# Ruby Minitest Framework Research

## Framework Identity

| Field                                          | Answer                                                                                       |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Language                                       | Ruby                                                                                         |
| Framework                                      | Minitest                                                                                     |
| Framework versions researched                  | Minitest 5.x autorun and `--name` behavior                                                   |
| Package/project markers                        | `Gemfile`/`Gemfile.lock` entries for `minitest`, `test/test_helper.rb`, `Rakefile` test task |
| Primary command-line tool                      | `bundle exec ruby -Itest ...`                                                                |
| CodeTracer recorder/backend used for recording | `codetracer-ruby-recorder` CTFS recorder                                                     |
| Minimum supported platform(s)                  | Platforms where Ruby, Bundler, Minitest, and the Ruby recorder are installed                 |

## Project Detection

- Detect Minitest when `Gemfile` or `Gemfile.lock` mentions `minitest`.
- Also detect `test/test_helper.rb` or a `Rakefile` mentioning Minitest.
- Source discovery scans `test/**/*_test.rb` and other Ruby files under `test/`.

## Existing Editor Extension Research

- Ruby VS Code test adapters commonly place actions on `Minitest::Test`
  subclasses and `def test_*` methods.
- Single-test execution usually invokes the file with `--name` or `-n` and a
  method/class pattern.
- VS Code Testing API maps classes to suite items and methods to case items.

Sources:

- Minitest 5.x CLI behavior from `minitest/autorun`.
- VS Code Testing API concepts: https://code.visualstudio.com/api/extension-guides/testing

## Discovery

- Project discovery: parse candidate test files.
- File discovery: parse Ruby classes inheriting from `Minitest::Test`,
  `MiniTest::Test`, or `Test::Unit::TestCase`, then collect instance methods
  whose names start with `test_`.
- M9 does not execute Ruby to discover dynamically defined tests.

## Location Strategy

| Source                                       | Used?                | Notes                                                                              |
| -------------------------------------------- | -------------------- | ---------------------------------------------------------------------------------- |
| External adapter reports exact file/range    | Future               | Needed for dynamically generated tests                                             |
| Framework-native discovery reports file/line | Future               | Minitest objects expose names but not a complete static tree without loading files |
| Language server reports test/runnable ranges | No                   | Not required for M9                                                                |
| Tree-sitter query rules                      | Future option        | Better replacement for the lightweight parser                                      |
| Language-native/parser rules                 | M9 partial           | Lightweight class/method parser                                                    |
| Declarative pattern rules                    | Candidate files only | `test/**/*_test.rb`                                                                |
| Regex/file-name fallback                     | Candidate files only | Never creates runnable items by itself                                             |

## Selectors and Stable IDs

- Single method selector: `ClassName#test_method`.
- File selector: workspace-relative test file.
- Project selector: workspace root.
- Stable `TestItem.id`: provider/language/framework/relative file plus the
  class/method selector.

## Execution Commands

| Operation         | Command                                                                 |
| ----------------- | ----------------------------------------------------------------------- | --- | ---------------------- |
| Run project       | `bundle exec ruby -Itest -e "Dir['test/**/*_test.rb'].sort.each {       | f   | require_relative f }"` |
| Run file          | `bundle exec ruby -Itest test/file_test.rb`                             |
| Run single method | `bundle exec ruby -Itest test/file_test.rb --name /Class#test_method$/` |

M9 implements command construction and guarded process execution. If Ruby or
Bundler is absent, the provider returns an explicit diagnostic.

## Recording Commands

- M9 records only single-method scopes.
- The intended command wraps a tiny Ruby runner with
  `codetracer-ruby-recorder --out-dir <dir>`; the runner requires
  `bundler/setup` when available, leaves `--name` in `ARGV`, and loads the
  selected test file in-process so TracePoint recording can observe the method.
- Trace metadata includes `frameworkSelector` and `catalogTestId`.
- Verified in a Ruby-enabled Nix shell with the sibling
  `codetracer-ruby-recorder` native extension built: one Minitest method records
  to a non-empty `.ct` artifact and maps trace metadata back to the catalog item
  ID.

## Entry Point Identification

- The source entry point is the selected `def test_*` method.
- Setup, teardown, helpers, and dynamically generated methods require native
  Minitest reconciliation for exact attribution.

## Output and Result Capture

- Whole-process stdout/stderr can be captured from the Ruby process.
- Minitest's default summary line reports runs, assertions, failures, errors,
  and skips.
- M9 includes a summary parser that maps `0 failures, 0 errors` to passed and
  failures/errors to failed/errored status.

## Parallelism, Isolation, and Scheduling

- Minitest runs serially by default unless tests opt into parallelization.
- Recording should prefer one process per selected method.

## Incremental Testing

- Cache inputs: the test file plus `Gemfile`, `Gemfile.lock`, `Rakefile`, and
  `test/test_helper.rb`.

## Adapter Implementation Plan

- Nim module: `frameworks/ruby_minitest.nim`
- Shared parser/commands: `frameworks/ruby_common.nim`
- Provider ID: `ruby-minitest`
- Required operations implemented in M9: detect, discover project/file, locate
  tests, command construction, guarded run/record, normalized event-line parse,
  summary parse helper, and trace metadata mapping.

## Fixture and Test Plan

- Fixture project: `src/ct_test/fixtures/ruby_minitest_project`
- Cases: multiple `Minitest::Test` classes, multiple `test_*` methods, project
  aggregation, and fake tests in comments/strings.

## Risks and Open Questions

- Dynamically defined tests and custom runners require loading Ruby code.
- Class names nested in modules need richer selector escaping in a later slice.
- Real execution and recorder smoke require Ruby, Bundler, Minitest, and a built
  `codetracer-ruby-recorder` on the test machine.
