module Tend
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      Tend::RequestContext.with_env(env) do
        begin
          @app.call(env)
        rescue Exception => e # rubocop:disable Lint/RescueException
          unless Tend.ignored?(e) || Tend::RequestContext.captured?(e)
            Tend.capture_exception(e, env: env)
          end
          raise
        end
      end
    end
  end
end
