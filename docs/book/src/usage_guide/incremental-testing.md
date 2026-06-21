# Incremental Testing

**Trace-based incremental testing** makes a test suite re-run only the
tests that a code change can actually affect. `ct test --incremental`
records what each test does the first time it runs, and on later runs it
**skips a test whenever none of the functions that test executed have
changed**. A test that did not touch any of the code you edited cannot
produce a different result, so there is no reason to run it again.

This is the standalone, productized form of CodeTracer's runtime-dependency
test selection: it works on its own, without any external build system.

## What it does

The idea comes directly from CodeTracer's recorded traces:

1. The first time a test runs, `ct test` records a trace of it and remembers
   **which functions it executed**, together with a hash of each of those
   functions.
2. On a later run, `ct test` looks at the test's recorded baseline. If every
   function the test executed still hashes the same, the test's result
   cannot have changed, so it is **skipped**.
3. If a function the test *did* execute has changed, the test is **re-run**
   and a fresh baseline is recorded.

Code you changed that the test never ran — a different module, an unexecuted
branch, a helper the test never reached — does not force a re-run.

## Using it

```bash
ct test --incremental --language <python|ruby> --program <path> \
    [--source-root DIR] [--cache PATH] [--id TESTID]
```

| Flag | Meaning |
|------|---------|
| `--language` | The language of the program under test. Live-validated: `python`. Wired: `ruby`. |
| `--program` | Path to the test program to record and decide on. |
| `--source-root` | Root used to resolve the executed functions' source for hashing. Defaults to `/` (trace-recorded paths are absolute). |
| `--cache` | Where the per-test baseline (executed functions + hashes) is stored, so a later run can compare against it. |
| `--id` | A stable identifier for the test, used as the cache key and in the report. |

Each run reports one of:

- **`run (fresh baseline: <id>)`** — no baseline existed yet, so the test ran
  and its baseline was recorded.
- **`skipped (unchanged: <id>)`** — every function the test executed is
  unchanged; the test was not re-run.
- **`re-run (changed: <id> — functions: …)`** — a function the test executed
  changed; the test was re-run and the changed functions are named.

The existing `ct test e2e …` surface is unaffected — only the explicit
`--incremental` token switches into the incremental selector.

## Per-language support

| Language | Status |
|----------|--------|
| Python | ✅ Live-validated end-to-end (record → decide → skip/re-run). |
| Ruby | 🔌 Wired on the same path (drives the production Ruby recorder); not yet covered by an automated end-to-end test. |
| Other interpreted languages (JavaScript/TypeScript, …) | The same CTFS source-text mechanism applies as their recorders are wired in. |
| Native (C/C++/Rust) | Supported in the engine via compile-time instrumentation (the `ct_instrument` call-trace facet) plus instruction-byte hashing; not exposed on this CLI yet, so a native program is rejected up front rather than silently skipped. |

The selection is **fail-safe**: any ambiguity — a recorder that cannot run, an
unreadable trace, a missing or malformed baseline, an unsupported language —
results in a **re-run**, never a false skip. A test is skipped only when
CodeTracer can prove the functions it executed are unchanged.

## How the decision is made

For each test, `ct test` derives the **executed-function set** from the
function and call records in the CTFS (`.ct`) trace the recorder produces, then
computes a **per-function shallow hash**. A test is skipped only when *every*
executed function hashes identically to its recorded baseline.

The hash adapts to the language so the comparison is precise:

- **Interpreted languages (Python, Ruby, JavaScript/TypeScript):** a hash of
  the function's **source text**, read from the CTFS trace. For these recorders
  a function's identity is its source body.
- **Native (compiled C/C++/Rust):** a hash of the function's **compiled
  instruction bytes**, so a change that alters codegen is caught even when the
  source line looks the same. The executed-function set comes from a
  compile-time-instrumentation capture (`-finstrument-functions` via the
  `ct_instrument` call-trace facet); the hash runs over a clean,
  non-instrumented build.

Because the baseline records both *which* functions ran and *what* they
contained, an edit anywhere outside that executed set is provably irrelevant to
the test and is skipped.

## See also

- [Tracepoints](./tracepoints.md) and the rest of this Usage guide for the
  other CLI-driven CodeTracer workflows.
- The same technique is available under the reprobuild watcher as
  `repro watch --ct-incremental`, which applies incremental skipping to watched
  test edges during a build.
