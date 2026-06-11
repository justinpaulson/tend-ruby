require_relative "test_helper"
require "active_support/parameter_filter"

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
    assert payload.dig(:context, "runtime", "ruby_version")
    assert_equal "RuntimeError", payload.dig(:context, "error", "class")
    assert_equal [], payload.dig(:context, "error", "cause_chain")
  end

  def test_from_exception_nil_backtrace
    e = RuntimeError.new("no backtrace")
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: nil)
    assert_equal "", payload[:stack_trace]
  end

  def test_tags_merge_extra_wins_on_non_reserved_conflict
    Tend.configuration.tags = { hostname: "host1", shared: "from_config" }
    e = build_exception
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/x" }
    extra = { shared: "from_extra", method: "PUT", path: "/wrong" }
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: extra, env: env)

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

  def test_stack_trace_is_not_duplicated_in_context
    e = build_exception
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: nil)

    refute_context_key payload[:context], "stack_trace"
    refute_context_key payload[:context], "backtrace"
  end

  def test_tag_overflow_preserves_rack_filter_tags
    extra = { method: "PUT", path: "/wrong", request_id: "wrong" }
    70.times { |i| extra["k#{i}"] = i }
    env = {
      "REQUEST_METHOD" => "PATCH",
      "PATH_INFO" => "/widgets",
      "action_dispatch.request_id" => "req-123"
    }
    e = build_exception
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: extra, env: env)

    assert_equal 64, payload[:tags].size
    assert_equal "PATCH", payload[:tags]["method"]
    assert_equal "/widgets", payload[:tags]["path"]
    assert_equal "req-123", payload[:tags]["request_id"]
  end

  def test_url_construction_filters_sensitive_top_level_url
    env = {
      "rack.url_scheme" => "https",
      "HTTP_HOST" => "example.com",
      "PATH_INFO" => "/users",
      "QUERY_STRING" => "id=1&token=raw",
      "SERVER_PORT" => "443"
    }
    e = build_exception
    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: env)
    assert_equal "https://example.com/users?id=1&token=%5BFILTERED%5D", payload[:url]
  end

  def test_context_includes_request_route_params_runtime_and_exception_metadata
    env = {
      "rack.url_scheme" => "https",
      "HTTP_HOST" => "example.com",
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/users/42",
      "QUERY_STRING" => "page=1",
      "SERVER_PORT" => "443",
      "HTTP_USER_AGENT" => "Agent/1.0",
      "HTTP_REFERER" => "https://example.com/start",
      "REMOTE_ADDR" => "203.0.113.10",
      "CONTENT_TYPE" => "application/json",
      "action_dispatch.request_id" => "req-123",
      "action_dispatch.route_uri_pattern" => "/users/:id",
      "action_dispatch.request.path_parameters" => { controller: "users", action: "show" },
      "action_dispatch.request.parameters" => { "name" => "Justin", "password" => "secret" }
    }
    e = build_exception

    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: env)
    context = payload[:context]

    assert_equal "POST", context.dig("request", "method")
    assert_equal "/users/42", context.dig("request", "path")
    assert_equal "req-123", context.dig("request", "request_id")
    assert_equal "Agent/1.0", context.dig("request", "user_agent")
    assert_equal "203.0.113.10", context.dig("request", "remote_ip")
    assert_equal "application/json", context.dig("request", "content_type")
    assert_equal "users", context.dig("route", "controller")
    assert_equal "show", context.dig("route", "action")
    assert_equal "/users/:id", context.dig("route", "pattern")
    assert_equal "Justin", context.dig("params", "name")
    assert_equal "[FILTERED]", context.dig("params", "password")
    assert_equal "tend-ruby/#{Tend::VERSION}", context.dig("runtime", "sdk_version")
    assert_equal [], context.dig("error", "cause_chain")
  end

  def test_uses_rails_request_filtered_parameters_when_present
    request = fake_request(
      filtered_parameters: { "password" => "[FILTERED_BY_RAILS]", "safe" => "1" },
      filtered_path: "/accounts?password=%5BFILTERED_BY_RAILS%5D",
      route_uri_pattern: "/accounts"
    )
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/accounts", "QUERY_STRING" => "password=secret" }

    Tend::PayloadBuilder.stub(:action_dispatch_request, request) do
      payload = Tend::PayloadBuilder.from_exception(build_exception, configuration: Tend.configuration, extra: {}, env: env)

      assert_equal "[FILTERED_BY_RAILS]", payload.dig(:context, "params", "password")
      assert_equal "/accounts?password=%5BFILTERED_BY_RAILS%5D", payload.dig(:context, "request", "filtered_path")
    end
  end

  def test_uses_rails_parameter_filter_for_params_and_rails_error_context
    filter = ActiveSupport::ParameterFilter.new([:password, :custom_secret])
    params = {
      "password" => "secret",
      "custom_secret" => "secret",
      "safe" => "1"
    }
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/x",
      "action_dispatch.parameter_filter" => filter,
      "action_dispatch.request.parameters" => params
    }

    payload = Tend::PayloadBuilder.from_exception(
      build_exception,
      configuration: Tend.configuration,
      extra: {},
      env: env,
      rails_error: { handled: false, context: { "custom_secret" => "secret", "safe" => "ok" } }
    )

    assert_equal "[FILTERED]", payload.dig(:context, "params", "password")
    assert_equal "[FILTERED]", payload.dig(:context, "params", "custom_secret")
    assert_equal "1", payload.dig(:context, "params", "safe")
    assert_equal "[FILTERED]", payload.dig(:context, "rails", "context", "custom_secret")
    assert_equal "ok", payload.dig(:context, "rails", "context", "safe")
  end

  def test_fallback_filter_catches_nested_sensitive_fields_and_does_not_mutate
    params = {
      "api_key" => "secret",
      "nested" => [{ "session_id" => "secret", "safe" => "1" }]
    }
    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/x",
      "action_dispatch.request.parameters" => params
    }

    payload = Tend::PayloadBuilder.from_exception(build_exception, configuration: Tend.configuration, extra: {}, env: env)

    assert_equal "[FILTERED]", payload.dig(:context, "params", "api_key")
    assert_equal "[FILTERED]", payload.dig(:context, "params", "nested", 0, "session_id")
    assert_equal "secret", params["api_key"]
    assert_equal "secret", params["nested"][0]["session_id"]
  end

  def test_rails_error_metadata_goes_to_context_and_extra_tags_remain_compatible
    payload = Tend::PayloadBuilder.from_exception(
      build_exception,
      configuration: Tend.configuration,
      extra: { job_id: "job-1", token: "tag-secret" },
      env: nil,
      rails_error: {
        handled: false,
        severity: :error,
        source: "rails",
        context: { job_id: "job-1", token: "secret" }
      }
    )

    assert_equal false, payload.dig(:context, "rails", "handled")
    assert_equal "error", payload.dig(:context, "rails", "severity")
    assert_equal "rails", payload.dig(:context, "rails", "source")
    assert_equal "job-1", payload.dig(:context, "rails", "context", "job_id")
    assert_equal "[FILTERED]", payload.dig(:context, "rails", "context", "token")
    assert_equal "job-1", payload[:tags]["job_id"]
    assert_equal "[FILTERED]", payload[:tags]["token"]
  end

  def test_custom_context_cannot_override_sdk_sections
    payload = Tend::PayloadBuilder.from_exception(
      build_exception,
      configuration: Tend.configuration,
      extra: {},
      env: nil,
      context: { "error" => { "class" => "Fake" }, "feature" => "checkout" }
    )

    assert_equal "RuntimeError", payload.dig(:context, "error", "class")
    assert_equal "checkout", payload.dig(:context, "feature")
  end

  def test_exception_cause_summaries_are_bounded
    root = RuntimeError.new("root")
    root.set_backtrace(["/root.rb:1"])
    child = RuntimeError.new("child")
    child.set_backtrace(["/child.rb:2"])
    child.define_singleton_method(:cause) { root }
    e = RuntimeError.new("top")
    e.define_singleton_method(:cause) { child }

    payload = Tend::PayloadBuilder.from_exception(e, configuration: Tend.configuration, extra: {}, env: nil)
    causes = payload.dig(:context, "error", "cause_chain")

    assert_equal "RuntimeError", causes[0]["class"]
    assert_equal "child", causes[0]["message"]
    assert_equal "/child.rb:2", causes[0]["top_frame"]
    assert_equal "root", causes[1]["message"]
    refute causes[0].key?("backtrace")
    refute causes[0].key?("stack_trace")
  end

  def test_context_bounds_large_values
    large_hash = {}
    60.times { |i| large_hash["k#{i}"] = i }
    rails_context = {
      "large_string" => "x" * 3000,
      "large_array" => 30.times.to_a,
      "large_hash" => large_hash,
      "deep" => { "a" => { "b" => { "c" => { "d" => { "e" => "too deep" } } } } }
    }
    payload = Tend::PayloadBuilder.from_exception(
      build_exception,
      configuration: Tend.configuration,
      extra: {},
      env: nil,
      rails_error: { handled: false, context: rails_context }
    )
    context = payload.dig(:context, "rails", "context")

    assert_operator context["large_string"].bytesize, :<=, 2048
    assert_equal 20, context["large_array"].length
    assert_equal 50, context["large_hash"].length
    assert_equal "[Truncated]", context.dig("deep", "a", "b")
  end

  def test_from_message_includes_runtime_context
    payload = Tend::PayloadBuilder.from_message("hello", level: "warning", configuration: Tend.configuration, extra: { foo: "bar" })
    assert_equal "backend", payload[:source]
    assert_equal "warning", payload[:level]
    assert_equal "hello", payload[:message]
    refute payload.key?(:exception_class)
    refute payload.key?(:stack_trace)
    assert payload.dig(:context, "runtime", "ruby_version")
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

  def fake_request(filtered_parameters:, filtered_path:, route_uri_pattern:)
    request = Object.new
    request.define_singleton_method(:request_method) { "GET" }
    request.define_singleton_method(:path) { "/accounts" }
    request.define_singleton_method(:filtered_path) { filtered_path }
    request.define_singleton_method(:filtered_url) { "https://example.com#{filtered_path}" }
    request.define_singleton_method(:host) { "example.com" }
    request.define_singleton_method(:scheme) { "https" }
    request.define_singleton_method(:request_id) { "req-filtered" }
    request.define_singleton_method(:filtered_parameters) { filtered_parameters }
    request.define_singleton_method(:path_parameters) { { controller: "accounts", action: "index" } }
    request.define_singleton_method(:route_uri_pattern) { route_uri_pattern }
    request
  end

  def refute_context_key(value, key)
    case value
    when Hash
      refute value.key?(key), "expected context not to include #{key.inspect}"
      value.each_value { |child| refute_context_key(child, key) }
    when Array
      value.each { |child| refute_context_key(child, key) }
    end
  end
end
