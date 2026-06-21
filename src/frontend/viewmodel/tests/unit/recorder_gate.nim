## Shared missing-recorder gating for the headless ViewModel
## (`headless_session`) acceptance tests.
##
## ## Why this module exists
##
## The column-aware / formatted-view ViewModel tests under this directory
## each drive a *real* language recorder (`codetracer-<lang>-recorder`, the
## JS recorder, the Nim VM tracer, `nargo`, …) to produce a trace and then
## replay it through `headless_session.nim`.  Every one of these tests is
## gated on the corresponding recorder sibling being checked out and built.
##
## Historically two *different* behaviours coexisted for the **identical**
## "recorder sibling not built" condition:
##
##   * Some tests (JS, PolkaVM, Solana, Nim, Flow) resolved the recorder via
##     a `find…Recorder()` that **raised `IOError`** when the binary was
##     missing.  An unhandled `IOError` aborts the test block with a stack
##     trace and is reported as FAILED — indistinguishable, to a CI log
##     reader, from a genuine product regression.
##   * Other tests (Cairo, EVM, Move, Wasm, Noir) returned an empty string
##     and called `skip()` with an ad-hoc `echo` line whose wording differed
##     from test to test.
##
## Neither a silent pass nor an unexplained crash is acceptable: per
## `codetracer-specs/Working-with-the-CodeTracer-Repos.md` §C ("Env-var-gated
## tests"), a missing cross-repo prerequisite must be reported as a *clear,
## greppable* skip — never a silent success and never an opaque exception.
##
## This module makes that outcome **uniform**.  Every recorder-gated test
## routes its missing-recorder path through `skipMissingRecorder` (directly,
## or via the `requireRecorderOrSkip` convenience template), which emits a
## single grep-friendly marker line and then calls unittest's `skip()`.
## Present-recorder runs are unaffected: the test body still runs for real
## and its assertions still fail loudly on a genuine regression.
##
## ## Greppable contract
##
## The emitted line always starts with the literal prefix
## `MISSING-RECORDER SKIP:` so CI and humans can grep for skipped
## prerequisites with a single pattern across the whole suite, e.g.
##
##   grep -r 'MISSING-RECORDER SKIP:' <test logs>

import std/unittest

const MissingRecorderSkipPrefix* = "MISSING-RECORDER SKIP:"
  ## Stable, greppable marker prefix shared by every recorder-gated test.
  ## Do not reword without updating the docs above and any CI greps.

proc missingRecorderMessage*(recorderName, envVar, buildHint: string): string =
  ## Build the uniform, greppable diagnostic line for a missing recorder.
  ## Factored out of `skipMissingRecorder` so the message construction is
  ## testable and identical regardless of caller.
  let envClause =
    if envVar.len > 0: envVar & " unset and "
    else: ""
  MissingRecorderSkipPrefix & " " & recorderName & " not available (" &
    envClause & "no built sibling found). " & buildHint

template skipMissingRecorder*(recorderName, envVar, buildHint: string) =
  ## Report a missing recorder prerequisite uniformly.
  ##
  ## Emits one greppable diagnostic line and then calls unittest's `skip()`
  ## so the surrounding `test` block is recorded as skipped rather than
  ## failing with an opaque exception.
  ##
  ## This MUST be a template (not a proc): `unittest.skip()` expands to code
  ## that references the per-`test` `testStatusIMPL` symbol, which only
  ## exists inside a `test` block's scope.  A template expands `skip()` at
  ## the call site so it picks up that symbol; a proc would not compile.
  ##
  ## NOTE: `skip()` only sets the test status — it does NOT abort the rest
  ## of the test body (and `return` is not permitted inside a `test` block).
  ## Callers must therefore guard the recorder-dependent body so it does not
  ## run when the recorder is missing; the `requireRecorderOrSkip` template
  ## below encapsulates that guard.
  ##
  ## Parameters:
  ##   * `recorderName` — human-readable recorder name, e.g.
  ##     `"codetracer-js-recorder"`.
  ##   * `envVar` — the env var that overrides the recorder path, e.g.
  ##     `"CODETRACER_JS_RECORDER_PATH"`.  Pass `""` when the recorder has
  ##     no path override.
  ##   * `buildHint` — a one-line "how to build it" hint, e.g.
  ##     `"Build the codetracer-js-recorder sibling (just build)."`.
  echo missingRecorderMessage(recorderName, envVar, buildHint)
  skip()

template requireRecorderOrSkip*(recorderPath: string;
                                recorderName, envVar, buildHint: string;
                                body: untyped) =
  ## Run `body` only when `recorderPath` resolves to a built recorder;
  ## otherwise report a uniform, greppable skip and do not run `body`.
  ##
  ## `recorderPath` is the result of the test's own `find…Recorder()`
  ## resolver, which must return the empty string (rather than raising)
  ## when the recorder is missing.  This keeps the missing-recorder
  ## decision in one place and identical across every recorder-gated test.
  if recorderPath.len == 0:
    skipMissingRecorder(recorderName, envVar, buildHint)
  else:
    body
