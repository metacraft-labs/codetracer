require_relative "test_helper"

class CalculatorTest < Minitest::Test
  def test_adds_numbers
    assert_equal 5, 2 + 3
  end

  def test_handles_zero
    assert_equal 3, 0 + 3
  end
end

class StringFormattingTest < Minitest::Test
  def test_upcases
    assert_equal "RUBY", "ruby".upcase
  end
end

fake = "def test_from_string"
# def test_from_comment
