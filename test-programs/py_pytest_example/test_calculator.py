"""Simple pytest test file for ct record-test integration testing."""


def add(a: int, b: int) -> int:
    """Add two numbers."""
    return a + b


def multiply(a: int, b: int) -> int:
    """Multiply two numbers."""
    return a * b


def test_add_positive():
    """Test adding positive numbers."""
    result = add(2, 3)
    assert result == 5


def test_add_negative():
    """Test adding negative numbers."""
    result = add(-1, -2)
    assert result == -3


def test_multiply():
    """Test multiplication."""
    result = multiply(4, 5)
    assert result == 20


class TestCalculatorClass:
    """Test class for grouping calculator tests."""

    def test_add_zero(self):
        """Test adding zero."""
        assert add(5, 0) == 5

    def test_multiply_zero(self):
        """Test multiplying by zero."""
        assert multiply(5, 0) == 0
