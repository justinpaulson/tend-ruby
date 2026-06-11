module Tend
  class Railtie < ::Rails::Railtie
    initializer "tend.configure_defaults", before: :load_config_initializers do
      Tend.configuration.environment ||= ::Rails.env if defined?(::Rails)
      Tend.configuration.logger ||= ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
    end

    initializer "tend.middleware", after: :load_config_initializers do |app|
      if Tend.configuration.valid?
        Tend::Railtie.install_middleware(app.middleware)
      else
        logger = (defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil) || Tend.configuration.logger
        logger&.warn("Tend: ingest_token not set; SDK disabled")
      end
    end

    config.after_initialize do
      if Tend.configuration.valid? && defined?(::Rails) && ::Rails.respond_to?(:error) && ::Rails.error.respond_to?(:subscribe)
        ::Rails.error.subscribe(Tend::ErrorSubscriber.new)
      end
    end

    def self.install_middleware(stack)
      return if middleware_registered?(stack, Tend::Middleware)

      if defined?(::ActionDispatch::Executor)
        begin
          stack.insert_before(::ActionDispatch::Executor, Tend::Middleware)
          return
        rescue StandardError
          nil
        end
      end

      stack.use(Tend::Middleware)
    end

    def self.middleware_registered?(stack, middleware_class)
      stack.any? { |entry| middleware_entry_matches?(entry, middleware_class) }
    rescue StandardError
      false
    end

    def self.middleware_entry_matches?(entry, middleware_class)
      if entry.respond_to?(:klass)
        entry.klass == middleware_class
      else
        entry == middleware_class || entry.to_s == middleware_class.name
      end
    rescue StandardError
      false
    end
  end
end
