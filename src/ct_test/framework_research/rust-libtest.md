# Rust libtest / cargo test Framework Research

## Scope

- Language: Rust.
- Framework/runtime: Cargo's default `cargo test` flow and rustc's built-in
  libtest harness.
- Milestone: M6, first provider slice.
- Status: discovery, source locations, selector construction, and command
  construction only. CodeTracer recording, event parsing, per-test output
  capture, and trace entry-point mapping are not wired in this milestone.

## Existing Editor Extension Research

The mature VS Code integration is rust-analyzer. Its run buttons are not based
on libtest `--list` output alone. rust-analyzer builds "runnables" from semantic
IDE analysis: it identifies test functions with HIR/function metadata, computes
canonical paths when available, and attaches a navigation target that VS Code can
render as a CodeLens/location.

Relevant source and docs:

- rust-analyzer `runnables.rs`: `runnable_fn` checks `def.is_test`, computes a
  canonical path when available, falls back to the function name, and creates a
  `RunnableKind::Test`.
  <https://github.com/rust-lang/rust-analyzer/blob/master/crates/ide/src/runnables.rs>
- rust-analyzer LSP conversion: runnables carry a `location` and cargo
  `cargoArgs`/`executableArgs`.
  <https://github.com/rust-lang/rust-analyzer/blob/master/crates/rust-analyzer/src/lsp/to_proto.rs>
- rust-analyzer LSP extension model: `CargoRunnableArgs` separates cargo
  arguments from executable/libtest arguments.
  <https://github.com/rust-lang/rust-analyzer/blob/master/crates/rust-analyzer/src/lsp/ext.rs>
- rust-analyzer generated configuration documents CodeLens placement and test
  command placeholders including `${test_name}`, `${exact}`, and
  `${include_ignored}`.
  <https://rust-analyzer.github.io/book/configuration.html>

Conclusion for CodeTracer: source locations should come from a Rust-aware parser
or rust-analyzer/LSP integration, not from regex-only scanning or from libtest
listing. libtest listing remains useful as a reconciliation and selector check
before execution.

## How To Detect The Framework

- Project marker: `Cargo.toml` at the workspace/package root.
- Candidate source roots for M6:
  - `src/**/*.rs` for unit tests compiled into package targets.
  - `tests/*.rs` and `tests/**/*.rs` as candidate integration test source files.
- Cargo itself treats each `tests/*.rs` file as a separate integration test
  target by convention; deeper files are normally modules/helpers unless
  explicitly declared as targets in `Cargo.toml`.
- Custom harnesses (`harness = false`) and non-Cargo build systems are out of
  scope for M6 and must be detected/researched before execution support relies
  on them.

## How To Identify Test Entry Points

Canonical libtest entry points are functions annotated with `#[test]`. Popular
async runtimes provide attribute macros that behave as tests, including
`#[tokio::test]` and `#[async_std::test]`.

M6 identifies:

- `#[test] fn name()`
- `#[ignore] #[test] fn name()`
- `#[tokio::test] async fn name()`
- `#[async_std::test] async fn name()`
- nested inline `mod` paths such as `tests::inner::case`
- standard file-module prefixes for `src/foo.rs`, such as `foo::case`
- integration test file items without a file-name selector prefix, such as
  `integration_smoke` from `tests/integration_sample.rs`

M6 does not identify:

- macro-generated tests;
- proc-macro-expanded test functions beyond the known async test attributes;
- doctests;
- benchmarks;
- custom test harness items;
- selectors that require rust-analyzer's full semantic model.

## Location Strategy

rust-analyzer attaches runnable locations from semantic navigation targets. M6
uses a lightweight Rust lexer/parser that preserves line numbers while masking
comments, block comments, normal strings, raw strings, byte strings, and chars.
The parser then reads attributes, module declarations, braces, and function
definitions.

The M6 range contract is:

- `startLine` points to the test attribute line that made the function runnable.
- `endLine` points to the function definition line.
- Columns use the function keyword span on the end line.

This places editor controls above the attribute block, matching the Rust visual
convention that the attribute and function are one declaration.

Future contract freeze should compare this with rust-analyzer locations. If
rust-analyzer becomes available in the provider path, exact LSP locations should
override the lightweight parser.

## Selectors And libtest `--list`

Cargo compiles tests by building test executables linked with libtest. Cargo's
official docs say those binaries automatically run functions annotated with
`#[test]`, and that `cargo test FILTER -- --test-threads N` passes arguments
after `--` to the test binary.

Official docs:

- Cargo `cargo test` command:
  <https://doc.rust-lang.org/cargo/commands/cargo-test.html>
- Cargo guide on unit and integration tests:
  <https://doc.rust-lang.org/cargo/guide/tests.html>
- rustc/libtest CLI arguments:
  <https://doc.rust-lang.org/rustc/tests/index.html>

Observed/expected mapping:

- Unit tests under inline modules usually list as `module::test_name`.
- Unit tests in `src/foo.rs` usually list as `foo::module::test_name`.
- Integration tests in `tests/integration_sample.rs` usually list as
  `test_name` or `module::test_name` inside that integration test binary, not
  `integration_sample::test_name`.
- `cargo test -- --list` can list built tests, but it may require compiling the
  full package and does not provide source ranges.

M6 selectors are source-derived and libtest-like. Before actual execution is
considered final, the provider should optionally reconcile them with
`cargo test -- --list` or target-specific `cargo test --test NAME -- --list`.

## How To Run Tests

Project:

```sh
cargo test
```

Library/unit-test file in `src/`:

```sh
cargo test --lib
```

Integration test file `tests/integration_sample.rs`:

```sh
cargo test --test integration_sample
```

Single unit test:

```sh
cargo test --lib -- tests::unit_adds --exact --include-ignored
```

Single integration test:

```sh
cargo test --test integration_sample -- api::nested_integration --exact --include-ignored
```

Notes:

- `--exact` avoids substring-filter matches.
- `--include-ignored` lets an explicit run button execute ignored tests too,
  mirroring the rust-analyzer placeholder model for single tests.
- File-scoped execution for arbitrary `src/foo.rs` is approximate because Cargo
  runs package targets, not a single source file. M6 exposes `--lib` for `src/`
  files and target-specific `--test NAME` for top-level integration test files.

## How To Run All Tests In A File

- `tests/name.rs`: `cargo test --test name`.
- `src/*.rs`: no exact libtest-level file filter exists through Cargo. M6 uses
  `cargo test --lib` for source files. A later milestone can narrow this by
  collecting selectors in the file and invoking exact tests in parallel, or by
  using rust-analyzer target/runnable data.

## How To Run All Tests In A Project

Use `cargo test` from the package/workspace root. Workspaces require package
selection policy (`--package`, `--workspace`, or current package) before the
contract is frozen.

## How To Capture Output Of Individual Tests

M6 does not capture per-test output. Stable libtest text output interleaves with
parallel execution unless run with controlled threads and `--nocapture`.
Machine-readable JSON output has historically been unstable/nightly-only; Rust
RFC 3558 documents the need for stable libtest JSON, but this milestone does
not depend on it.

Future options:

- use stable libtest text as a fallback with `--test-threads=1`;
- use nightly/stable JSON only when available and explicitly detected;
- integrate `cargo nextest` as a separate provider once researched;
- wrap single-test executions to isolate stdout/stderr per test.

## How Recording Should Work Later

Recording should wrap the constructed cargo command with the appropriate
CodeTracer recorder. For single-test recording, use the exact selector command.
For file/project recording, either run multiple exact selector recordings or
record the broader cargo invocation and map resulting trace metadata back to
test items. This mapping is not implemented in M6.

## Incremental And Cache Inputs

Cache invalidation should include:

- `Cargo.toml`
- `Cargo.lock`
- `.cargo/config.toml`
- relevant `src/**/*.rs` and `tests/**/*.rs` file contents
- future rust-analyzer/cargo metadata target graph fingerprints

## Provider Shape

M6 uses a modular Nim provider:

- provider id: `rust-libtest`
- language: `rust`
- framework: `libtest/cargo-test`
- discovery: source parser
- command construction: explicit helper returning argv parts
- run/record callbacks: return diagnostics only

A future external adapter could provide rust-analyzer-derived locations and
selectors directly. The manifest should remain declarative: Cargo markers,
source roots, command templates, and optional location-source priority.

## Fixture Requirements

The M6 fixture crate includes:

- library unit tests;
- nested inline module tests;
- `src/nested.rs` module tests;
- integration tests in `tests/integration_sample.rs`;
- ignored test;
- `#[tokio::test]` and `#[async_std::test]` attributes for discovery only;
- a failing test for future run/result handling;
- fake tests in comments and strings that must not be discovered.

## Risks And Open Questions

- Source-derived selectors are not macro-perfect; rust-analyzer or cargo/libtest
  reconciliation is needed before final execution support.
- File-scoped source execution is approximate for `src/*.rs`.
- Workspace/package target selection is not designed in M6.
- libtest JSON/event parsing and per-test output attribution remain open.
- Async runtime attributes are treated as source markers only; M6 does not
  compile or run those tests.
