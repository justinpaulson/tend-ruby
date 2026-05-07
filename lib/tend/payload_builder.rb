require "time"

module Tend
  module PayloadBuilder
    MESSAGE_BYTE_LIMIT = 4_096
    STACK_TRACE_BYTE_LIMIT = 16_384
    URL_LIMIT = 2_048
    TAGS_KEY_LIMIT = 64

    module_function

    def from_exception(exception, configuration:, extra: {}, env: nil)
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
        tags: build_tags(configuration: configuration, extra: extra, env: env)
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
        tags: build_tags(configuration: configuration, extra: extra, env: nil)
      }.compact
    end

    def build_tags(configuration:, extra:, env:)
      merged = {}
      merged.merge!(stringify(configuration.tags)) if configuration.tags.is_a?(Hash)
      merged.merge!(stringify(rack_tags(env))) if env
      merged.merge!(stringify(extra)) if extra.is_a?(Hash)

      if merged.size > TAGS_KEY_LIMIT
        configuration.logger&.warn("Tend: tags exceed #{TAGS_KEY_LIMIT} keys; trimming")
        merged = merged.first(TAGS_KEY_LIMIT).to_h
      end
      merged
    end

    def rack_tags(env)
      return {} unless env
      {
        method: env["REQUEST_METHOD"],
        path: env["PATH_INFO"],
        request_id: env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
      }.compact
    end

    def build_url(env)
      return nil unless env
      scheme = env["rack.url_scheme"] || "http"
      host = env["HTTP_HOST"] || env["SERVER_NAME"]
      return nil if host.nil? || host.to_s.empty?
      port = env["SERVER_PORT"]
      port_part = if port.nil? || (scheme == "http" && port.to_s == "80") || (scheme == "https" && port.to_s == "443") || host.to_s.include?(":")
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

    def stringify(hash)
      out = {}
      hash.each do |k, v|
        next if v.nil?
        out[k.to_s] = v.is_a?(String) ? v : v.to_s
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
