module Tend
  class Railtie < ::Rails::Railtie
    initializer "tend.configure_defaults", before: :load_config_initializers do
      Tend.configuration.environment ||= ::Rails.env if defined?(::Rails)
      Tend.configuration.logger ||= ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
    end

    initializer "tend.middleware", after: :load_config_initializers do |app|
      if Tend.configuration.valid?
        app.middleware.use(Tend::Middleware)
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
  end
end
