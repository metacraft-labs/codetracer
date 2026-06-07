# omniscient-db-size / python / mid_length_compute
#
# Profile: a mid-length compute-bound workload — repeatedly hashes
# rolling buffers and merges intermediate state. Models a typical
# data-pipeline cell (~100 KB working set, ~10 K events).  P3 also
# reuses this fixture as its default mid-length program.


import hashlib


def fold(state: bytes, chunk: bytes) -> bytes:
    h = hashlib.sha256()
    h.update(state)
    h.update(chunk)
    return h.digest()


def main() -> None:
    state = b"seed"
    accum = 0
    chunks = [bytes((j % 251 for j in range(i, i + 64))) for i in range(64)]
    for round_idx in range(200):
        for chunk in chunks:
            state = fold(state, chunk)
            accum = (accum + state[0]) & 0xFFFF
    print(accum, len(state))


if __name__ == "__main__":
    main()
