$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "webmock/minitest"
require "logger"
require "stringio"
require "tend"

WebMock.disable_net_connect!(allow_localhost: true)

module TendTestHelpers
  def fresh_config!(token: "tok_test", logger: nil)
    Tend.reset_configuration!
    Tend::Transport.reset!
    Tend::Transport.synchronous = true
    Thread.current[:tend_user] = nil
    Tend.configure do |c|
      c.ingest_token = token
      c.logger = logger || Logger.new(StringIO.new)
      c.tags = {}
    end
  end

  def teardown
    Tend::Transport.reset!
    Tend::Transport.synchronous = false
    Tend.reset_configuration!
    Thread.current[:tend_user] = nil
    super
  end
end

Minitest::Test.include(TendTestHelpers)
