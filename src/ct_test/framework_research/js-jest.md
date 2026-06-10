# JavaScript/TypeScript Jest Framework Research

## Framework Identity

| Field                                          | Answer                                                                                                        |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Language                                       | JavaScript, TypeScript                                                                                        |
| Framework                                      | Jest                                                                                                          |
| Framework versions researched                  | Jest 29/30 behavior and current VS Code Jest extension behavior                                               |
| Package/project markers                        | `jest`/`ts-jest`/`@jest/globals` dependencies, `jest` package key, `jest.config.*`, scripts mentioning `jest` |
| Primary command-line tool                      | `npx jest`                                                                                                    |
| CodeTracer recorder/backend used for recording | JS/Node recorder, not wired in M7                                                                             |
| Minimum supported platform(s)                  | Same as CodeTracer JavaScript/Node recording support                                                          |

## Project Detection

- Prefer explicit Jest markers in `package.json` and `jest.config.*`.
- A package script containing `jest` is sufficient when no competing Vitest
  marker is present.
- M7 treats the requested workspace as one Jest root; monorepo/multi-project
  Jest roots need later config-aware splitting.

## Existing Editor Extension Research

- `jest-community/vscode-jest` integrates Jest with VS Code Test Explorer,
  watch mode, editor status, debugging, snapshots, and coverage. Its docs say
  it automatically starts Jest for most runnable configurations and supports
  Test Explorer and editor feedback.
- VS Code testing decorations come from extension-created `TestItem`s with
  ranges. The Jest extension owns discovery and reconciliation; VS Code does
  not infer Jest locations by itself.
- Jest itself provides stable selectors through test names and file paths, but
  normal CLI output is not a complete source-location API. Mature integrations
  combine Jest process results, source parsing, and extension state.
- Lightweight CodeLens extensions such as Jest/Vitest Runner place run/debug
  commands directly in test files. These extensions demonstrate the practical
  parser-pattern approach for editor immediacy, but they are not a sufficient
  authoritative discovery layer.

Sources:

- VS Code Jest extension: https://github.com/jest-community/vscode-jest
- VS Code Testing API: https://code.visualstudio.com/api/extension-guides/testing
- Jest/Vitest Runner marketplace: https://marketplace.visualstudio.com/items?itemName=firsttris.vscode-jest-runner

## Discovery

- Project discovery: future authoritative path should invoke Jest with a small
  adapter/reporter that returns JSON test suites, names, file paths, and source
  locations where available.
- File discovery: M7 parses open JS/TS files for `describe`, `test`, and `it`
  calls after masking comments, strings, and template literals.
- Dynamic tests, generated names, `test.each` case expansion, custom globals,
  aliases, and macro-like wrappers are out of scope for M7 source discovery.

## Location Strategy

| Source                                       | Used?                | Notes                                                                                      |
| -------------------------------------------- | -------------------- | ------------------------------------------------------------------------------------------ |
| External adapter reports exact file/range    | Future               | Best final shape for Jest results and generated cases                                      |
| Framework-native discovery reports file/line | Partial future       | Jest command/reporters can identify suites/files; exact ranges need adapter/source mapping |
| Language server reports test/runnable ranges | No                   | Not required for M7                                                                        |
| Tree-sitter query rules                      | Future option        | Preferred declarative replacement for M7 parser                                            |
| Language-native/parser rules                 | M7 partial           | Lightweight lexical parser over sanitized JS/TS source                                     |
| Declarative pattern rules                    | Candidate files only | `*.test.*` and `*.spec.*`                                                                  |
| Regex/file-name fallback                     | Candidate files only | Never creates runnable items by itself                                                     |

## Selectors and Stable IDs

- Source selector: `{relativeFile}::{describe name > test name}`.
- Jest command selector: file plus `--testNamePattern` using the full suite/test
  name. This is weaker than an exact test ID when duplicate names exist.
- Parameterized tests are represented at source call level and tagged with
  `each` when detected; generated parameter cases require Jest collection.

## Execution Commands

| Operation         | Command                                                                      |
| ----------------- | ---------------------------------------------------------------------------- |
| Run project       | `npx jest --runInBand`                                                       |
| Run file          | `npx jest --runInBand --runTestsByPath {file}`                               |
| Run single test   | `npx jest --runInBand --runTestsByPath {file} --testNamePattern {full name}` |
| Structured events | Future reporter/adapter JSON stream                                          |

M7 implements and tests discovery plus command construction only. The provider
does not advertise run or record capabilities because this workspace does not
provide a Jest package installation/adapter for a real-program execution smoke.

## Recording, Output, and Trace Entry Points

- Recording should wrap the same Jest command in the JS/Node recorder once a
  Jest adapter/reporter path is available and tested.
- Per-test output needs a custom reporter or adapter; raw console output is not
  enough to reliably attribute output to individual tests.
- Trace entry-point mapping is not implemented in M7.

## Scheduling, Incremental Testing, and Cache Inputs

- Cache inputs: `package.json`, `package-lock.json`/`yarn.lock`/`pnpm-lock.yaml`,
  `jest.config.*`, `tsconfig.json`, Babel/SWC config, and the test file.
- Jest watch mode and `--findRelatedTests` are useful future project-level
  optimizations but are not used by M7.

## Adapter Shape

- M7 uses an in-tree Nim provider and shared JS parser.
- Future exact support should be an external Node adapter or Jest reporter that
  emits CodeTracer catalog/events JSON.

## Fixtures and Risks

- Fixtures include JS and TS tests with `describe`, `test`, `it`, async tests,
  `.skip`, `.only`, comments, strings, and template literals.
- Residual risks: duplicate full names, dynamic names, aliases, `test.each`
  expansion, transformed TypeScript source maps, monorepos, and custom runners.
