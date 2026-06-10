import pytest


def helper():
    return "def test_not_real(): pass"


COMMENT_TEXT = """
def test_from_string():
    assert False

class TestFromString:
    def test_nested_string(self):
        assert False
"""

RAW_COMMENT_TEXT = r"""
def test_from_raw_string():
    assert False
"""


# def test_from_comment():
#     assert False


def test_plain():
    assert helper()


def testCamelCaseName():
    assert True


async def test_async_function():
    assert True


@pytest.mark.skip(reason="fixture skip marker")
def test_skipped_marker():
    assert True


@pytest.mark.xfail(reason="fixture xfail marker")
def test_expected_failure():
    assert False


@pytest.mark.parametrize("value", [1, 2])
def test_parametrized(value):
    assert value > 0


class TestArithmetic:
    def test_adds(self):
        assert 1 + 1 == 2

    async def test_async_method(self):
        assert True

    @pytest.mark.parametrize("value", [3, 4])
    def test_method_parametrized(self, value):
        assert value > 2

    def helper_method(self):
        pass


class HelperClass:
    def test_not_collected_by_pytest_source_slice(self):
        assert False
