# Noir `nargo test` Framework Research

## Scope

- Language: Noir (`.nr`).
- Framework/runtime: `nargo test`, the test runner built into the Noir
  toolchain (`tooling/nargo_cli` in `metacraft-labs/noir`).
- Milestone: M17 (Noir slice) of CodeTracer-Test-Runner.
- Status: discovery, source locations, selector construction, command
  construction, **real execution and real per-test result reporting**.
  Recording and trace entry-point mapping are deliberately NOT claimed — see
  "Recording, And Why It Is Not Claimed Yet".

## The Decision: `nargo`, Not The Tracer wasm Modules

Noir has two candidate execution surfaces, and only one of them answers the
question a provider exists to answer.

- **`nargo test`.** Noir declares tests in source with `#[test]`, runs them
  with its own runner, and reports them per test. This is structurally the
  same situation as Rust/`cargo test`, Go/`go test`, Python/`pytest` — the
  shape every non-M13 provider in this framework already has.
- **`tooling/tracer_wasm`.** A *recorder*: it turns a compiled Noir program
  into a CodeTracer trace. It has no concept of a test, cannot enumerate one,
  and cannot report a pass or a fail.

A provider answers *which tests does this workspace have, and how do I run
one?* The tracer answers *can CodeTracer trace this program?* Those are
different questions, and only the first is a provider's. The M13 recorder
harnesses (`smart_contract_common.nim`) exist precisely for ecosystems that
have no answer to the first question at all, where enumerating fixture files
and handing them to a recorder is the best available approximation of a test
catalog. Noir is not in that position, so building it as an M13-style harness
would discard a real test runner in favour of an approximation of one.

The tracer belongs to this provider's `record` capability, which is where it
will attach when the trap below is closed.

## Existing Editor Extension Research

The mature Noir editor integration is the official Noir VS Code extension,
backed by `tooling/lsp` in the Noir repository. Relevant findings:

- `tooling/lsp/src/requests/code_lens_request.rs` builds the "▶ Run Test"
  code lenses. It does **not** parse source text: it type-checks the crate and
  walks `HirContext`, so a lens exists exactly where the compiler says a test
  function is.
- `tooling/lsp/src/requests/test_run.rs` runs one test by its
  fully-qualified name and maps `TestStatus::{Pass, Fail, Skipped,
  CompileError}` onto an LSP result — the same four states `nargo test`'s JSON
  formatter emits.
- The lens command carries the same identifier the CLI accepts, so the editor
  and the CLI agree on what a selector is.

Conclusion for CodeTracer: locations should come from a Noir-aware parser (or,
later, from the Noir LSP), and the *selector* must be nargo's fully-qualified
name, because that is the one string both the CLI and the LSP accept. This
provider derives that name in source and can be checked against
`nargo test --list-tests`, which is what `noir_providers_test.nim`'s
`noir_nargo_selectors_equal_nargo_own_list_tests` does.

## How To Detect The Framework

- Project marker: `Nargo.toml` at the crate root. A marker, not a content
  scan — `docs/ct-test-provider-guide.md` names content-scanning `detect`
  implementations as the most expensive probe in the registry.
- Source root: `src/`. Files are enumerated through
  `workspace_scope.walkWorkspaceFiles`, never `walkDirRec`, so a crate's
  `target/` output and any vendored dependency trees are excluded once for
  every provider rather than once per provider.

## How To Identify Test Entry Points

Noir's parser accepts exactly three attribute forms
(`compiler/noirc_frontend/src/parser/parser/attributes.rs`, and the error text
in `lexer/errors.rs` that enumerates them):

- `#[test]`
- `#[test(should_fail)]`
- `#[test(should_fail_with = "message")]`

A test may additionally be `unconstrained`. There is **no `#[ignore]`
attribute**: `TestStatus::Skipped` comes from `NARGO_IGNORE_TEST_FAILURES_FROM_
FOREIGN_CALLS` at run time (`tooling/nargo/src/ops/test.rs`), not from source,
so the provider tags `unconstrained` and the two `should_fail` variants and
does not invent an ignore concept.

## Selectors And Stable IDs

The selector is nargo's fully-qualified name, built by
`HirContext::fully_qualified_function_name`
(`compiler/noirc_frontend/src/hir/mod.rs`): the `::`-joined module path plus
the function name, with an empty path for the crate root. Reproduced in the
provider as:

- the file's module prefix — `src/main.nr` and `src/lib.rs`-equivalent
  `src/lib.nr` are the crate root and contribute nothing; `src/foo.nr` and
  `src/foo/mod.nr` both contribute `foo`; and
- inline `mod name { … }` nesting, tracked by brace depth.

So `#[test] fn nested_case()` inside `mod nested { … }` in `src/arithmetic.nr`
is `arithmetic::nested::nested_case`. Verified against real
`nargo test --list-tests` output, not merely asserted.

Item IDs use the shared `makeTestItemId(providerId, language, framework, file,
selector)`, so they are stable across discovery order.

## Execution Commands

Every command carries `--format json --show-output`. That is not decoration:
`--format json` selects `JsonFormatter`
(`tooling/nargo_cli/src/cli/test_cmd/formatters.rs`), which emits one JSON
object per line, and it is the only reason this provider can report real
per-test results instead of fanning one process exit code out over the whole
catalog the way `native_m11_common.runCommand` must.

| Scope | Command |
| --- | --- |
| project | `nargo test --format json --show-output` |
| file | `nargo test --format json --show-output --exact <every selector in the file>` |
| single | `nargo test --format json --show-output --exact <selector>` |

**File scope is an exact list, not a prefix, and that is a correctness
requirement rather than a style choice.** A bare `nargo test <string>` is a
`FunctionNameMatch::Contains` over the fully-qualified name, and the crate
root's module prefix is the *empty string* — so the obvious "run this file's
module prefix" spelling silently degrades a file-scoped run into a
whole-crate run and reports it as success. `--exact a b c` is
`FunctionNameMatch::Exact(Vec<String>)`, which matches any of the listed names
and nothing else. When a file has no tests, the provider returns a diagnostic
and does **not** invoke nargo, because an argument-less `nargo test` runs the
crate.

## Output And Result Capture

`--format json` emits, per line:

- `{"type":"suite","event":"started"|"ok"|"failed", …}` — suite framing.
- `{"type":"test","event":"started","name":…,"suite":…}`
- `{"type":"test","name":…,"suite":…,"exec_time":…,"event":"ok"|"failed"|"ignored"[,"stdout":…]}`

mapped to `tekTestStarted`, `tekOutput`, `tekFailure`, `tekTestFinished` with
`tsPassed` / `tsFailed` / `tsSkipped`. `exec_time` is seconds and becomes
`durationMs`.

Two properties of the real stream drive the parser's shape:

1. **Non-JSON lines are normal.** nargo writes compiler warnings (with
   box-drawing characters) and a trailing bare `Error:` to stderr, and
   `process_exec.execCapturedShell` merges stderr into the same stream. They
   are *counted* as unparsed rather than silently dropped.
2. **A truncated capture is fatal, not short.** `CapturedRun.truncated` is
   consulted before the stream is believed. JSON Lines is the most list-shaped
   output ct_test consumes, and `process_exec`'s own note says a prefix of a
   list-shaped output is indistinguishable from a complete short answer.

## Non-Triviality Is Enforced By The Provider

`nargo test --exact <name that matches nothing>` **exits zero** and prints a
suite line and no test lines. Exit code, absence of a failure event, and "the
command ran" all report success over a run in which nothing executed.

So `noirRunResult` counts finished tests and returns `tsErrored` with a `dsError`
diagnostic when the count is zero. The rule is enforced in the provider rather
than left to each caller, because the caller that forgets is the one that
reports green over nothing.

## Recording, And Why It Is Not Claimed Yet

`canRecordProject/File/Single` are **false**, and `canMapTraceEntryPoints` is
false with them (`validateCapabilities` refuses the latter without the
former).

The only Noir tracer today is the `tooling/tracer_wasm` pair. An ordinary
compile-then-trace run reports `ok` from **both** wasm modules and produces a
trace of **one event and zero steps**; the artifact even carries
`debug_symbols`, so the obvious "did it succeed?" assertion is green over
something that cannot be stepped. Only `mode: "debug"` produces a real trace
(27 events, 8 steps, 3 calls).

`docs/ct-test-provider-guide.md` says a record capability may be claimed only
when `record` "can create a non-empty trace artifact". For Noir that bar is
not enough: a one-event trace *is* a non-empty artifact. The bar this provider
must clear before claiming recording is **non-triviality** — steps > 0 and
calls > 0, asserted on the produced trace, not merely a zero exit and a
present `debug_symbols` field. Until a record path asserts that, claiming the
capability would put a Record button in the editor over a recording nobody can
step through, which is worse than having no button.

The unsupported diagnostic (`NoirRecordUnsupported`) says all of this at the
point of use.

## Parallelism, Isolation, And Scheduling

`nargo test` parallelises internally (`--test-threads`, defaulting to
`rayon::current_num_threads()`). The provider does not pass it, so nargo picks
its own degree; ct_test's own worker pool schedules whole provider invocations
above that. Noir tests are pure circuit execution with no shared filesystem
state, so file-scoped and single-scoped runs are safely concurrent.

## Fixture And Test Plan

`src/ct_test/fixtures/noir_nargo_project/` — a `bin` crate with seven tests
across two files and four decoys:

- `src/main.nr`: three crate-root tests, one per attribute form; a
  commented-out `#[test]`, a block-commented one (with a nested block comment),
  and a `#[test]` inside a string literal — one decoy per masking rule the
  sanitiser implements.
- `src/arithmetic.nr`: two module tests, one `unconstrained`, one genuinely
  failing (so the failure path is exercised against a real failure rather than
  a simulated one), and one inside an inline `mod nested`.

`src/ct_test/noir_providers_test.nim` covers detection, discovery, selector
equality against `nargo test --list-tests`, real single/file/project
execution, the failure path, the non-JSON-line path, the no-results path, the
truncation path, capability honesty, and lane registration.

## Risks And Open Questions

- **Cargo-style workspaces.** `Nargo.toml` supports a `[workspace]` form with
  member crates. This provider detects and enumerates a single crate root; a
  workspace root delegates to nargo's own package selection, but per-member
  catalogs are not yet built. Left explicit rather than half-done.
- **Selector collisions across packages.** `--exact` matches on the
  fully-qualified name only, so two packages in one workspace with the same
  test name would both run. `--package` is the fix and is not wired yet.
- **Source locations are parser-derived, not compiler-derived.** Confidence is
  `lcHigh`, not `lcExact`. The Noir LSP is the upgrade path, and
  `nargo test --list-tests` is the reconciliation that keeps the parser honest
  in the meantime.
