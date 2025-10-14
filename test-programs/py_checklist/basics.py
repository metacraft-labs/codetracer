"""Baseline language probes: literals, operators, unpacking, flow control.

Each `demo_*` function focuses on a single theme so traces remain easy to
scan. Demos print numbered lines to make missing console events obvious.
"""

from __future__ import annotations


def demo_1_literals() -> None:
    """Show the range of literal syntax available in modern Python.

    Literals configure built-in objects without constructor calls, which
    is prevalent in configuration-heavy code paths.
    """
    a = 1_000_000  # underscores improve readability for large integers (PEP 515).
    b = 3.14  # floating point literal.
    c = 1 + 2j  # complex number literal used in scientific workloads.
    s = r"C:\path\to\file"  # raw string avoids needing to escape backslashes.
    bs = b"hello"  # bytes literal for binary protocols.
    name = "Ada"
    debug = f"{name=}"  # f-string with debug repr (PEP 498).
    e = ...  # Ellipsis literal used by type checkers and placeholder APIs.
    pos_inf = float("inf")
    neg_inf = float("-inf")
    nan = float("nan")
    empty_list, empty_dict, empty_set = [], {}, set()
    truthy_if_len = bool([0]) and not bool([])

    print(
        "1. literals:",
        a,
        b,
        c,
        s,
        bs,
        debug,
        e,
        pos_inf,
        neg_inf,
        nan != nan,  # NaN is never equal to itself; highlight the pitfall.
        empty_list,
        empty_dict,
        empty_set,
        truthy_if_len,
        sep=" | ",
    )


def demo_2_operators() -> None:
    """Exercise arithmetic and bitwise operators including corner cases."""
    # Floor division and modulo with negatives behave differently than many languages;
    # we capture the values for debugging numeric code.
    floor_mod = (7 // -3, 7 % -3)
    power = 2**5  # exponentiation.
    bits = (5 & 3, 5 | 3, 5 ^ 3, 5 << 1, 5 >> 1, ~5)
    print("2. operators:", floor_mod, power, bits, sep=" | ")


def demo_3_comparisons() -> None:
    """Compare chaining, identity, and membership semantics."""
    a, b, c = 1, 2, 3
    chained = a < b < c  # only true when both comparisons succeed.
    same = (a is a) and (a is not b)  # identity comparisons on small ints.
    mem = 2 in [1, 2, 3]  # membership leveraging sequence iteration.
    print("3. comparisons:", chained, same, mem, sep=" | ")


def demo_4_expressions() -> None:
    """Highlight ternary, lambda, walrus operator, and starred unpacking."""
    x = 10
    small = "yes" if x < 5 else "no"
    f = lambda y: y + 1  # small inline function, common in callback APIs.
    if (n := len("abc")) > 2:
        z = n  # walrus stores the length while evaluating the condition.
    seq = list(range(10))
    part = seq[1:8:2]
    rev = seq[::-1]  # idiomatic list reversal.
    slc = slice(2, None, 3)
    by_three = seq[slc]
    head, *mid, tail = range(5)  # starred unpacking pulls the middle values.
    merged = [*range(2), *range(2, 4)]  # iterable unpacking (PEP 448).
    d = {"x": 1, "y": 2}
    d2 = {**d, "y": 99, "z": 3}  # dict unpacking override.
    print(
        "4. expressions:",
        small,
        f(10),
        z,
        part,
        rev,
        by_three,
        head,
        mid,
        tail,
        merged,
        d2,
        sep=" | ",
    )


def demo_5_flow_control() -> None:
    """Cover loop `else` clauses and structural pattern matching."""
    for_result = []
    for n in range(3):
        for_result.append(n)
    else:
        for_result.append("loop-complete")  # runs because no break occurred.

    m = 0
    while_result = []
    while m < 2:
        while_result.append(m)
        m += 1
    else:
        while_result.append("loop-finished")  # executes once condition is false.

    def match_demo(value: object) -> str | tuple:
        """Structural pattern matching introduced in Python 3.10."""
        match value:
            case 0:
                return "zero"
            case [a, b, *rest] if a < b:
                return ("seq", a, b, rest)
            case {"k": v}:
                return ("map", v)
            case complex(real=r, imag=i):
                return ("complex", r, i)
            case _:
                return "other"

    print(
        "5. flow:",
        for_result,
        while_result,
        match_demo(0),
        match_demo([1, 2, 3]),
        match_demo({"k": 9}),
        match_demo(1 + 2j),
        match_demo("fallback"),
        sep=" | ",
    )


def run_all() -> None:
    """Execute each demo; intended entry point for the checklist runner."""
    demo_1_literals()
    demo_2_operators()
    demo_3_comparisons()
    demo_4_expressions()
    demo_5_flow_control()


if __name__ == "__main__":
    run_all()
