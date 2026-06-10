# JavaScript/TypeScript Vitest Framework Research

## Framework Identity

| Field                                          | Answer                                                                                                  |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Language                                       | JavaScript, TypeScript                                                                                  |
| Framework                                      | Vitest                                                                                                  |
| Framework versions researched                  | Vitest 1.4+ VS Code extension requirement and current Vitest 3 docs                                     |
| Package/project markers                        | `vitest` dependency, scripts mentioning `vitest`, `vitest.config.*`, `vite.config.*` with Vitest config |
| Primary command-line tool                      | `npx vitest run`                                                                                        |
| CodeTracer recorder/backend used for recording | JS/Node recorder, not wired in M7                                                                       |
| Minimum supported platform(s)                  | Node.js support required by the configured Vitest version                                               |

## Project Detection

- Prefer `vitest` dependencies and explicit `vitest.config.*`.
- A package script containing `vitest` is sufficient.
- `vite.config.*` can hold Vitest config, but M7 avoids claiming Vitest from a
  plain Vite config unless another Vitest marker exists.

## Existing Editor Extension Research

- The official `vitest-dev/vscode` extension uses VS Code's `TestController`
  API. Its docs describe Test Explorer integration, gutter icons next to test
  cases, single-test run/debug actions, coverage, and inline console-log
  display.
- The extension searches for config files using a pattern similar to
  `**/*{vite,vitest}*.config*.{ts,js,mjs,cjs,cts,mts}` and exposes workspace
  config settings for root/workspace config resolution.
- Vitest docs point users to the official VS Code extension and document
  `vitest run` for one-shot command-line execution.
- Location ownership remains with the extension/provider. CodeTracer should
  follow that model: parser locations for editor immediacy, native Vitest
  collection/adapter data before execution when exactness matters.

Sources:

- Vitest VS Code extension: https://github.com/vitest-dev/vscode
- Vitest guide: https://vitest.dev/guide/
- VS Code Testing API: https://code.visualstudio.com/api/extension-guides/testing

## Discovery

- Project discovery: future exact path should use Vitest's Node API or a Vitest
  reporter/adapter to emit normalized JSON.
- File discovery: M7 parses open JS/TS files for `describe`, `test`, and `it`
  calls after masking comments, strings, and template literals.
- M7 recognizes modifier tags such as `skip`, `only`, `todo`, `concurrent`,
  and `each`, but does not expand table-driven cases.

## Location Strategy

| Source                                       | Used?                | Notes                                                  |
| -------------------------------------------- | -------------------- | ------------------------------------------------------ |
| External adapter reports exact file/range    | Future               | Best final shape for Vitest's worker/reporter model    |
| Framework-native discovery reports file/line | Future               | Use Vitest APIs/reporter rather than terminal text     |
| Language server reports test/runnable ranges | No                   | Not required for M7                                    |
| Tree-sitter query rules                      | Future option        | Good manifest-backed replacement for M7 parser         |
| Language-native/parser rules                 | M7 partial           | Lightweight lexical parser over sanitized JS/TS source |
| Declarative pattern rules                    | Candidate files only | `*.test.*` and `*.spec.*`                              |
| Regex/file-name fallback                     | Candidate files only | Never creates runnable items by itself                 |

## Selectors and Stable IDs

- Source selector: `{relativeFile}::{describe name > test name}`.
- Vitest command selector: file plus `-t {full name}`.
- Duplicate names and generated names are weak selectors; future adapter output
  should distinguish exact collected tasks.

## Execution Commands

| Operation         | Command                                |
| ----------------- | -------------------------------------- |
| Run project       | `npx vitest run`                       |
| Run file          | `npx vitest run {file}`                |
| Run single test   | `npx vitest run {file} -t {full name}` |
| Structured events | Future reporter/adapter JSON stream    |

M7 implements discovery plus command construction only. The provider does not
advertise run or record capabilities because this workspace does not provide a
Vitest package installation/adapter for a real-program execution smoke.

## Recording, Output, and Trace Entry Points

- Recording should wrap the Vitest command with the JS/Node recorder once a
  Vitest adapter/reporter path is available and tested.
- Per-test output attribution should use Vitest reporter/task events, not raw
  merged stdout.
- Trace entry-point mapping is not implemented in M7.

## Scheduling, Incremental Testing, and Cache Inputs

- Cache inputs: `package.json`, lockfiles, `vitest.config.*`, relevant
  `vite.config.*`, `tsconfig.json`, and the test file.
- Watch mode and Vitest workspaces are future scheduling concerns.

## Adapter Shape

- M7 uses an in-tree Nim provider and shared JS parser.
- Future exact support can be an external Node adapter that calls Vitest APIs or
  registers a reporter and emits CodeTracer JSON.

## Fixtures and Risks

- Fixtures include TS and JS tests, nested `describe`, `it`, async tests,
  `test.concurrent`, `test.todo`, and fake tests in comments/strings/templates.
- Residual risks: aliases, dynamic names, `test.each`, duplicate names, Vitest
  workspace projects, transformed source maps, browser mode, and custom pools.
