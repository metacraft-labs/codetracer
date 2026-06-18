# python_materialized — benchmark workload.
#
# Drives the materialised indexer benchmark per spec §6.8.6.4/§6.8.6.5.
# The workload spans ~1 K value changes across an arithmetic accumulator
# loop so the benchmark can pin:
#
#   * Mode 3 indexer wall-clock <= 1 s on the materialised side.
#   * Mode 3 compressed storage overhead <= 5 % of baseline.
#   * Mode 3 ct/originSummary p50 <= 60 us, ct/originChain p50 <= 200 us.
#
# The number of iterations is intentionally a power of two so the
# trace's step count is stable across reruns.

ITERATIONS = 1024


def chain_step(accum: int, idx: int) -> int:
    forwarded = accum
    bumped = forwarded + idx
    return bumped


def main() -> None:
    accum = 0
    for i in range(ITERATIONS):
        accum = chain_step(accum, i)
    print(accum)


if __name__ == "__main__":
    main()
