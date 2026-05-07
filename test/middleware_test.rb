require_relative "test_helper"
require "rack"
require "rack/test"

class MiddlewareTest < Minitest::Test
  include Rack::Test::Methods

  URL = "https://tend.justinpaulson.com/api/error_events".freeze

  def setup
    fresh_config!
    @raise_class = nil
    @raise_message = nil
  end

  def app
    raise_class = -> { @raise_class }
    raise_message = -> { @raise_message }
    inner = ->(_env) { raise raise_class.call, raise_message.call }
    Tend::Middleware.new(inner)
  end

  def test_captures_and_reraises
    @raise_class = RuntimeError
    @raise_message = "boom"
    stub_request(:post, URL).to_return(status: 202, body: "{}")

    err = assert_raises(RuntimeError) do
      get "/widgets?id=42", {}, { "HTTP_USER_AGENT" => "MyAgent/1.0" }
    end
    assert_equal "boom", err.message
    assert_requested(:post, URL) do |req|
      body = JSON.parse(req.body)
      assert_equal "GET", body["tags"]["method"]
      assert_equal "/widgets", body["tags"]["path"]
      assert_includes body["url"].to_s, "/widgets"
      assert_equal "MyAgent/1.0", body["user_agent"]
      true
    end
  end

  def test_ignored_exception_not_captured
    Tend.configuration.ignored_exceptions = ["MyIgnored"]
    ignored_class = Class.new(StandardError)
    Object.const_set(:MyIgnored, ignored_class) unless Object.const_defined?(:MyIgnored)

    @raise_class = MyIgnored
    @raise_message = "ignore me"
    stub_request(:post, URL).to_return(status: 202, body: "{}")

    assert_raises(MyIgnored) { get "/x" }
    refute_requested(:post, URL)
  ensure
    Object.send(:remove_const, :MyIgnored) if Object.const_defined?(:MyIgnored)
  end

  def test_passes_through_when_no_exception
    inner_app = ->(_env) { [200, {}, ["ok"]] }
    mw = Tend::Middleware.new(inner_app)
    status, _headers, body = mw.call(Rack::MockRequest.env_for("/"))
    assert_equal 200, status
    assert_equal ["ok"], body
  end
end
