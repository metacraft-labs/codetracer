# simple_trivial_chain — Python
# a=10; b=a; c=b — origin chain terminates at Literal.
#
# The Value Origin query targets `c` at the print line. The chain must
# walk: c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).


def main() -> None:
    a = 10
    b = a
    c = b
    print(c)


if __name__ == "__main__":
    main()
