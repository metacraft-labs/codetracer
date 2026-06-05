# walrus_in_condition - Python
# `if (n := compute()) > 0:` binds `n` via the walrus operator from a
# function-return capture. Per spec §7.2 Python override, the walrus binding
# inherits the RHS classification - here ReturnCapture.


def compute() -> int:
    a = 3
    b = 4
    return a + b


def main() -> None:
    if (n := compute()) > 0:
        result = n
        print(result)


if __name__ == "__main__":
    main()
