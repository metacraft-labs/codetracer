# Go test research notes (M11)

## Detection

- Project: `go.mod`.
- File: `*_test.go`.
- Source discovery: parse exported `func TestXxx(t *testing.T)`,
  `func BenchmarkXxx(b *testing.B)`, and simple `t.Run("name", ...)`
  subtests inside discovered tests.

## Commands

- Project: `go test ./...`.
- File/package: `go test .` from the package directory.
- Single test: `go test . -run '^TestName$' -v`.
- Subtest: `go test . -run '^TestName$/^Subtest name$' -v`.
- Benchmark: `go test . -run '^$' -bench '^BenchmarkName$'`.

## Discovery and locations

`go test` does not have a stable built-in JSON discovery mode for all tests and
subtests without running them. M11 uses source parsing for exact top-level
function lines and medium-confidence subtest call locations.

## Results and output

`go test` can emit JSON with `-json`, but M11 normalizes command-level pass/fail
events from the process result. Per-test output/status parsing can be added by
mapping `Action` events from `go test -json` to catalog selectors.

## Recording

Run support is enabled. Recording is reported unsupported in M11 because
`go test` compiles an ephemeral test binary and CodeTracer does not yet expose a
stable provider path for recording that generated executable while preserving
single-test selectors.

## Limitations

- Dynamic subtest names are not discovered.
- Nested subtest selectors beyond simple `t.Run("literal", ...)` are not
  guaranteed.
- Single-test recording returns a precise unsupported diagnostic.
