module Tend
  module RequestContext
    THREAD_KEY = :tend_request_context
    CAPTURED_MARKER = :@__tend_captured

    module_function

    def with_env(env)
      previous = Thread.current[THREAD_KEY]
      captured = previous && previous[:captured_exception_ids]
      Thread.current[THREAD_KEY] = {
        env: env,
        captured_exception_ids: captured || {}.compare_by_identity
      }
      yield
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    def current_env
      state = Thread.current[THREAD_KEY]
      state && state[:env]
    end

    def clear!
      Thread.current[THREAD_KEY] = nil
    end

    def captured?(exception)
      exception_chain(exception).any? do |chain_exception|
        captured_exception_ids.key?(chain_exception) || marked?(chain_exception)
      end
    end

    def mark_captured(exception)
      exception_chain(exception).each do |chain_exception|
        captured_exception_ids[chain_exception] = true
        mark_exception(chain_exception)
      end
    end

    def exception_chain(exception)
      chain = []
      seen = {}.compare_by_identity
      current = exception

      while current && !seen.key?(current)
        seen[current] = true
        chain << current
        current = current.respond_to?(:cause) ? current.cause : nil
      end

      chain
    end

    def captured_exception_ids
      state = Thread.current[THREAD_KEY]
      return {} unless state

      state[:captured_exception_ids] ||= {}.compare_by_identity
    end

    def marked?(exception)
      exception.instance_variable_defined?(CAPTURED_MARKER)
    rescue StandardError
      false
    end

    def mark_exception(exception)
      exception.instance_variable_set(CAPTURED_MARKER, true)
    rescue StandardError
      nil
    end
  end
end
