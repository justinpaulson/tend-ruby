module Tend
  class ErrorSubscriber
    def report(error, handled:, severity: nil, context: nil, source: nil)
      return if handled
      extra = context.is_a?(Hash) ? context : {}
      Tend.capture_exception(error, extra: extra)
    rescue StandardError
      nil
    end
  end
end
