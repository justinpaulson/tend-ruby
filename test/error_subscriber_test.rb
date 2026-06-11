require_relative "test_helper"

class ErrorSubscriberTest < Minitest::Test
  URL = "https://tend.justinpaulson.com/api/error_events".freeze

  def setup
    fresh_config!
  end

  def test_unhandled_error_captured_with_env_and_rails_error_metadata
    stub_request(:post, URL).to_return(status: 202, body: "{}")
    sub = Tend::ErrorSubscriber.new
    err = build_exception
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/jobs",
      "action_dispatch.request_id" => "req-456"
    }

    Tend::RequestContext.with_env(env) do
      sub.report(err, handled: false, severity: :error, context: { foo: "bar", token: "secret" }, source: "rails")
    end

    assert_requested(:post, URL) do |req|
      body = JSON.parse(req.body)
      assert_equal "boom", body["message"]
      assert_equal "bar", body["tags"]["foo"]
      assert_equal "[FILTERED]", body["tags"]["token"]
      assert_equal "POST", body["tags"]["method"]
      assert_equal "/jobs", body["tags"]["path"]
      assert_equal "req-456", body["tags"]["request_id"]
      assert_equal "POST", body.dig("context", "request", "method")
      assert_equal "/jobs", body.dig("context", "request", "path")
      assert_equal "req-456", body.dig("context", "request", "request_id")
      assert_equal false, body.dig("context", "rails_error", "handled")
      assert_equal "error", body.dig("context", "rails_error", "severity")
      assert_equal "rails", body.dig("context", "rails_error", "source")
      assert_equal "bar", body.dig("context", "rails_error", "context", "foo")
      assert_equal "[FILTERED]", body.dig("context", "rails_error", "context", "token")
      true
    end
  end

  def test_handled_error_skipped
    stub_request(:post, URL).to_return(status: 202, body: "{}")
    sub = Tend::ErrorSubscriber.new
    err = build_exception
    sub.report(err, handled: true, severity: :error, context: {})
    refute_requested(:post, URL)
  end

  def test_no_source_kwarg_compatible
    stub_request(:post, URL).to_return(status: 202, body: "{}")
    sub = Tend::ErrorSubscriber.new
    err = build_exception
    sub.report(err, handled: false, severity: :error, context: nil, source: "rails")
    assert_requested(:post, URL)
  end

  def test_skips_exception_already_captured_in_request_context
    stub_request(:post, URL).to_return(status: 202, body: "{}")
    sub = Tend::ErrorSubscriber.new
    err = build_exception

    Tend::RequestContext.with_env({}) do
      Tend::RequestContext.mark_captured(err)
      sub.report(err, handled: false, severity: :error, context: nil, source: "rails")
    end

    refute_requested(:post, URL)
  end

  def test_skips_exception_chain_already_captured
    stub_request(:post, URL).to_return(status: 202, body: "{}")
    sub = Tend::ErrorSubscriber.new
    cause = build_exception("cause")
    wrapper = RuntimeError.new("wrapper")
    wrapper.define_singleton_method(:cause) { cause }

    Tend::RequestContext.with_env({}) do
      Tend::RequestContext.mark_captured(cause)
      sub.report(wrapper, handled: false, severity: :error, context: nil, source: "rails")
    end

    refute_requested(:post, URL)
  end

  private

  def build_exception(message = "boom")
    e = RuntimeError.new(message)
    e.set_backtrace(["/path:1:in `t'"])
    e
  end
end
