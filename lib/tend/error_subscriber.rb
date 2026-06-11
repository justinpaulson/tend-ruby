module Tend
  class ErrorSubscriber
    def report(error, handled:, severity: nil, context: nil, source: nil)
      return if handled
      return if Tend::RequestContext.captured?(error)

      Tend.capture_exception(
        error,
        env: Tend::RequestContext.current_env,
        rails_error: {
          handled: handled,
          severity: severity,
          source: source,
          context: context
        }
      )
    rescue StandardError
      nil
    end
  end
end
