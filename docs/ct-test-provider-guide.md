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

## Enumerating Workspace Files

A provider must **never** call `walkDirRec` (or any other unrestricted
traversal) on the workspace root. Use `walkWorkspaceFiles(root)` from
`src/ct_test/workspace_scope.nim` instead — `import ../discovery` re-exports it:

```nim
for path in walkWorkspaceFiles(projectRoot):
  if isCandidateFile(path):
    result.add path
```

Two reasons, both learned the expensive way:

1. **Scope.** `walkWorkspaceFiles` yields only the files the workspace claims as
   its own — it honours the project's `git ls-files --cached --others
   --exclude-standard` inventory (full `.gitignore` chain, stops at nested
   checkouts, keeps untracked-but-not-ignored files) and falls back to a pruning
   filesystem walk elsewhere. A vendored upstream source tree such as
   `references/llvm-project` is therefore invisible to every provider at once,
   instead of each provider needing its own reject list — and forgetting.
2. **Cost.** `discover --workspace` runs `detect` on every registered provider
   and `discoverProject` on every one that claims the workspace. The scope is
   resolved once per invocation and shared, so N providers cost one traversal
   rather than N.

A `detect` implementation that reads file *contents* to decide whether it owns
the workspace is the most expensive probe in the registry. Prefer a project
marker (`Cargo.toml`, `go.mod`, `package.json`, …) and treat the content scan as
a last resort — and when you do scan, guard `readFile` so an unreadable file
cannot abort discovery.

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
# Vendored/ignored trees are excluded by default. To reproduce the old
# unrestricted enumeration (rarely what you want):
ct test discover --workspace . --scope unscoped --json
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

CI runs the same script in the `ct-test-release-gate` job of
`.github/workflows/codetracer.yml`, and the cross-language counterpart
(`just test-ct-providers`, which additionally builds the native/JS/Ruby
recorder siblings) in `ct-test-providers`. Both are listed in
`ci/verdict/required-jobs.txt`, so a run in which either is skipped is
reported as lost coverage rather than as a pass.

The gate fails on:

- provider registry entries missing release-gate metadata
- stale support matrix or catalog schema fixture versions
- declared capabilities without fixture, research, provider tests, or source
  coverage
- record-capable providers that do not verify trace artifact creation
- skipped core ViewModel tests
- visible GUI actions that only have mock coverage and no explicit unsupported
  diagnostic
