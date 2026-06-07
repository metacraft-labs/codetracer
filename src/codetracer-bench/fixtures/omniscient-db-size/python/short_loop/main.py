# omniscient-db-size / python / short_loop
#
# Profile: a small fixed loop (~100 iterations) doing trivial integer
# arithmetic. Models a CLI helper whose recording is tiny — the
# benchmark uses this row to establish the per-language overhead
# floor (manifest bytes + a handful of step events).
#
# Run length target: ~1000 events.


def main() -> None:
    total = 0
    for i in range(100):
        total = total + i * 2
    print(total)


if __name__ == "__main__":
    main()
