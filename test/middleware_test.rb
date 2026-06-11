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
      assert_equal "GET", body.dig("context", "request", "method")
      assert_equal "/widgets", body.dig("context", "request", "path")
      assert_equal "42", body.dig("context", "params", "id")
      true
    end
  end

  def test_request_context_visible_and_cleaned_up_on_success
    observed_env = nil
    inner_app = lambda do |_env|
      observed_env = Tend::RequestContext.current_env
      [200, {}, ["ok"]]
    end
    mw = Tend::Middleware.new(inner_app)
    env = Rack::MockRequest.env_for("/ok")

    status, _headers, body = mw.call(env)

    assert_equal 200, status
    assert_equal ["ok"], body
    assert_same env, observed_env
    assert_nil Tend::RequestContext.current_env
  end

  def test_request_context_visible_during_capture_and_cleaned_after_exception
    observed_env = nil
    Tend.configuration.before_send = lambda do |payload|
      observed_env = Tend::RequestContext.current_env
      payload
    end
    stub_request(:post, URL).to_return(status: 202, body: "{}")
    env = Rack::MockRequest.env_for("/boom")
    mw = Tend::Middleware.new(->(_env) { raise "boom" })

    assert_raises(RuntimeError) { mw.call(env) }

    assert_same env, observed_env
    assert_nil Tend::RequestContext.current_env
  end

  def test_ignored_exception_not_captured_and_context_cleaned
    Tend.configuration.ignored_exceptions = ["MyIgnored"]
    ignored_class = Class.new(StandardError)
    Object.const_set(:MyIgnored, ignored_class) unless Object.const_defined?(:MyIgnored)

    @raise_class = MyIgnored
    @raise_message = "ignore me"
    stub_request(:post, URL).to_return(status: 202, body: "{}")

    assert_raises(MyIgnored) { get "/x" }
    refute_requested(:post, URL)
    assert_nil Tend::RequestContext.current_env
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

  def test_subscriber_and_middleware_do_not_duplicate_same_exception
    stub_request(:post, URL).to_return(status: 202, body: "{}")
    err = build_exception("boom")
    inner_app = lambda do |_env|
      Tend::ErrorSubscriber.new.report(err, handled: false, severity: :error, context: { phase: "rails" })
      raise err
    end
    mw = Tend::Middleware.new(inner_app)

    assert_raises(RuntimeError) { mw.call(Rack::MockRequest.env_for("/dupe")) }

    assert_requested(:post, URL, times: 1)
  end

  def test_wrapped_exception_chain_does_not_duplicate_after_cause_capture
    stub_request(:post, URL).to_return(status: 202, body: "{}")
    cause = build_exception("cause")
    wrapper = RuntimeError.new("wrapper")
    wrapper.set_backtrace(["/wrapper.rb:1"])
    wrapper.define_singleton_method(:cause) { cause }
    inner_app = lambda do |_env|
      Tend::ErrorSubscriber.new.report(cause, handled: false, severity: :error, context: {})
      raise wrapper
    end
    mw = Tend::Middleware.new(inner_app)

    assert_raises(RuntimeError) { mw.call(Rack::MockRequest.env_for("/wrapped")) }

    assert_requested(:post, URL, times: 1)
  end

  private

  def build_exception(message)
    e = RuntimeError.new(message)
    e.set_backtrace(["/path.rb:1"])
    e
  end
end
