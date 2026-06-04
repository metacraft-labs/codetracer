# destructuring_or_index — Python
# Tuple destructuring + index access: both shapes exercise the
# "structural projection is a trivial copy" rule.


def main() -> None:
    pair = (11, 22)
    first, second = pair  # destructuring
    indexed = pair[1]     # index access
    print(first, second, indexed)


if __name__ == "__main__":
    main()
