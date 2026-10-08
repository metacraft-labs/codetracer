## A run control must not claim a run STARTED before anything took it.
##
## LANE: `vm-unit` (and `vm-unit-js`) by the directory glob.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_run_start_is_not_claimed_before_dispatch.nim
##
## ## WHY THIS SUITE READS SOURCE TEXT, WHICH IS NOT WHAT A TEST SHOULD DO
##
## Both subjects live in `src/frontend/ui/`, which is JS-target and
## DOM-bound: `editor.makeTestAction` builds a `Node` and talks to Monaco,
## and `web_noir_build.dispatch` reaches `ctPlatform().process.start`
## through the build pane. Neither can be instantiated by a `nim c` unit
## suite, and the behavioural gate that CAN see them — arm G of
## `ci/test/web_renderer_probe.mjs` — needs a served bundle and a
## Playwright browser.
##
## That gate exists and it stays the real one. What it does not do is run
## on every `vm-unit` invocation, and what it cannot do is fail for a
## reason a reader can act on in one line. Both defects below are
## STATEMENT ORDER — a claim made before the thing it claims — and
## statement order is exactly what source text can pin cheaply and
## exactly.
##
## So this is a contract test over two orderings, and its limits are
## stated rather than implied:
##
##   * it is defeated by a rename or a reformat, which is why every
##     needle below is asserted to be FINDABLE before it is asserted to
##     be positioned — a suite that silently stopped locating its
##     subject would pass while measuring nothing, and the `located`
##     checks are what stop that;
##   * it says nothing about whether the spinner clears, only about
##     whether the claim is made before or after the answer.
##
## ## THE DEFECT
##
## A click on a Run-test control reached `editorTestRunHook`, which
## reaches `web_noir_build.startNoirTestRecording`. When the platform has
## no process-spawn capability — a deployment with the wasm worker script
## missing — `dispatch` refuses BEFORE anything runs, paints the sentence
## into the build pane, and returns without setting `activeInFlight`.
##
## `startNoirTestRecording` noticed that, settled the run, and then fell
## off the end returning the implicit `""` — which its own docstring
## defines as "the run was dispatched". The editor read `""` as consent.
##
## `runTestFromGutter` was repaired for this. `makeTestAction`'s inline
## widget — still painted for any `#[test]` or Python test on a line the
## catalog does not name — was not: it called the hook FIRST and armed
## the spinner afterwards, so the settle that happened synchronously
## inside the hook swept a list this editor had not yet joined, and then
## the lines below armed an animation no second settle would arrive to
## clear. `loadAnimation`'s 400-frame cap ended it two minutes later,
## under a `"<selector>" started` message.

import std/[os, strutils, unittest]

const thisFile = currentSourcePath()

proc repoFile(relative: string): string =
  ## `src/frontend/viewmodel/tests/unit/<this>` -> repo root.
  var root = thisFile.parentDir.parentDir.parentDir.parentDir.parentDir.parentDir
  result = root / relative

proc readSubject(relative: string): string =
  let path = repoFile(relative)
  require fileExists(path)
  readFile(path)

suite "a run control does not claim a start it has not been given":

  test "`dispatch` hands back its refusal instead of leaving it to be inferred":
    ## The type is the fix. A `void` `dispatch` cannot be misread, because
    ## there is nothing to read — it can only be assumed, and the one
    ## caller with a user waiting had assumed consent.
    let source = readSubject("src/frontend/ui/web_noir_build.nim")

    let declarations = source.count("proc dispatch(producer: NoirBuildProducer")
    check declarations == 2  # forward declaration + definition

    # Both must be string-returning. A forward declaration left at `void`
    # is not a cosmetic mismatch: it is what the earlier call sites are
    # typed against, and Nim resolves them through it.
    var scan = 0
    var stringReturning = 0
    for _ in 0 ..< declarations:
      let at = source.find("proc dispatch(producer: NoirBuildProducer", scan)
      check at >= 0
      # The signature spans three lines; take the whole of it.
      let signatureEnd = source.find("label: string", at)
      check signatureEnd >= 0
      let tail = source[signatureEnd ..< min(signatureEnd + 40, source.len)]
      if tail.startsWith("label: string): string"):
        inc stringReturning
      scan = at + 1
    check stringReturning == 2

  test "a declined dispatch is reported as a refusal, not as an empty string":
    ## `startNoirTestRecording`'s contract is `"" means dispatched`. The
    ## `not activeInFlight` branch is the one place that knows the
    ## dispatch was declined, and it used to end by falling through to
    ## the implicit `""`.
    let source = readSubject("src/frontend/ui/web_noir_build.nim")

    let procAt = source.find("proc startNoirTestRecording*(")
    check procAt >= 0
    let nextProc = source.find("\nproc ", procAt + 10)
    check nextProc > procAt
    let body = source[procAt ..< nextProc]

    # The dispatch's answer must be BOUND, not discarded: this is the one
    # caller that has a person waiting on it.
    check body.contains("let refusal = dispatch(")

    let branchAt = body.find("if not activeInFlight:")
    check branchAt >= 0
    let branch = body[branchAt .. ^1]

    check branch.contains("return refusal")
    # And the branch must not be able to run off its end: every path out
    # of it returns a sentence.
    let returns = branch.count("    return ")
    check returns >= 2

  test "the inline Run-test widget arms the spinner BEFORE it asks the host":
    ## The ordering IS the defect. Armed after the hook, a dispatch
    ## refused synchronously inside the hook settles a list this editor
    ## has not joined yet, and the arm that follows is unreachable by any
    ## later settle.
    let source = readSubject("src/frontend/ui/editor.nim")

    let widgetAt = source.find("proc makeTestAction(")
    check widgetAt >= 0
    let nextProc = source.find("\nproc ", widgetAt + 10)
    check nextProc > widgetAt
    let body = source[widgetAt ..< nextProc]

    let hookAt = body.find("editorTestRunHook(self.name, selector, line)")
    check hookAt >= 0
    let armAt = body.find("spinningTestEditors.add(self)")
    check armAt >= 0

    check armAt < hookAt

  test "and it does not say `started` when the run already settled inside the call":
    ## `runTestFromGutter` carries this guard; the inline widget had no
    ## equivalent, which is what turned a synchronous refusal into a
    ## two-minute spinner under a false claim.
    let source = readSubject("src/frontend/ui/editor.nim")

    let widgetAt = source.find("proc makeTestAction(")
    check widgetAt >= 0
    let nextProc = source.find("\nproc ", widgetAt + 10)
    check nextProc > widgetAt
    let body = source[widgetAt ..< nextProc]

    let hookAt = body.find("editorTestRunHook(self.name, selector, line)")
    check hookAt >= 0
    let claimAt = body.find("\" started\"")
    check claimAt >= 0

    # THE NEEDLE INCLUDES THE `return`, and that is not decoration. The
    # pre-fix source contains the same condition twice as an ARM --
    # `if spinningTestEditors.find(self) < 0:` / `spinningTestEditors.add(self)`
    # -- so a needle that stopped at the colon matched the defect itself
    # and reported green. It did, on the first run of this suite. What is
    # being asserted is a guard that LEAVES, not a condition that reads
    # the same list.
    let guardAt = body.find(
      "if spinningTestEditors.find(self) < 0:\n        return", hookAt)
    check guardAt >= 0
    check guardAt < claimAt
