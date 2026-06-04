# return_capture — Python
# A value captured from a function's return; the origin chain crosses
# the return boundary and lands at a Computational hop inside the callee.


def compute() -> int:
    a = 3
    b = 4
    return a + b


def main() -> None:
    captured = compute()
    print(captured)


if __name__ == "__main__":
    main()
