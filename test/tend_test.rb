require_relative "test_helper"

class TendTest < Minitest::Test
  URL = "https://tend.justinpaulson.com/api/error_events".freeze

  def setup
    fresh_config!
    Thread.current[:tend_user] = nil
  end

  def test_set_user_sets_configuration_user
    Tend.set_user(id: "1", email: "a@b")
    assert_equal({ id: "1", email: "a@b" }, Tend.configuration.user)
  end

  def test_set_user_includes_extras
    Tend.set_user(id: "1", email: "a@b", plan: "pro")
    assert_equal "pro", Tend.configuration.user[:plan]
  end

  def test_clear_user_resets_global
    Tend.set_user(id: "1", email: "a@b")
    Tend.clear_user
    assert_nil Tend.configuration.user
  end

  def test_clear_user_does_not_touch_thread_local
    Thread.current[:tend_user] = { id: "tl", email: "t@l" }
    Tend.clear_user
    assert_equal({ id: "tl", email: "t@l" }, Thread.current[:tend_user])
  end

  def test_with_user_sets_thread_local_inside_block
    observed = nil
    Tend.with_user(id: "1", email: "a@b") { observed = Thread.current[:tend_user] }
    assert_equal({ id: "1", email: "a@b" }, observed)
  end

  def test_with_user_restores_prior_value
    Thread.current[:tend_user] = { id: "outer", email: "o@x" }
    Tend.with_user(id: "inner", email: "i@x") {}
    assert_equal({ id: "outer", email: "o@x" }, Thread.current[:tend_user])
  end

  def test_with_user_restores_on_exception
    Thread.current[:tend_user] = { id: "outer", email: "o@x" }
    assert_raises(RuntimeError) do
      Tend.with_user(id: "inner", email: "i@x") { raise "boom" }
    end
    assert_equal({ id: "outer", email: "o@x" }, Thread.current[:tend_user])
  end

  def test_with_user_returns_block_value
    result = Tend.with_user(id: "1", email: nil) { 42 }
    assert_equal 42, result
  end

  def test_with_user_clears_thread_local_when_no_prior_value
    Tend.with_user(id: "1", email: "a@b") {}
    assert_nil Thread.current[:tend_user]
  end

  def test_with_user_thread_isolation
    entered = Queue.new
    go = Queue.new
    results = Queue.new

    t_a = Thread.new do
      Tend.with_user(id: "tA", email: "a@x") do
        entered << :a
        go.pop
        results << [:a, Thread.current[:tend_user]]
      end
    end

    t_b = Thread.new do
      Tend.with_user(id: "tB", email: "b@x") do
        entered << :b
        go.pop
        results << [:b, Thread.current[:tend_user]]
      end
    end

    2.times { entered.pop }
    2.times { go << :go }
    [t_a, t_b].each(&:join)

    observed = {}
    2.times { name, user = results.pop; observed[name] = user }

    assert_equal({ id: "tA", email: "a@x" }, observed[:a])
    assert_equal({ id: "tB", email: "b@x" }, observed[:b])
  end

  def test_capture_exception_payload_includes_user
    stub_request(:post, URL).to_return(status: 202, body: "{}")
    Tend.with_user(id: "u1", email: "x@y.com") do
      Tend.capture_exception(RuntimeError.new("boom"))
    end

    assert_requested(:post, URL) do |req|
      body = JSON.parse(req.body)
      assert_equal "u1", body["user"]["id"]
      assert_equal "x@y.com", body["user"]["email"]
      true
    end
  end
end
