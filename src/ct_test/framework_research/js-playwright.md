# JavaScript/TypeScript Playwright Framework Research

## Framework Identity

| Field                                          | Answer                                                                                                             |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Language                                       | JavaScript, TypeScript                                                                                             |
| Framework                                      | Playwright Test                                                                                                    |
| Framework versions researched                  | Current Playwright docs as of 2026-06-10                                                                           |
| Package/project markers                        | `@playwright/test` or `playwright` dependency, package scripts containing `playwright test`, `playwright.config.*` |
| Primary command-line tool                      | `npx playwright test`                                                                                              |
| CodeTracer recorder/backend used for recording | Browser trace ingestion is not wired in M8                                                                         |
| Minimum supported platform(s)                  | Node.js plus installed Playwright browser binaries                                                                 |

Sources:

- Playwright CLI: https://playwright.dev/docs/test-cli
- Playwright reporters and JSON reporter: https://playwright.dev/docs/test-reporters
- Playwright TestResult API: https://playwright.dev/docs/api/class-testresult
- Playwright trace viewer and trace modes: https://playwright.dev/docs/trace-viewer
- Playwright run filters: https://playwright.dev/docs/running-tests

## Project Detection

- Prefer explicit package dependencies on `@playwright/test` or `playwright`.
- A package script containing `playwright test` is sufficient.
- `playwright.config.js`, `.cjs`, `.mjs`, `.ts`, `.cts`, and `.mts` are accepted as framework markers.

## Discovery

- Framework-native discovery should run:
  `npx --no-install playwright test [file] --workers=1 --list --reporter=json`
- M8 parses Playwright JSON reporter/list output under the documented JSON reporter shape. Items are built from `suites[].specs[]`, using `file`, `line`, `column`, `title`, `titlePath`, `tags`, and `tests[].projectName`.
- Source selectors are `{relativeFile}::{suite title > test title}`.
- Location provenance is `framework/exact` because Playwright reports file and line in JSON output.

## Execution Commands

| Operation        | Command                                                                      |
| ---------------- | ---------------------------------------------------------------------------- |
| Run project      | `npx --no-install playwright test --workers=1 --reporter=json`               |
| Run file batch   | `npx --no-install playwright test {file} --workers=1 --reporter=json`        |
| Run single test  | Not advertised in M8                                                         |
| Discover project | `npx --no-install playwright test --workers=1 --list --reporter=json`        |
| Discover file    | `npx --no-install playwright test {file} --workers=1 --list --reporter=json` |

Playwright also supports selecting a test by file line such as
`npx playwright test example.spec.ts:10`, but M8 intentionally exposes
file-level batches only. This avoids promising stable single-test selectors
before duplicate titles, generated tests, projects, retries, and browser
artifacts are fully mapped.

## Per-Test Output And Status Capture

- JSON result ingestion walks each spec's `tests[].results[]`.
- `passed` maps to `passed`, `failed` maps to `failed`, `skipped` maps to
  `skipped`, and `timedOut`/`interrupted` map to `errored`.
- `stdout` and `stderr` arrays become `output` events.
- Failed or errored results emit a `failure` event before `test-finished`.
- The file batch emits `run-started`, one `test-started`/`test-finished` pair
  per spec, and `run-finished`.

## Recording Feasibility

Playwright can create its own browser traces using config or run-time trace
settings such as `on`, `retain-on-failure`, `on-first-retry`, and
`on-all-retries`. M8 does not advertise CodeTracer recording for Playwright
because the local environment has no installed `@playwright/test` package or
browser binaries, and CodeTracer has no wired browser-trace ingestion path for
Playwright `trace.zip` artifacts yet.

The provider therefore sets all record capabilities to false and returns an
explicit unsupported diagnostic if record is called.

## Limitations And Follow-Ups

- Local verification in this workspace cannot run real Chromium tests because
  `npx --no-install playwright` cannot resolve Playwright and browser binaries
  are not installed.
- M8 tests use fixture Playwright JSON outputs that mirror documented reporter
  fields instead of faking a successful browser run.
- Single-test execution remains unsupported.
- Multi-project output currently produces one normalized item per spec with
  project names as tags. A future provider may need project-specific item IDs.
- Playwright traces are parsed only as result attachments today; no CodeTracer
  trace metadata is emitted.
- Sharding, retries, repeat-each, custom reporters, component testing, and
  transformed-source sourcemaps remain follow-up work.

## Fixture

- Fixture project: `src/ct_test/fixtures/js_playwright_project`
- Specs: `tests/home.spec.ts` and `tests/form.spec.ts`
- Browser target in config: Chromium
- Expected failing test: `form flow > fails on missing output`
- JSON fixture inputs: `.ct-test/playwright-list.json` and
  `.ct-test/playwright-results.json`
