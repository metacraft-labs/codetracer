# Ruby RSpec Framework Research

## Framework Identity

| Field                                          | Answer                                                                                                |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Language                                       | Ruby                                                                                                  |
| Framework                                      | RSpec                                                                                                 |
| Framework versions researched                  | RSpec 3.x command and JSON formatter behavior                                                         |
| Package/project markers                        | `Gemfile`/`Gemfile.lock` entries for `rspec`, `.rspec`, `spec/spec_helper.rb`, `spec/rails_helper.rb` |
| Primary command-line tool                      | `bundle exec rspec`                                                                                   |
| CodeTracer recorder/backend used for recording | `codetracer-ruby-recorder` CTFS recorder                                                              |
| Minimum supported platform(s)                  | Platforms where Ruby, Bundler, RSpec, and the Ruby recorder are installed                             |

## Project Detection

- Detect RSpec when `Gemfile` or `Gemfile.lock` mentions `rspec`.
- Also detect `.rspec`, `spec/spec_helper.rb`, or `spec/rails_helper.rb`.
- Source discovery scans `*_spec.rb` files under the requested workspace.
- The M9 provider treats the requested workspace as the Bundler root.

## Existing Editor Extension Research

- VS Code Ruby/RSpec adapters commonly expose CodeLens or Testing UI actions at
  `describe`, `context`, and `it` lines.
- Mature adapters use RSpec location selectors (`spec/file_spec.rb:line`) for
  reliable single-example execution instead of constructing full-description
  regexes, because duplicate descriptions are common.
- RSpec can emit machine-readable JSON with `--format json`; that gives example
  IDs, descriptions, locations, status, run time, and exceptions.
- VS Code Testing API maps well to suites for `describe`/`context` and cases for
  `it`/`specify`/`example`.

Sources:

- RSpec CLI help and JSON formatter behavior from RSpec 3.x.
- VS Code Testing API concepts: <https://code.visualstudio.com/api/extension-guides/testing>

## Discovery

- Project discovery: parse candidate `spec/**/*_spec.rb` files.
- File discovery: parse the open file for `RSpec.describe`, `describe`,
  `context`, `shared_examples`, `shared_context`, `it`, `specify`, and
  `example`.
- Shared example groups are represented as suites tagged `shared-example`.
- `it_behaves_like` is not expanded in M9 because accurate expansion requires
  loading RSpec.
- The source parser ignores comment-only lines and string-assigned fake tests
  that do not start with an RSpec DSL call.

## Location Strategy

| Source                                       | Used?                | Notes                                                            |
| -------------------------------------------- | -------------------- | ---------------------------------------------------------------- |
| External adapter reports exact file/range    | Future               | Best final shape for generated/shared examples                   |
| Framework-native discovery reports file/line | Future               | RSpec JSON locations should reconcile selectors before execution |
| Language server reports test/runnable ranges | No                   | Not required for M9                                              |
| Tree-sitter query rules                      | Future option        | Better replacement for the lightweight parser                    |
| Language-native/parser rules                 | M9 partial           | Lightweight line parser over Ruby source                         |
| Declarative pattern rules                    | Candidate files only | `*_spec.rb`                                                      |
| Regex/file-name fallback                     | Candidate files only | Never creates runnable items by itself                           |

## Selectors and Stable IDs

- Single example selector: `{relative_spec_file}:{line}`.
- File selector: workspace-relative spec path.
- Project selector: workspace root.
- Stable `TestItem.id`: provider/language/framework/relative file plus the
  location selector.

## Execution Commands

| Operation          | Command                                                        |
| ------------------ | -------------------------------------------------------------- |
| Run project        | `bundle exec rspec`                                            |
| Run file           | `bundle exec rspec spec/file_spec.rb`                          |
| Run single example | `bundle exec rspec spec/file_spec.rb:line`                     |
| Structured output  | `bundle exec rspec --format json ...` as a future adapter path |

M9 implements command construction and guarded process execution. If Ruby or
Bundler is absent, the provider returns an explicit diagnostic.

## Recording Commands

- M9 records only single-example scopes.
- The intended command wraps a tiny Ruby runner with
  `codetracer-ruby-recorder --out-dir <dir>`; the runner requires
  `bundler/setup` when available and calls `RSpec::Core::Runner.run([selector])`
  in-process so TracePoint recording can observe the example.
- Trace metadata includes `frameworkSelector` and `catalogTestId` so
  `ruby_rspec_records_nested_example_trace` can verify linkage when the recorder
  and gems are available.
- Verified in a Ruby-enabled Nix shell with the sibling
  `codetracer-ruby-recorder` native extension built: one nested RSpec example
  records to a non-empty `.ct` artifact and maps trace metadata back to the
  catalog item ID.

## Entry Point Identification

- The source entry point is the example line selected by `{file}:{line}`.
- Hooks, `let`, shared contexts, and shared examples execute around that line
  and need native RSpec reconciliation for exact trace attribution.

## Output and Result Capture

- Whole-process stdout/stderr can be captured from `bundle exec rspec`.
- RSpec JSON reports status, run time, pending messages, and exception details.
- M9 includes a JSON result parser for formatter output, but live JSON emission
  is not yet wired into the run loop.

## Parallelism, Isolation, and Scheduling

- RSpec runs serially by default; parallelization usually comes from external
  gems or CI sharding.
- Recording should prefer one process per selected example to avoid mixed trace
  artifacts and shared global state.

## Incremental Testing

- Cache inputs: the spec file plus `Gemfile`, `Gemfile.lock`, `.rspec`, helper
  files, and `Rakefile`.

## Adapter Implementation Plan

- Nim module: `frameworks/ruby_rspec.nim`
- Shared parser/commands: `frameworks/ruby_common.nim`
- Provider ID: `ruby-rspec`
- Required operations implemented in M9: detect, discover project/file, locate
  tests, command construction, guarded run/record, normalized event-line parse,
  RSpec JSON result parse helper, and trace metadata mapping.

## Fixture and Test Plan

- Fixture project: `src/ct_test/fixtures/ruby_rspec_project`
- Cases: nested `describe`/`context`, examples, `specify`, shared examples, and
  fake tests in comments/strings.
- Required assertions: selectors, ranges, parent IDs, detection, command
  construction, result parsing, CLI JSON, missing-runtime diagnostics, and trace
  metadata catalog linkage.

## Risks and Open Questions

- Shared example expansion and generated examples require RSpec-native loading.
- Location selectors are robust for normal examples but not enough for generated
  cases without reconciliation.
- Real execution and recorder smoke require Ruby, Bundler, RSpec, and a built
  `codetracer-ruby-recorder` on the test machine.
