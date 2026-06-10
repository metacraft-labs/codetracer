import unittest


TEXT = """
class FakeCase(unittest.TestCase):
    def test_from_string(self):
        self.fail("not real")
"""

RAW_TEXT = r"""
class RawFakeCase(unittest.TestCase):
    def test_from_raw_string(self):
        self.fail("not real")
"""


# class CommentedCase(unittest.TestCase):
#     def test_from_comment(self):
#         self.fail("not real")


class CalculatorCase(unittest.TestCase):
    def test_adds(self):
        self.assertEqual(1 + 1, 2)

    def testCamelCaseName(self):
        self.assertTrue(True)

    @unittest.skip("fixture skip marker")
    def test_skipped(self):
        self.fail("skip should be represented only as a tag")

    def helper(self):
        pass


class AsyncCalculatorCase(unittest.IsolatedAsyncioTestCase):
    async def test_async_method(self):
        self.assertTrue(True)


class NotATestCase:
    def test_not_unittest(self):
        raise AssertionError("not a unittest case")
