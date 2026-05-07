require_relative "test_helper"

class ErrorSubscriberTest < Minitest::Test
  URL = "https://tend.justinpaulson.com/api/error_events".freeze

  def setup
    fresh_config!
  end

  def test_unhandled_error_captured
    stub_request(:post, URL).to_return(status: 202, body: "{}")
    sub = Tend::ErrorSubscriber.new
    err = build_exception
    sub.report(err, handled: false, severity: :error, context: { foo: "bar" })

    assert_requested(:post, URL) do |req|
      body = JSON.parse(req.body)
      assert_equal "boom", body["message"]
      assert_equal "bar", body["tags"]["foo"]
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

  private

  def build_exception
    e = RuntimeError.new("boom")
    e.set_backtrace(["/path:1:in `t'"])
    e
  end
end
