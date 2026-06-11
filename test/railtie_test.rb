require_relative "test_helper"

begin
  require "rails"
  require "tend/railtie"
  HAS_RAILS = true
rescue LoadError
  HAS_RAILS = false
end

class RailtieTest < Minitest::Test
  def setup
    skip "rails not loaded" unless HAS_RAILS
    Tend.reset_configuration!
  end

  def test_railtie_class_defined
    assert defined?(Tend::Railtie)
    assert Tend::Railtie < ::Rails::Railtie
  end

  def test_initializers_registered
    names = Tend::Railtie.initializers.map(&:name)
    assert_includes names, "tend.configure_defaults"
    assert_includes names, "tend.middleware"
  end

  def test_install_middleware_inserts_before_executor_when_available
    skip "ActionDispatch::Executor not loaded" unless defined?(::ActionDispatch::Executor)

    stack = FakeMiddlewareStack.new
    Tend::Railtie.install_middleware(stack)

    assert_equal [:insert_before, ::ActionDispatch::Executor, Tend::Middleware], stack.calls.first
  end

  def test_install_middleware_falls_back_to_use_when_insert_fails
    skip "ActionDispatch::Executor not loaded" unless defined?(::ActionDispatch::Executor)

    stack = FakeMiddlewareStack.new(fail_insert: true)
    Tend::Railtie.install_middleware(stack)

    assert_equal [:insert_before, ::ActionDispatch::Executor, Tend::Middleware], stack.calls[0]
    assert_equal [:use, Tend::Middleware], stack.calls[1]
  end

  def test_install_middleware_skips_duplicate_registration
    stack = FakeMiddlewareStack.new(entries: [FakeMiddlewareEntry.new(Tend::Middleware)])
    Tend::Railtie.install_middleware(stack)

    assert_empty stack.calls
  end

  FakeMiddlewareEntry = Struct.new(:klass)

  class FakeMiddlewareStack
    include Enumerable

    attr_reader :calls

    def initialize(entries: [], fail_insert: false)
      @entries = entries
      @fail_insert = fail_insert
      @calls = []
    end

    def each(&block)
      @entries.each(&block)
    end

    def insert_before(target, middleware)
      @calls << [:insert_before, target, middleware]
      raise "missing target" if @fail_insert

      @entries << FakeMiddlewareEntry.new(middleware)
    end

    def use(middleware)
      @calls << [:use, middleware]
      @entries << FakeMiddlewareEntry.new(middleware)
    end
  end
end
