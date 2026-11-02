"""Nested calls followed by sibling calls, for the call-trace collapse tests.

The shape mirrors codetracer#811: `main` calls `assert_in_range`, and after
`main` returns more top-level calls follow. Collapsing `main` hides
`assert_in_range` and moves every later call up a row, so a current-call mark
kept by row position would land on `report_total`.
"""


def assert_in_range(value: int, low: int, high: int) -> int:
    assert low <= value <= high
    return value


def main() -> int:
    return assert_in_range(5, 0, 10)


def report_total(total: int) -> None:
    print(f"total: {total}")


def report_done() -> None:
    print("done")


result = main()
report_total(result)
report_done()
