require "net/http"
require "uri"
require "json"

module Tend
  class Transport
    QUEUE_LIMIT = 100
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 2

    class << self
      def instance
        @instance ||= new
      end

      def reset!
        @instance&.shutdown
        @instance = nil
      end

      attr_writer :synchronous

      def synchronous?
        @synchronous == true
      end
    end

    def initialize
      @mutex = Mutex.new
      @queue = nil
      @worker = nil
      @at_exit_registered = false
    end

    def enqueue(payload)
      if self.class.synchronous?
        deliver(payload)
        return
      end

      @mutex.synchronize do
        @queue ||= SizedQueue.new(QUEUE_LIMIT)
        ensure_worker
        register_at_exit
      end

      if @queue.size >= QUEUE_LIMIT
        log_warn("Tend: dropping event, queue full")
        return
      end

      begin
        @queue.push(payload, true)
      rescue ThreadError
        log_warn("Tend: dropping event, queue full")
      end
    end

    def flush(timeout: 2)
      return unless @queue

      deadline = Time.now + timeout
      while !@queue.empty? && Time.now < deadline
        sleep 0.05
      end
    end

    def shutdown
      worker = @worker
      @worker = nil
      worker&.kill
      @queue = nil
    end

    def deliver(payload)
      cfg = Tend.configuration
      return unless cfg.valid?

      uri = URI.parse(cfg.ingest_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.use_ssl = (uri.scheme == "https")

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["X-Tend-Ingest-Token"] = cfg.ingest_token.to_s
      req["User-Agent"] = "tend-ruby/#{Tend::VERSION}"
      req.body = JSON.generate(payload)

      response = http.request(req)
      code = response.code.to_i
      unless code >= 200 && code < 300
        log_warn("Tend: ingest returned #{code}: #{response.body.to_s[0, 500]}")
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
           Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError, IOError => e
      log_warn("Tend: ingest network error #{e.class}: #{e.message}")
    rescue StandardError => e
      log_warn("Tend: ingest failed #{e.class}: #{e.message}")
    end

    private

    def ensure_worker
      return if @worker&.alive?

      queue = @queue
      @worker = Thread.new do
        Thread.current.report_on_exception = false
        loop do
          payload = queue.pop
          break if payload.equal?(:__shutdown__)
          begin
            deliver(payload)
          rescue StandardError => e
            log_warn("Tend: worker error #{e.class}: #{e.message}")
          end
        end
      end
    end

    def register_at_exit
      return if @at_exit_registered
      @at_exit_registered = true
      at_exit do
        begin
          flush(timeout: 2)
        rescue StandardError
          nil
        end
      end
    end

    def log_warn(msg)
      logger = Tend.configuration.logger
      logger&.warn(msg)
    rescue StandardError
      nil
    end
  end
end
