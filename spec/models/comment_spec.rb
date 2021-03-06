require 'spec_helper'

describe Comment do
  def valid_comment(options={})
    Comment.new({:author => 'Bob',
                :article_id => Factory(:article).id,
                :body => 'nice post',
                :ip => '1.2.3.4'}.merge(options))
  end

  describe '#permalink_url' do
    before(:each) do
      Factory(:blog)
      @c = Factory(:comment, :article => Factory(:article,
        :permalink => 'inactive-article',
        :published_at => Date.new(2004, 5, 1)))
    end

    subject { @c.permalink_url }

    it 'should render permalink to comment in public part' do
      should == "http://myblog.net/2004/05/01/inactive-article#comment-#{@c.id}"
    end
  end

  describe '#edit_url' do
    it 'should get a url where edit comment in admin' do
      Factory(:blog)
      c = feedback(:old_comment)
      assert_equal "http://myblog.net/admin/comments/edit/#{c.id}", c.edit_url
    end
  end

  describe '#delete_url' do
    it 'should get the delete url of comment in admin part' do
      Factory(:blog)
      c = feedback(:old_comment)
      assert_equal "http://myblog.net/admin/comments/destroy/#{c.id}", c.delete_url
    end
  end

  describe '#save' do
    before(:each) { Factory(:blog, :sp_article_auto_close => 300) }
    it 'should save good comment' do
      assert feedback(:comment2).save
      assert_equal "http://www.google.com", feedback(:comment2).url
    end

    it 'should save spam comment' do
      assert feedback(:spam_comment).save
      assert_equal "http://fakeurl.com", feedback(:spam_comment).url
    end

    it 'should not save in invalid article' do
      c = valid_comment(:author => "Old Spammer",
                        :body => "Old trackback body",
                        :article => Factory.build(:article, :state => 'draft'))

      assert ! c.save
      assert c.errors['article_id'].any?
    end

    it 'should change old comment' do
      c = Factory(:comment)
      c.body = 'Comment body <em>italic</em> <strong>bold</strong>'
      assert c.save
      assert c.errors.empty?
    end

    it 'should save a valid comment' do
      c = valid_comment # article created 2 days ago
      c.save.should be_true
      c.errors.should be_empty
    end

    it 'should not save with article not allow comment'  do
      b = Blog.default
      b.sp_article_auto_close = 1
      b.save

      c = Factory.build(:comment, :article => Factory(:article, :allow_comments => false))
      c.save.should_not be_true
      c.errors.should_not be_empty
    end

  end

  describe '#create' do
    it 'should create comment' do
      Factory(:blog)
      c = valid_comment
      assert c.save
      assert c.guid.size > 15
    end

  end

  describe '#spam?' do
    before(:each) do
      Factory(:blog)
    end

    it 'should reject spam rbl' do
      c = valid_comment(:author => "Spammer",
                        :body => %{This is just some random text. &lt;a href="http://chinaaircatering.com"&gt;without any senses.&lt;/a&gt;. Please disregard.},
                        :url => "http://buy-computer.us")
      should_be_spam(c)
    end

    it 'should not define spam a comment rbl with lookup succeeds' do
      c = valid_comment(:author => "Not a Spammer",
                        :body   => "Useful commentary!",
                        :url    => "http://www.bofh.org.uk")
      c.should_not be_spam
      c.should_not be_status_confirmed
    end

    it 'should reject spam with uri limit' do
      c = valid_comment(:author => "Yet Another Spammer",
                        :body => %{ <a href="http://www.one.com/">one</a> <a href="http://www.two.com/">two</a> <a href="http://www.three.com/">three</a> <a href="http://www.four.com/">four</a> },
                        :url => "http://www.uri-limit.com")
      should_be_spam(c)
    end

    def should_be_spam(comment)
      comment.should be_spam
      comment.should_not be_status_confirmed
    end

  end

  it 'should have good relation' do
    article = Factory.build(:article)
    comment = Factory.build(:comment, :article => article)
    assert comment.article
    assert_equal article, comment.article
  end

  describe 'reject xss' do
    before(:each) do
      Factory(:blog)
      @comment = Comment.new do |c|
        c.body = "Test foo <script>do_evil();</script>"
        c.author = 'Bob'
        c.article_id = Factory(:article).id
      end
    end
    ['','textile','markdown','smartypants','markdown smartypants'].each do |filter|
      it "should reject with filter #{filter}" do
        Blog.default.comment_text_filter = filter

        assert @comment.save
        assert @comment.errors.empty?

        assert @comment.html(:body) !~ /<script>/
      end
    end
  end

  describe 'change state' do
    before(:each) do
      Factory(:blog)
    end

    it 'should becomes withdraw' do
      c = Comment.find(feedback(:comment2).id)
      assert c.withdraw!
      assert ! c.published?
      assert c.spam?
      assert c.status_confirmed?
      c.reload
      assert ! c.published?
      assert c.spam?
      assert c.status_confirmed?
    end

    it 'should becomes not published in article if withdraw' do
      a = Article.new(:title => 'foo')
      assert a.save

      assert_equal 0, a.published_comments.size
      c = a.comments.build(:body => 'foo', :author => 'bob', :published => true, :published_at => Time.now)
      assert c.save
      assert c.published?
      c.reload
      a.reload

      assert_equal 1, a.published_comments.size
      c.withdraw!

      a = Article.new(:title => 'foo')
      assert_equal 0, a.published_comments.size
    end

    it 'should becomes not confirmed in article if withdraw' do
      a = Factory(:article)
      Factory(:comment, :article => a, :state => 'presumed_ham')
      Factory(:comment, :article => a, :state => 'ham')
      assert !a.comments[0].status_confirmed?
      assert  a.comments[1].status_confirmed?

      a.reload
      assert_equal 1,
        a.comments.find_all_by_status_confirmed(true).size
      assert_equal 1,
        a.comments.find_all_by_status_confirmed(true).size
      a.comments[0].withdraw!
      assert_equal 2,
        a.comments.find_all_by_status_confirmed(true).size
    end
  end

  it 'should have good default filter' do
    Factory(:blog)
    a = Comment.find(:first)
    assert_equal 'markdown', a.default_text_filter.name
  end

  describe 'with feedback moderation enabled' do
    before(:each) do
      @blog = Factory(:blog,
        :sp_global => false,
        :default_moderate_comments => true)
    end

    it 'should save comment as presumably spam' do
      comment = Comment.new do |c|
        c.body = "Test foo"
        c.author = 'Bob'
        c.article_id = Factory(:article).id
      end
      assert comment.save!

      assert ! comment.published?
      assert comment.spam?
      assert ! comment.status_confirmed?
    end

    it 'should save comment as confirmed ham' do
      comment = Comment.new do |c|
        c.body = "Test foo"
        c.author = 'Bob'
        c.article_id = Factory(:article).id
        c.user_id = users(:tobi).id
      end
      assert comment.save!

      assert comment.published?
      assert comment.ham?
      assert comment.status_confirmed?

    end
  end

end
