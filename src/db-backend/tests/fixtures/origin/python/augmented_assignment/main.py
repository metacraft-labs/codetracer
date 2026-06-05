# augmented_assignment - Python
# `total += i` is canonically Computational per spec §7.2 (Python override).
# The classifier rewrites `total += i` as `total = total + i` and reports a
# Computational origin whose RHS operand snapshots are `total` and `i`.


def main() -> None:
    total = 0
    i = 5
    total += i
    print(total)


if __name__ == "__main__":
    main()
