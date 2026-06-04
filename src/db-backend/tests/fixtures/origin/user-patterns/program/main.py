# user-patterns program fixture
#
# This program depends on the faux library at
# ../faux-library/, which ships a `.codetracer/origin-patterns.toml`
# marking the `forward()` wrapper as a TrivialCopy forwarder with
# continuation `$value`.
#
# At record time, the recorder discovers the pattern file in the
# dependency root and embeds it under meta_dat/origin-patterns/ in the
# resulting trace. At query time, an origin query against `result`
# walks: result -> forward(payload) -> [TrivialCopy via faux_lib pattern]
# -> payload -> 42 (Literal).
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "faux-library"))

from faux_lib import forward  # type: ignore


def main() -> None:
    payload = 42
    result = forward(payload)
    print(result)


if __name__ == "__main__":
    main()
