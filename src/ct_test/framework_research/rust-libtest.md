# Rust libtest / cargo test Framework Research

## Scope

- Language: Rust.
- Framework/runtime: Cargo's default `cargo test` flow and rustc's built-in
  libtest harness.
- Milestone: M6, first provider slice.
- Status: discovery, source locations, selector construction, reconciliation
  with the compiled binaries' `--list`, doc-test discovery, command
  construction, and Cargo/libtest execution are implemented. The run callback
  reports one normalized terminal outcome per requested unit, from the command's
  exit code and libtest's summary line. CodeTracer recording, framework-native
  per-test event parsing/output attribution, and trace entry-point mapping are
  not wired in this milestone.

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

- Project marker: `Cargo.toml` at the workspace/package root. A virtual
  workspace (a root manifest with only `[workspace]`) is a project too.
- Which files hold tests is Cargo's answer, not a directory convention.
  `cargo metadata --no-deps` names every workspace member at or below the
  project root and, for each, its targets with their root files, editions and
  `test`/`doctest` flags. A file belongs to a target when that target's `mod`
  declarations reach it, followed the way rustc resolves them (beside a crate
  root or `mod.rs`, in a directory named after any other file, `#[path]`
  relative to the declaring file's directory, inline modules adding their own
  components). A file no target reaches is not compiled and holds no units.
  When several targets compile one file, it belongs to the first of library,
  binary, integration test, example, bench.
  <https://doc.rust-lang.org/reference/items/modules.html#module-source-filenames>
- Only when Cargo cannot be asked (no usable `cargo`, as on the Nix-fallback
  route) do the conventions decide: `src/**/*.rs` and `tests/**/*.rs` of the
  root package, with module paths guessed from file paths.
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
- any of these written on one line, such as `#[test] fn name() {}`
- nested inline `mod` paths such as `tests::inner::case`
- file-module prefixes from the owning target's module tree, such as
  `foo::case` for `src/foo.rs`, including modules under a custom `[lib]` or
  `[[bin]]` path or a `#[path]` attribute
- raw identifiers as libtest prints them: rustc keeps `r#` only for a word
  reserved in the crate's edition, so `fn r#try` is `r#try` in 2018 and later
  and `try` in 2015, and `fn r#plain` is `plain`
- doc tests, by the name rustdoc gives them (`src/lib.rs - item (line N)`),
  located at the opening fence on line `N`
- integration test file items without a file-name selector prefix, such as
  `integration_smoke` from `tests/integration_sample.rs`

M6 does not identify:

- macro-generated tests and proc-macro-expanded test functions beyond the
  known async test attributes: no source line declares them. Project
  discovery still sees them in the binaries' `--list` and names them in a
  warning diagnostic, so the omission is never silent;
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

Discovery reconciles. File discovery (`--file`, editor gutters) reads source
and `cargo metadata` only, so it compiles nothing and lists no doc tests.
Project discovery then builds the test targets
(`cargo test --no-run --message-format=json --package <member>...`), runs each
test executable with `--list`, and runs `cargo test --doc --package <member>
-- --list` for each library with doc tests:

- a source selector the binary lists is confirmed;
- one the binary spells differently, ignoring `r#` prefixes, takes the
  binary's spelling;
- one the binary does not list stays a unit (a `#[cfg]`-gated test), which
  the run reports skipped;
- a listed test no source declaration places is named in a warning
  diagnostic and is not a unit;
- each doc test becomes a unit, its file resolved against the workspace root
  rustdoc names paths from;
- a target that did not build, or whose `--list` failed or timed out, keeps
  its source selectors, and the diagnostic says which targets were not
  checked. A certificate covers exactly the targets it names, and partial
  coverage is permitted (test-certificates-spec `Standard.md` §8), so a test
  discovery could not place is a coverage gap, never a false claim.

A doc test cannot be selected alone: rustdoc splits a filter on whitespace and
ORs the pieces. A doc-test unit runs `cargo test --doc -- <file path>`, which
runs every doc test of that file, and is judged on its own
`test <name> ... ok|FAILED|ignored` line alone, in both directions. A failing
sibling therefore fails only its own unit, and an `ignore` block finishes
`skipped`.

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

Use `cargo test` from the package/workspace root. Units are dispatched one
test at a time, and each command names its member with `--package` whenever
the workspace has several members or the member is not the project root's
own package.

## How To Capture Output Of Individual Tests

M6 preserves the combined Cargo/libtest process output on the run unit, but it
does not parse or attribute that stream per test. Stable libtest text output
interleaves with parallel execution unless run with controlled threads and
`--nocapture`. Machine-readable JSON output has historically been
unstable/nightly-only; Rust RFC 3558 documents the need for stable libtest JSON,
but this milestone does not depend on it.

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
- discovery: source parser over the module trees `cargo metadata` describes,
  reconciled with the compiled binaries' `--list` and rustdoc's doc-test list
  (see "Selectors And libtest `--list`")
- command construction: explicit helper returning argv parts
- target selection: `cargo metadata --no-deps` names the targets, so a
  `[[bin]]` or `[[test]]` renamed in the manifest runs under its declared name.
  A file runs under the target whose module tree reaches it. A file no tree
  reaches falls back to its directory's `main.rs` target below `tests/<x>/` or
  `src/bin/<x>/`, then `--lib` when the package has a library, then the
  `src/main.rs` binary. In a
  workspace the command also names the package, because `default-members` can
  otherwise redirect it. When Cargo cannot be asked, as on the Nix-fallback
  route, the same choice is made from the path conventions
- run callback: executes the constructed Cargo command through the shared
  process bridge, with one terminal event for the requested run unit. A
  non-zero exit is `failed`, except that Cargo refusing a target whose
  `required-features` are off is `skipped`. Exit zero is `passed` only when
  libtest's `test result:` lines count at least one passed test and, for a
  single test, libtest printed that test's own result line; otherwise it is
  `skipped`, because `cargo test` also exits zero when a selector matches
  nothing, as it does for a discovered test its `#[cfg]` keeps out of the build.
  Both markers must start a line: rustc's warnings quote source text and a
  build script's warnings are echoed, so the marker can appear inside either
- record callback: returns an explicit unsupported diagnostic

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

- Project discovery compiles the test targets, so its cost is a test build;
  the run that follows reuses it.
- `#[cfg]` is not evaluated when module trees are followed, so a gated module's
  tests are units that run as skipped.
- A module several targets compile is attributed to one of them; the other
  targets' copies are named in the unplaced-test diagnostic.
- File-scoped source execution is approximate for `src/*.rs`.
- libtest-native JSON/event parsing and per-test output attribution remain
  open; current results are run-unit outcomes read from the exit code and
  libtest's text summary.
- Async runtime attributes are treated as source markers only; M6 does not
  compile or run those tests.
