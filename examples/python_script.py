def fibonacci(n: int) -> list[int]:
    sequence: list[int] = []
    a, b = 0, 1
    for _ in range(max(0, n)):
        sequence.append(a)
        a, b = b, a + b
    return sequence


def main() -> None:
    series = fibonacci(10)
    total = sum(series)
    print("fibonacci:", series)
    print("total:", total)


if __name__ == "__main__":
    main()
