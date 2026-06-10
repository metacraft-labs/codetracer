import std/[strutils, unittest]

const fakeText = """
suite "not real suite":
  test "not real test":
    discard
"""

# suite "commented suite":
#   test "commented test":
#     discard

#[
suite "block commented suite":
  test "block commented test":
    discard
]#

type FutureLike = object

proc asyncShape(): FutureLike =
  FutureLike()

suite "math":
  test "adds numbers":
    discard asyncShape()
    check 1 + 1 == 2

  test "fails intentionally":
    check 2 + 2 == 5

  test "skips conditionally":
    skip()

  suite "nested":
    test "inner case":
      check true

suite "strings":
  test "contains colon::and spaces":
    check "abc".contains("b")

test "top level case":
  check true
