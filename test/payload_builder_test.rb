require_relative "test_helper"

class PayloadBuilderTest < Minitest::Test
  def setup
    fresh_config!
  end

  def test_from_exception_required_fields
    e = build_exception
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: nil)

    assert_equal "backend", payload[:source]
    assert_equal "error", payload[:level]
    assert_equal "boom", payload[:message]
    assert_equal "RuntimeError", payload[:exception_class]
    assert_includes payload[:stack_trace], "/some/path.rb"
    assert payload[:occurred_at]
    assert_match(%r{tend-ruby/}, payload[:sdk_version])
  end

  def test_from_exception_nil_backtrace
    e = RuntimeError.new("no backtrace")
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: nil)
    assert_equal "", payload[:stack_trace]
  end

  def test_tags_merge_extra_wins_on_conflict
    Tend.configuration.tags = { hostname: "host1", shared: "from_config" }
    e = build_exception
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/x" }
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: { shared: "from_extra" }, env: env)

    assert_equal "from_extra", payload[:tags]["shared"]
    assert_equal "POST", payload[:tags]["method"]
    assert_equal "/x", payload[:tags]["path"]
    assert_equal "host1", payload[:tags]["hostname"]
  end

  def test_tag_values_stringified
    e = build_exception
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: { count: 42, sym: :ok }, env: nil)
    assert_equal "42", payload[:tags]["count"]
    assert_equal "ok", payload[:tags]["sym"]
  end

  def test_message_truncation
    big = "x" * 5000
    e = RuntimeError.new(big)
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: nil)
    assert_equal 4096, payload[:message].bytesize
  end

  def test_stack_trace_truncation
    e = build_exception(backtrace: ["a" * 17_000])
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: nil)
    assert_operator payload[:stack_trace].bytesize, :<=, 16_384
  end

  def test_tag_overflow_trims_to_64
    extra = {}
    70.times { |i| extra["k#{i}"] = i }
    e = build_exception
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: extra, env: nil)
    assert_equal 64, payload[:tags].size
  end

  def test_url_construction
    env = {
      "rack.url_scheme" => "https",
      "HTTP_HOST" => "example.com",
      "PATH_INFO" => "/users",
      "QUERY_STRING" => "id=1",
      "SERVER_PORT" => "443"
    }
    e = build_exception
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: env)
    assert_equal "https://example.com/users?id=1", payload[:url]
  end

  def test_from_message
    payload = Tend::PayloadBuilder.from_message("hello", level: "warning", configuration: Tend.configuration, extra: { foo: "bar" })
    assert_equal "backend", payload[:source]
    assert_equal "warning", payload[:level]
    assert_equal "hello", payload[:message]
    refute payload.key?(:exception_class)
    refute payload.key?(:stack_trace)
    assert_equal "bar", payload[:tags]["foo"]
  end

  def test_payload_omits_user_when_unset
    e = build_exception
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: nil)
    refute payload.key?(:user)
  end

  def test_payload_includes_configuration_user
    Tend.configuration.user = { id: "u1", email: "x@y.com" }
    e = build_exception
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: nil)
    assert_equal({ id: "u1", email: "x@y.com" }, payload[:user])
  end

  def test_payload_thread_local_overrides_configuration_user
    Tend.configuration.user = { id: "global", email: "g@x" }
    Thread.current[:tend_user] = { id: "local", email: "l@x" }
    e = build_exception
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: nil)
    assert_equal({ id: "local", email: "l@x" }, payload[:user])
  end

  def test_from_message_includes_user
    Tend.configuration.user = { id: "u1", email: "x@y.com" }
    payload = Tend::PayloadBuilder.from_message("hi", configuration: Tend.configuration)
    assert_equal({ id: "u1", email: "x@y.com" }, payload[:user])
  end

  private

  def build_exception(message: "boom", backtrace: ["/some/path.rb:1:in `do_thing'"])
    e = RuntimeError.new(message)
    e.set_backtrace(backtrace)
    e
  end
end
