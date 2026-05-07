module Tend
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env)
    rescue Exception => e # rubocop:disable Lint/RescueException
      Tend.capture_exception(e, env: env) unless Tend.ignored?(e)
      raise
    end
  end
end
