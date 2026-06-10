# Adding a ct-test Provider

This is the release-gated checklist for adding a new language or framework
provider to `ct test`.

## Research

Add a short research note under `src/ct_test/framework_research/` before
adding code. It should state:

- framework discovery commands and stable machine-readable output, if any
- source location strategy and expected confidence level
- run and record command templates
- trace entry-point mapping strategy
- unsupported modes and the diagnostic users should see
- required toolchains, recorder binaries, and any heavy CI dependencies

## Provider Contract

Add the provider implementation under `src/ct_test/frameworks/` and register it
in `newDefaultProviderRegistry()`. Capability flags must be exact:

- Set discovery flags only for scopes the provider can populate.
- Set run flags only when `run` emits structured `TestEvent` data or a clear
  diagnostic for unsupported runtime execution.
- Set record flags only when `record` can create a non-empty trace artifact and
  emit `tekRecordingCreated`.
- Set `canMapTraceEntryPoints` only when trace metadata can be mapped back to
  catalog item ids.

Conditional or toolchain-heavy providers must make the condition explicit in
diagnostics and tests. Do not expose GUI actions for unsupported capabilities.

## Fixtures And Trace Smoke

Every provider needs a representative fixture under `src/ct_test/fixtures/` or,
for sibling recorder harnesses, explicit release-gate metadata pointing to the
heavy fixture test. The provider test must cover discovery and every declared
run/record capability. Record-capable providers must verify that a non-empty
trace artifact exists and that the event stream validates.

Update `src/ct_test/release_gate.nim` with the provider fixture, research note,
test file, and source files. Then regenerate `docs/ct-test-support-matrix.md`
by running `just test-m16-release-gate`; the test fails if the matrix drifts.

## Launcher-backed ct test

Use launcher-backed commands in docs and workflows:

```bash
ct test discover --workspace . --json
ct test discover --file path/to/test_file --json
ct test run --test <selector>
ct test record --test <selector>
```

Direct `ct-test-runner` or `ct-test` binary invocation is legacy-only for
low-level development and compile checks. CI and user-facing docs should go
through `ct test` so launcher path resolution, component selection, and recorder
environment handling match installed CodeTracer behavior.

## Release Gate

Run:

```bash
just test-m16-release-gate
```

The gate fails on:

- provider registry entries missing release-gate metadata
- stale support matrix or catalog schema fixture versions
- declared capabilities without fixture, research, provider tests, or source
  coverage
- record-capable providers that do not verify trace artifact creation
- skipped core ViewModel tests
- visible GUI actions that only have mock coverage and no explicit unsupported
  diagnostic
