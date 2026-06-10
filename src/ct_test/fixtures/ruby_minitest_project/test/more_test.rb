require_relative "test_helper"

class MoreRubyTest < Minitest::Test
  def test_more_method
    assert_equal 4, 2 * 2
  end
end
