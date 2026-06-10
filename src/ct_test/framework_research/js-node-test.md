# JavaScript/TypeScript Node Test Runner Framework Research

## Framework Identity

| Field                                          | Answer                                                                                                        |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Language                                       | JavaScript; TypeScript with loaders/transpilation                                                             |
| Framework                                      | Node.js built-in `node:test` runner                                                                           |
| Framework versions researched                  | Node 20+ runner behavior and VS Code node:test extension docs                                                 |
| Package/project markers                        | Scripts containing `node --test`, imports/requires of `node:test`, conventional `*.test.js`/`*.spec.js` files |
| Primary command-line tool                      | `node --test`                                                                                                 |
| CodeTracer recorder/backend used for recording | JS/Node recorder for single-case JavaScript files                                                             |
| Minimum supported platform(s)                  | Node version supported by CodeTracer JS recording; VS Code extension requires Node >=19                       |

## Project Detection

- Prefer package scripts containing `node --test`.
- If no Jest/Vitest project marker exists, detect `node:test` imports in
  candidate JS/TS test files.
- M7 does not infer Node runner from file names alone, because many JS
  frameworks share `*.test.*` and `*.spec.*`.

## Existing Editor Extension Research

- Connor Peet's `nodejs-testing` VS Code extension provides Test Explorer
  integration for the native Node test runner. Its marketplace docs say it
  looks for files using Node's test runner naming convention and requires
  Node.js >=19 for needed features.
- The extension docs call out an important TypeScript limitation: the native
  runner only supports JavaScript directly; TypeScript requires a compilation
  step/loader and sourcemaps so the extension can map test locations back to
  source.
- Node's own docs describe `test`, `describe`, and `it` APIs, subtests, skip
  and todo options, and rerun-failure state keyed by file/line/column. That
  supports a future location-oriented reconciliation model.
- VS Code still receives locations from the extension/provider, not directly
  from core editor heuristics.

Sources:

- Node test runner docs: https://nodejs.org/api/test.html
- Node test runner VS Code extension: https://marketplace.visualstudio.com/items?itemName=connor4312.nodejs-testing
- VS Code Testing API: https://code.visualstudio.com/api/extension-guides/testing

## Discovery

- Project discovery: future exact path should run or query Node test discovery
  through an adapter that emits JSON and maps file/line/column back to sources.
- File discovery: M7 parses open JS/TS files for `describe`, `test`, and `it`
  calls after masking comments, strings, and template literals.
- Subtests created through `t.test()` inside callbacks are not modeled in M7
  unless they use a visible top-level-style call that the parser recognizes.

## Location Strategy

| Source                                       | Used?                | Notes                                                                        |
| -------------------------------------------- | -------------------- | ---------------------------------------------------------------------------- |
| External adapter reports exact file/range    | Future               | Needed for TypeScript/sourcemap-aware exactness                              |
| Framework-native discovery reports file/line | Future               | Node rerun state and reporter output can identify line/column-oriented tests |
| Language server reports test/runnable ranges | No                   | Not required for M7                                                          |
| Tree-sitter query rules                      | Future option        | Good manifest-backed parser source                                           |
| Language-native/parser rules                 | M7 partial           | Lightweight lexical parser over sanitized JS/TS source                       |
| Declarative pattern rules                    | Candidate files only | `*.test.*` and `*.spec.*`                                                    |
| Regex/file-name fallback                     | Candidate files only | Never creates runnable items by itself                                       |

## Selectors and Stable IDs

- Source selector: `{relativeFile}::{describe name > test name}`.
- Node command selector: file plus `--test-name-pattern {full name}`.
- For duplicate names, dynamically generated tests, and subtests with repeated
  names, line/column reconciliation is required before execution.

## Execution Commands

| Operation         | Command                                              |
| ----------------- | ---------------------------------------------------- |
| Run project       | `node --test`                                        |
| Run file          | `node --test {file}`                                 |
| Run single test   | `node --test --test-name-pattern {full name} {file}` |
| Structured events | Future reporter/adapter JSON stream                  |

M7 implements command construction plus real `node --test` execution for
project, file, and single-test scopes. Events are coarse lifecycle events around
the process output, not a full reporter-derived per-test event stream.

## Recording, Output, and Trace Entry Points

- M7 records single-test scopes through `codetracer-js-recorder record` when the
  selected file contains exactly one test case. This produces a CTFS `.ct`
  bundle and is covered by an automated smoke test.
- Multi-test file single-selector recording is deliberately rejected in M7
  because the current JS recorder records an entry file and does not expose a
  way to run Node with `--test-name-pattern` while tracing the selected test's
  JavaScript frames.
- Per-test output attribution needs reporter/test event data.
- Trace entry-point mapping is not implemented in M7.

## Scheduling, Incremental Testing, and Cache Inputs

- Cache inputs: `package.json`, lockfiles, `tsconfig.json`, loader config, and
  the test file.
- For TypeScript, source maps and loader parameters must be part of cache and
  command identity.

## Adapter Shape

- M7 uses an in-tree Nim provider and shared JS parser.
- Future exact support should be an external Node adapter that can run the
  native test runner, consume reporter events, and report normalized locations.

## Fixtures and Risks

- Fixtures include JS and TS tests, nested suites, async tests, and fake tests
  in comments/strings/templates. The TS fixture emits a diagnostic explaining
  loader requirements.
- Residual risks: Node version differences, TypeScript loaders, sourcemaps,
  multi-test file recording, subtests, duplicate names, generated tests, and
  reporter compatibility.
