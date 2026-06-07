# omniscient-db-size / python / io_heavy
#
# Profile: stresses the recorder's I/O path. Writes + reads back a
# series of small files, exercising syscalls (and therefore the
# recorder's syscall capture rate). Models a build-tool's
# scratch-directory churn.


import os
import tempfile


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="ct-bench-io-") as scratch:
        sizes = []
        for i in range(64):
            path = os.path.join(scratch, f"chunk_{i:02d}.bin")
            payload = (b"abcdefgh" * (i + 1))
            with open(path, "wb") as fh:
                fh.write(payload)
            with open(path, "rb") as fh:
                sizes.append(len(fh.read()))
        print(sum(sizes))


if __name__ == "__main__":
    main()
