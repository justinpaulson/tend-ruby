require_relative "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    Tend.reset_configuration!
    Tend::Transport.reset!
    Tend::Transport.synchronous = true
  end

  def test_defaults
    cfg = Tend::Configuration.new
    assert_equal "https://tend.justinpaulson.com/api/error_events", cfg.ingest_url
    assert_kind_of Hash, cfg.tags
    assert_includes cfg.ignored_exceptions, "ActiveRecord::RecordNotFound"
    assert_kind_of Proc, cfg.before_send
    assert_equal({ a: 1 }, cfg.before_send.call({ a: 1 }))
    assert_equal true, cfg.enabled
    refute cfg.valid?, "no token => invalid"
  end

  def test_user_default_is_nil
    cfg = Tend::Configuration.new
    assert_nil cfg.user
  end

  def test_configure_with_token
    Tend.configure { |c| c.ingest_token = "tok" }
    assert Tend.configuration.valid?
  end

  def test_configure_without_token_disables_and_warns
    io = StringIO.new
    log = Logger.new(io)
    Tend.configure do |c|
      c.logger = log
      c.ingest_token = nil
    end

    refute Tend.configuration.valid?
    refute Tend.configuration.enabled
    assert_match(/SDK disabled/, io.string)
  end

  def test_capture_exception_no_op_when_disabled
    Tend.configure do |c|
      c.logger = Logger.new(StringIO.new)
      c.ingest_token = nil
    end

    Tend.capture_exception(StandardError.new("nope"))
  end

  def test_before_send_returning_nil_drops
    fresh_config!
    stub_request(:post, "https://tend.justinpaulson.com/api/error_events")
      .to_return(status: 202, body: "{}")
    Tend.configuration.before_send = ->(_payload) { nil }
    Tend.capture_exception(RuntimeError.new("boom"))
    refute_requested :post, "https://tend.justinpaulson.com/api/error_events"
  end

  def test_ignored_exceptions_match_subclass
    fresh_config!
    Tend.configuration.ignored_exceptions = ["RuntimeError"]
    sub = Class.new(RuntimeError) { def self.name; "MySubclass"; end }
    assert Tend.ignored?(sub.new("x"))
  end
end
