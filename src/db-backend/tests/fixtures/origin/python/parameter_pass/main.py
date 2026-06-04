# parameter_pass — Python
# A value is passed across a function boundary; the origin chain crosses
# the call site, then terminates at the Literal where the source was
# assigned.


def receive(p: int) -> None:
    local = p
    print(local)


def main() -> None:
    value = 7
    receive(value)


if __name__ == "__main__":
    main()
