require "tend/version"
require "tend/configuration"
require "tend/payload_builder"
require "tend/transport"
require "tend/middleware"
require "tend/error_subscriber"

module Tend
  class << self
    def configure
      yield(configuration) if block_given?
      unless configuration.valid?
        configuration.enabled = false
        configuration.logger&.warn("Tend: ingest_token missing — SDK disabled")
      end
      configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def reset_configuration!
      @configuration = nil
    end

    def capture_exception(exception, extra: {}, env: nil)
      return unless configuration.valid?
      return if ignored?(exception)
      payload = PayloadBuilder.from_exception(exception, configuration: configuration, extra: extra, env: env)
      payload = configuration.before_send.call(payload) if configuration.before_send
      return if payload.nil?
      Transport.instance.enqueue(payload)
    rescue StandardError => e
      configuration.logger&.warn("Tend: capture_exception failed: #{e.class}: #{e.message}")
      nil
    end

    def capture_message(message, level: "error", extra: {})
      return unless configuration.valid?
      payload = PayloadBuilder.from_message(message, level: level, configuration: configuration, extra: extra)
      payload = configuration.before_send.call(payload) if configuration.before_send
      return if payload.nil?
      Transport.instance.enqueue(payload)
    rescue StandardError => e
      configuration.logger&.warn("Tend: capture_message failed: #{e.class}: #{e.message}")
      nil
    end

    def ignored?(exception)
      names = exception.class.ancestors.map { |a| a.respond_to?(:name) ? a.name : nil }.compact
      configuration.ignored_exceptions.any? { |n| names.include?(n) }
    end

    def flush(timeout: 2)
      Transport.instance.flush(timeout: timeout)
    end
  end
end

require "tend/railtie" if defined?(::Rails::Railtie)
