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
  end

end
