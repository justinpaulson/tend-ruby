require_relative "test_helper"

class TransportTest < Minitest::Test
  URL = "https://tend.justinpaulson.com/api/error_events".freeze

  def setup
    fresh_config!
  end

  def test_synchronous_post_with_headers_and_body
    stub_request(:post, URL).to_return(status: 202, body: "{}")
    Tend.capture_exception(RuntimeError.new("boom"))

    assert_requested(:post, URL) do |req|
      assert_equal "tok_test", req.headers["X-Tend-Ingest-Token"]
      assert_match(/tend-ruby\//, req.headers["User-Agent"])
      body = JSON.parse(req.body)
      assert_equal "backend", body["source"]
      assert_equal "boom", body["message"]
      assert_equal "RuntimeError", body["exception_class"]
      true
    end
  end

  def test_401_swallowed
    stub_request(:post, URL).to_return(status: 401, body: '{"error":"Unauthorized"}')
    Tend.capture_exception(RuntimeError.new("boom"))
  end

  def test_429_no_retry
    stub_request(:post, URL).to_return(status: 429, body: '{"error":"rate limited"}')
    Tend.capture_exception(RuntimeError.new("boom"))
    assert_requested :post, URL, times: 1
  end

  def test_timeout_swallowed
    stub_request(:post, URL).to_timeout
    Tend.capture_exception(RuntimeError.new("boom"))
  end

  def test_connection_refused_swallowed
    stub_request(:post, URL).to_raise(Errno::ECONNREFUSED)
    Tend.capture_exception(RuntimeError.new("boom"))
  end

  def test_disabled_when_token_missing
    Tend.reset_configuration!
    Tend.configure { |c| c.ingest_token = nil; c.logger = Logger.new(StringIO.new) }
    Tend.capture_exception(RuntimeError.new("boom"))
    refute_requested :post, URL
  end
end
