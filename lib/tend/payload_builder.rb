require "time"
require "uri"

module Tend
  module PayloadBuilder
    MESSAGE_BYTE_LIMIT = 4_096
    STACK_TRACE_BYTE_LIMIT = 16_384
    URL_LIMIT = 2_048
    TAGS_KEY_LIMIT = 64
    CONTEXT_DEPTH_LIMIT = 5
    CONTEXT_HASH_KEY_LIMIT = 50
    CONTEXT_ARRAY_LIMIT = 20
    CONTEXT_STRING_BYTE_LIMIT = 2_048
    CONTEXT_CAUSE_LIMIT = 5
    FILTERED_VALUE = "[FILTERED]".freeze
    SENSITIVE_KEY_PATTERN = /password|passwd|pwd|token|secret|key|auth|cookie|session|csrf/i
    RESERVED_RACK_TAGS = %w[method path request_id].freeze

    module_function

    def from_exception(exception, configuration:, extra: {}, env: nil, rails_error: nil)
      base = {
        source: "backend",
        level: "error",
        message: truncate_bytes(exception.message.to_s, MESSAGE_BYTE_LIMIT),
        exception_class: exception.class.name,
        stack_trace: truncate_bytes(Array(exception.backtrace).join("\n"), STACK_TRACE_BYTE_LIMIT),
        occurred_at: Time.now.utc.iso8601,
        release: configuration.release,
        environment: configuration.environment,
        sdk_version: "tend-ruby/#{Tend::VERSION}",
        url: env ? build_url(env) : nil,
        user_agent: env ? env["HTTP_USER_AGENT"] : nil,
        user: resolve_user(configuration),
        tags: build_tags(configuration: configuration, extra: extra, env: env),
        context: build_context(exception, env: env, rails_error: rails_error)
      }
      base.compact
    end

    def from_message(message, level: "error", configuration:, extra: {})
      {
        source: "backend",
        level: level,
        message: truncate_bytes(message.to_s, MESSAGE_BYTE_LIMIT),
        occurred_at: Time.now.utc.iso8601,
        release: configuration.release,
        environment: configuration.environment,
        sdk_version: "tend-ruby/#{Tend::VERSION}",
        user: resolve_user(configuration),
        tags: build_tags(configuration: configuration, extra: extra, env: nil)
      }.compact
    end

    def resolve_user(configuration)
      Thread.current[:tend_user] || configuration.user
    end

    def build_tags(configuration:, extra:, env:)
      merged = {}
      rack_tag_values = env ? stringify(rack_tags(env)) : {}

      merged.merge!(stringify(configuration.tags)) if configuration.tags.is_a?(Hash)
      merged.merge!(rack_tag_values)
      merged.merge!(stringify(extra)) if extra.is_a?(Hash)
      rack_tag_values.each { |key, value| merged[key] = value if RESERVED_RACK_TAGS.include?(key) }

      if merged.size > TAGS_KEY_LIMIT
        configuration.logger&.warn("Tend: tags exceed #{TAGS_KEY_LIMIT} keys; trimming")
        merged = trim_tags(merged, rack_tag_values)
      end
      merged
    end

    def trim_tags(tags, rack_tag_values)
      trimmed = {}
      rack_tag_values.each do |key, value|
        next unless RESERVED_RACK_TAGS.include?(key)

        trimmed[key] = value
      end

      tags.each do |key, value|
        break if trimmed.size >= TAGS_KEY_LIMIT
        next if trimmed.key?(key)

        trimmed[key] = value
      end

      trimmed
    end

    def rack_tags(env)
      return {} unless env

      {
        method: env["REQUEST_METHOD"],
        path: env["PATH_INFO"],
        request_id: env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
      }.compact
    end

    def build_context(exception, env:, rails_error:)
      request = action_dispatch_request(env)
      context = {
        request: build_request_context(env, request),
        route: build_route_context(env, request),
        params: build_params_context(env, request),
        rails_error: build_rails_error_context(rails_error, env, request),
        runtime: build_runtime_context,
        exception: build_exception_context(exception)
      }.compact

      normalize_context(context)
    end

    def action_dispatch_request(env)
      return nil unless env && defined?(::ActionDispatch::Request)

      ::ActionDispatch::Request.new(env)
    rescue StandardError
      nil
    end

    def build_request_context(env, request)
      return nil unless env

      {
        method: request_value(request, :request_method) || env["REQUEST_METHOD"],
        path: request_value(request, :path) || env["PATH_INFO"],
        filtered_path: request_value(request, :filtered_path),
        filtered_url: request_value(request, :filtered_url),
        host: request_value(request, :host) || env["HTTP_HOST"] || env["SERVER_NAME"],
        scheme: request_value(request, :scheme) || env["rack.url_scheme"],
        request_id: request_value(request, :request_id) ||
                    env["action_dispatch.request_id"] ||
                    env["HTTP_X_REQUEST_ID"],
        user_agent: request_value(request, :user_agent) || env["HTTP_USER_AGENT"],
        referer: request_value(request, :referer) || env["HTTP_REFERER"],
        remote_ip: request_value(request, :remote_ip) ||
                   env["action_dispatch.remote_ip"] ||
                   env["REMOTE_ADDR"],
        ip: request_value(request, :ip),
        content_type: request_value(request, :content_type) || env["CONTENT_TYPE"]
      }.compact
    end

    def build_route_context(env, request)
      return nil unless env

      path_parameters = hash_value(request_value(request, :path_parameters)) ||
                        hash_value(env["action_dispatch.request.path_parameters"]) ||
                        {}
      route = {
        controller: path_parameters[:controller] || path_parameters["controller"],
        action: path_parameters[:action] || path_parameters["action"],
        pattern: request_value(request, :route_uri_pattern) || env["action_dispatch.route_uri_pattern"]
      }.compact

      route.empty? ? nil : route
    end

    def build_params_context(env, request)
      return nil unless env

      filtered = request_value(request, :filtered_parameters)
      if filtered
        params = hash_value(filtered) || filtered
        return fallback_filter(params) unless params.respond_to?(:empty?) && params.empty?
      end

      params = fallback_params(env)
      return nil if params.empty?

      filter_value(params, env, request)
    end

    def fallback_params(env)
      params = {}
      combined = hash_value(env["action_dispatch.request.parameters"])

      if combined
        params.merge!(combined)
      else
        [
          "action_dispatch.request.path_parameters",
          "action_dispatch.request.query_parameters",
          "action_dispatch.request.request_parameters",
          "rack.request.query_hash",
          "rack.request.form_hash"
        ].each do |key|
          value = hash_value(env[key])
          params.merge!(value) if value
        end
      end

      params.merge!(parse_query_string(env["QUERY_STRING"])) if params.empty?
      params
    end

    def parse_query_string(query_string)
      return {} if query_string.to_s.empty?

      URI.decode_www_form(query_string.to_s).each_with_object({}) do |(key, value), memo|
        if memo.key?(key)
          memo[key] = Array(memo[key]) << value
        else
          memo[key] = value
        end
      end
    rescue StandardError
      {}
    end

    def build_rails_error_context(rails_error, env, request)
      return nil unless rails_error.is_a?(Hash)

      metadata = {
        handled: rails_error[:handled],
        severity: rails_error[:severity]&.to_s,
        source: rails_error[:source]&.to_s
      }.compact

      unless rails_error[:context].nil?
        metadata[:context] = filter_value(rails_error[:context], env, request)
      end

      metadata
    end

    def build_runtime_context
      {
        ruby_version: RUBY_VERSION,
        ruby_engine: defined?(RUBY_ENGINE) ? RUBY_ENGINE : nil,
        platform: RUBY_PLATFORM,
        pid: Process.pid,
        rails_version: defined?(::Rails) && ::Rails.respond_to?(:version) ? ::Rails.version : nil,
        rack_release: defined?(::Rack) && ::Rack.respond_to?(:release) ? ::Rack.release : nil,
        sdk_version: "tend-ruby/#{Tend::VERSION}"
      }.compact
    end

    def build_exception_context(exception)
      {
        causes: cause_summaries(exception)
      }
    end

    def cause_summaries(exception)
      summaries = []
      seen = {}.compare_by_identity
      current = exception.respond_to?(:cause) ? exception.cause : nil

      while current && !seen.key?(current) && summaries.length < CONTEXT_CAUSE_LIMIT
        seen[current] = true
        summaries << {
          class: current.class.name,
          message: truncate_bytes(current.message.to_s, MESSAGE_BYTE_LIMIT),
          top_frame: Array(current.backtrace).first
        }.compact
        current = current.respond_to?(:cause) ? current.cause : nil
      end

      summaries
    end

    def build_url(env)
      return nil unless env

      scheme = env["rack.url_scheme"] || "http"
      host = env["HTTP_HOST"] || env["SERVER_NAME"]
      return nil if host.nil? || host.to_s.empty?

      port = env["SERVER_PORT"]
      port_part = if port.nil? ||
                     (scheme == "http" && port.to_s == "80") ||
                     (scheme == "https" && port.to_s == "443") ||
                     host.to_s.include?(":")
        ""
      else
        ":#{port}"
      end
      path = env["PATH_INFO"].to_s
      qs = env["QUERY_STRING"].to_s
      url = "#{scheme}://#{host}#{port_part}#{path}"
      url += "?#{qs}" unless qs.empty?
      url[0, URL_LIMIT]
    end

    def request_value(request, method_name)
      return nil unless request && request.respond_to?(method_name)

      request.public_send(method_name)
    rescue StandardError
      nil
    end

    def hash_value(value)
      return value if value.is_a?(Hash)

      if value.respond_to?(:to_unsafe_h)
        value.to_unsafe_h
      elsif value.respond_to?(:to_h) && value.class.name.to_s.include?("Parameters")
        value.to_h
      end
    rescue StandardError
      nil
    end

    def filter_value(value, env, request)
      filter = rails_parameter_filter(env, request)
      if filter
        filtered = filter_with_rails(filter, value)
        return fallback_filter(filtered) unless filtered.nil?
      end

      fallback_filter(value)
    end

    def rails_parameter_filter(env, request)
      filter = request_value(request, :parameter_filter)
      filter ||= env && env["action_dispatch.parameter_filter"]
      return filter if filter.respond_to?(:filter)

      if filter.is_a?(Array) && defined?(::ActiveSupport::ParameterFilter)
        return ::ActiveSupport::ParameterFilter.new(filter)
      end

      nil
    rescue StandardError
      nil
    end

    def filter_with_rails(filter, value)
      return nil unless value.is_a?(Hash) || hash_value(value)

      filter.filter(deep_dup_value(hash_value(value) || value))
    rescue StandardError
      nil
    end

    def fallback_filter(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), memo|
          memo[key] = if sensitive_key?(key)
            already_filtered?(child) ? child : FILTERED_VALUE
          else
            fallback_filter(child)
          end
        end
      when Array
        value.map { |child| fallback_filter(child) }
      else
        value
      end
    end

    def sensitive_key?(key)
      key.to_s.match?(SENSITIVE_KEY_PATTERN)
    end

    def already_filtered?(value)
      value.is_a?(String) && value.match?(/\A\[FILTERED[^\]]*\]\z/i)
    end

    def deep_dup_value(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), memo| memo[key] = deep_dup_value(child) }
      when Array
        value.map { |child| deep_dup_value(child) }
      when String
        value.dup
      else
        value
      end
    end

    def normalize_context(value, depth = 0, seen = {})
      seen = seen.compare_by_identity unless seen.compare_by_identity?
      return "[Truncated]" if depth >= CONTEXT_DEPTH_LIMIT

      case value
      when nil, true, false
        value
      when String
        truncate_bytes(value, CONTEXT_STRING_BYTE_LIMIT)
      when Symbol
        value.to_s
      when Integer
        value
      when Float
        value.finite? ? value : value.to_s
      when Time
        value.utc.iso8601
      when Hash
        normalize_hash(value, depth, seen)
      when Array
        normalize_array(value, depth, seen)
      else
        truncate_bytes(value.to_s, CONTEXT_STRING_BYTE_LIMIT)
      end
    end

    def normalize_hash(value, depth, seen)
      return "[Circular]" if seen.key?(value)

      seen[value] = true
      normalized = {}
      value.first(CONTEXT_HASH_KEY_LIMIT).each do |key, child|
        normalized[normalize_context_key(key)] = normalize_context(child, depth + 1, seen)
      end
      seen.delete(value)
      normalized
    end

    def normalize_array(value, depth, seen)
      return "[Circular]" if seen.key?(value)

      seen[value] = true
      normalized = value.first(CONTEXT_ARRAY_LIMIT).map do |child|
        normalize_context(child, depth + 1, seen)
      end
      seen.delete(value)
      normalized
    end

    def normalize_context_key(key)
      truncate_bytes(key.to_s, 256)
    end

    def stringify(hash)
      out = {}
      hash.each do |key, value|
        next if value.nil?

        key = key.to_s
        out[key] = value.is_a?(String) ? value : value.to_s
      end
      out
    end

    def truncate_bytes(str, limit)
      s = str.to_s
      return s if s.bytesize <= limit

      s.byteslice(0, limit).to_s.scrub("")
    end
  end
end
