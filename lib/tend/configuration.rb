require "logger"
require "socket"

module Tend
  class Configuration
    DEFAULT_INGEST_URL = "https://tend.justinpaulson.com/api/error_events".freeze
    DEFAULT_IGNORED_EXCEPTIONS = [
      "ActiveRecord::RecordNotFound",
      "ActionController::RoutingError",
      "AbstractController::ActionNotFound",
      "ActionController::BadRequest",
      "ActionController::ParameterMissing"
    ].freeze

    attr_accessor :ingest_token, :ingest_url, :release, :environment,
                  :tags, :before_send, :ignored_exceptions, :logger, :enabled, :user

    def initialize
      @ingest_token = nil
      @ingest_url = DEFAULT_INGEST_URL
      @release = nil
      @environment = nil
      @tags = { hostname: safe_hostname }
      @before_send = ->(payload) { payload }
      @ignored_exceptions = DEFAULT_IGNORED_EXCEPTIONS.dup
      @logger = default_logger
      @enabled = true
      @user = nil
    end

    def valid?
      enabled && !ingest_token.to_s.empty?
    end

    private

    def default_logger
      if defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger
        ::Rails.logger
      else
        ::Logger.new($stdout)
      end
    end

    def safe_hostname
      Socket.gethostname
    rescue StandardError
      nil
    end
  end
end
