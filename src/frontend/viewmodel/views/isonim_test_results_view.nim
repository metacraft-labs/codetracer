## views/isonim_test_results_view.nim
##
## IsoNim view for the Test Results pane (`Content.TestResults`).
##
## Structure, both renderers::
##
##   div.component-container.test-results
##     div.test-results-header
##       div.test-results-headline    text "5 tests, not run yet"
##       div.test-results-run-btn[.disabled]   click -> vm.startRun()
##     div.test-results-body
##       div.test-results-row[.not-run|.passed|.failed|…]   (one per test)
##                           data-ct-test-id data-ct-recording-id
##                           data-ct-recorded-at
##         span.test-results-mark      "✓" / "✗" / "·" / …
##         span.test-results-name      "test_main"
##         span.test-results-where     "src/main.nr:13"
##         span.test-results-duration  "2 ms"   (only once it has run)
##         span.test-results-actions
##           span.test-results-refresh-btn[.disabled]  click -> triggerRefresh
##           span.test-results-open-btn[.shift-armed][.disabled]
##                                     data-ct-open-mode   click -> triggerOpen
##         div.test-results-message                (failures only)
##     div.test-results-failure[.hidden]
##       div.test-results-failure-line   one per run-level diagnostic
##     div.test-results-absence[.hidden]
##       text  why a run cannot be started here
##     div.test-results-empty[.hidden]
##       text "No tests found in this project."
##
## ## The failure block is what a faulted run looks like
##
## `.test-results-failure` renders `vm.runFailure` — the run-level diagnostics
## of a settled run — and it exists because this pane used to answer a faulted
## run with the sentence it had shown before the ▶ was pressed. The BUILD pane
## received those same lines and rendered them; this one received them, folded
## them into `TestRunSummary.diagnostics`, and painted nothing.
##
## It is DISTINCT FROM `.test-results-absence` and the two must not be merged.
## An absence is a statement about a deployment that was true before anyone
## clicked, and is not an error. A failure is the outcome of a run that was
## actually attempted. They can also be true at once — a build with no
## compiler module states an absence AND, if something dispatches anyway,
## faults — and a single node would have to pick one to lose.
##
## ## Why the mark is a glyph and the state is also a class
##
## §1a's mock-up reads `✓ test_main 2ms`, so the glyph is what a user scans.
## But a glyph is not a machine-readable state, and
## `ci/test/web-renderer-mounts.sh` asserts on PAINTED TEXT — so the class
## carries the state for CSS and the glyph carries it for the reader, and the
## gate can check either. The row's text is deliberately self-sufficient: a
## reader who cannot see colour still gets mark, name, location and duration.
##
## ## The absence line is not an error state
##
## `runAbsence` is shown as ordinary content, below the rows, because when it
## is set it is a statement about a DEPLOYMENT rather than a fault: a bundle
## that placed no Noir compiler module cannot run tests, and rendering that as
## an error would tell a visitor something is broken when nothing is.
##
## It is empty on an ordinary web deployment. It used to be a permanent
## paragraph saying a browser cannot run `nargo test` at all; the wasm module
## now exports `nv_test_vfs` and the worker routes `test` to it, so that
## paragraph was prose asserting an absence that had been filled. The ▶ beside
## the headline is what replaced it.
##
## ## THE ROW'S CLASS NAMES AVOID A SUBSTRING TRAP
##
## The actions wrapper is `test-results-actions` and NOT
## `test-results-row-actions`. Every reader of this DOM — the checks in this
## repo, `ci/test/web_renderer_probe.mjs`, and `mock_dom`-based suites — finds
## nodes by asking whether a class name is CONTAINED IN the class attribute, so
## a wrapper named `test-results-row-actions` would be counted as a
## `test-results-row` and every "the pane lists five tests" assertion would
## silently start reporting ten. The trap is invisible until a count is wrong
## for a reason nobody looks at.
##
## ## SHIFT IS TRACKED ON THE DOCUMENT, AND THE TITLES ARE UPDATED IN PLACE
##
## Two render effects, and the split is the point.
##
## The FIRST rebuilds rows when the run or the catalog changes. The SECOND
## depends only on `vm.shiftHeld` and walks button handles the first stored,
## rewriting `title`, `class`, `data-ct-open-mode` and the glyph WITHOUT
## replacing any node. Rebuilding the row on every keydown would work, but it
## tears down the element the pointer is resting on — which dismisses the very
## tooltip the user is reading, at the exact moment the modifier is supposed to
## change what it says.
##
## WHICH IS WHY THE STRUCTURAL EFFECT PAINTS THE OPEN BUTTON INSIDE `untrack`,
## and this is not a micro-optimisation. The paint reads `vm.shiftHeld`, so
## without `untrack` the STRUCTURAL effect subscribes to it too and a keypress
## rebuilds every row after all — the separation above becomes decorative. It
## was measured doing exactly that: the two effects both ran on the first
## Shift, the shift effect updated the button the pointer was on and the
## structural one then replaced it, and on release only the shift effect ran —
## over the NEW nodes — leaving the element the user was actually looking at
## frozen in its armed state, promising a re-record it would no longer perform.
## `test_tests_pane_row_controls`'s `shift-liveness` case holds one node across
## the whole toggle for that reason, and asserts its identity is unchanged.
##
## The listeners are on `document` and not on the button, and that is not
## laziness: a `keydown` only reaches an element that has focus, and the user
## whose discoverability this is for is HOVERING the button, not tabbed into
## it. A button-scoped listener would fire for nobody.
##
## `keyup` is not the only way Shift stops being held — alt-tabbing away eats
## it — so `blur` on the window clears the flag too. Without that the pane
## would sit permanently armed, promising a re-record to every subsequent
## click.
##
## ## Why the ▶ is disabled rather than hidden
##
## A control that vanishes cannot be told apart from a feature that does not
## exist. `vm.canRun` is false in three different situations — no host
## installed a runner, the deployment stated a reason, a run is already in
## flight — and in all three the button stays in place with a `disabled` class
## and a `title` that says which. That is `stopButtonClass`'s rule in the build
## view, applied to the same shape of question.

import std/strutils

import isonim/core/[signals, computation]
# `untrack`, and it is load-bearing rather than an optimisation — see
# "SHIFT IS TRACKED ON THE DOCUMENT" in the header, and `paintOpenButton`'s
# own comment for the failure it fixes.
from isonim/core/batch import untrack
import isonim/dsl/[ui, components]

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/test_results_vm

# The generic view expands the DSL where it is instantiated.
export signals, computation, components

const TestResultsContainerClass* = "component-container test-results"

proc stateClass*(state: TestResultsRowState): string =
  "test-results-row " & $state

# `stateMark`, `rowWhere`, `rowDuration`, `runButtonTitle` and
# `EmptyStateText` are the ViewModel's since PLAT-53 — the terminal's pane and
# the GPUI window draw the same words (`Test-Results-Pane.md` §8.4) — and are
# re-exported here, so this view's readers see them where they always did.
export stateMark, rowWhere, rowDuration, runButtonTitle, EmptyStateText,
       RunTestsTitle, RunButtonLabel

proc runButtonClass*(vm: TestResultsVM): string =
  ## `disabled` follows `canRun`, so the class a gate reads and the guard the
  ## click takes are one decision rather than two that can drift.
  if vm.canRun(): "test-results-run-btn"
  else: "test-results-run-btn disabled"

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

type
  RowActionHandles[N] = object
    ## The two buttons of one row, kept so the shift effect can rewrite them
    ## in place rather than rebuilding the row. `row` is the value they were
    ## built for — the mode depends on `row.recordingId`, so recomputing the
    ## title needs the row and not just the id.
    row: TestResultsRow
    openButton: N
    rowNode: N
      ## The row itself, for the selection's class (§9.3).

proc applyOpenButton[R, N](r: R; vm: TestResultsVM;
                          handle: RowActionHandles[N]) =
  ## The open button's four shift-sensitive faces, from ONE call to
  ## `openButtonMode` inside the VM's own accessors.
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin clearChildren, appendChild, setAttribute, createTextNode
  r.setAttribute(handle.openButton, "class", openButtonClass(vm, handle.row))
  r.setAttribute(handle.openButton, "title", openButtonTitle(vm, handle.row))
  r.setAttribute(handle.openButton, "aria-label",
                 openButtonTitle(vm, handle.row))
  r.setAttribute(handle.openButton, "data-ct-open-mode",
                 $openButtonMode(vm, handle.row))
  r.clearChildren(handle.openButton)
  r.appendChild(handle.openButton,
                r.createTextNode(openButtonMark(vm, handle.row)))

proc applySelection[R, N](r: R; vm: TestResultsVM;
                          handle: RowActionHandles[N]) =
  ## Test-Results-Pane.md §9.3: the selected row — what the palette's
  ## **Tests: Run** / **Tests: Run in Current Tab** act on — marked.
  mixin setAttribute
  let selected = vm.selectedTestId.val == handle.row.testId
  r.setAttribute(handle.rowNode, "class", stateClass(handle.row.state) &
    (if selected: " selected" else: ""))
  r.setAttribute(handle.rowNode, "data-ct-selected",
                 if selected: "true" else: "")

proc renderRow[R, N](r: R; vm: TestResultsVM; row: TestResultsRow;
                     handle: var RowActionHandles[N]): N =
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin appendChild, setAttribute
  let mark = stateMark(row.state)
  let where = rowWhere(row)
  let duration = rowDuration(row)
  let message = row.message
  var refreshButton, openButton, nameNode, whereNode: N
  let node = ui(r):
    # A click on the row — or on its ⟳ / ⏵, which bubble here — selects it
    # (§9.3: the row the palette pair acts on).
    tdiv(class = stateClass(row.state),
         onclick = proc() = vm.selectTest(row.testId)):
      span(class = "test-results-mark"):
        text mark
      span(ref = nameNode, class = "test-results-name"):
        text row.name
      span(ref = whereNode, class = "test-results-where"):
        text where
      span(class = "test-results-duration"):
        text duration
      span(class = "test-results-actions"):
        span(ref = refreshButton, class = "test-results-refresh-btn",
             onclick = proc() = vm.triggerRefresh(row)):
          text "⟳"
        span(ref = openButton, class = "test-results-open-btn",
             onclick = proc() = vm.triggerOpen(row)):
          discard
  # THE IDENTITIES, ON THE ROW. `data-ct-recording-id` is what lets a check
  # answer "did that click re-execute?" by comparing two strings — see
  # `TestResultsRow.recordingId`.
  #
  # AND THE TIME IS PUBLISHED BESIDE IT, as a SECOND witness to the same fact.
  # The id alone would carry the claim on its own, and a single string carrying
  # a claim is what Verification-Harness-Traps.md warns about: an implementation
  # that re-ran the test but minted the id from the selector would leave the id
  # unchanged and pass. The two are produced by different code at different
  # moments — the id is minted per retention in `web_noir_build`, the time is
  # read off the clock at the same instant — so "⏵ executed nothing" is
  # asserted twice over, and an id that is stable for the wrong reason no
  # longer certifies it. `recordedAtText` is emphatically NOT an identity and
  # is not used as one (see `rememberRecording`); it is corroboration.
  r.setAttribute(node, "data-ct-test-id", row.testId)
  r.setAttribute(node, "data-ct-recording-id", row.recordingId)
  r.setAttribute(node, "data-ct-recorded-at", row.recordedAtText)
  # THE FULL NAME AND THE FULL PATH, ON HOVER. This pane is a tab of a ~285px
  # panel and now carries two controls, so both text columns ellipsis — which
  # is the right trade only if the truncated text is still recoverable. The
  # selector rather than the short name, because that is the string a reader
  # would paste into `nargo test --exact`.
  r.setAttribute(nameNode, "title", row.selector)
  if rowWhere(row).len > 0:
    r.setAttribute(whereNode, "title", rowWhere(row))
  r.setAttribute(refreshButton, "class", refreshButtonClass(vm))
  r.setAttribute(refreshButton, "title", refreshButtonTitle(vm, row))
  r.setAttribute(refreshButton, "aria-label", refreshButtonTitle(vm, row))
  handle = RowActionHandles[N](row: row, openButton: openButton,
                               rowNode: node)
  # UNTRACKED. This runs inside the structural effect, and the paint reads
  # `vm.shiftHeld`; a tracked read here makes the structural effect a
  # subscriber and every keypress rebuilds the row. See the header.
  let handleCopy = handle
  untrack proc() = applyOpenButton[R, N](r, vm, handleCopy)
  untrack proc() = applySelection[R, N](r, vm, handleCopy)
  if message.len > 0:
    let detail = ui(r):
      tdiv(class = "test-results-message"):
        text message
    r.appendChild(node, detail)
  node

proc renderFailureLine[R, N](r: R; line: string): N =
  ## One run-level diagnostic, verbatim. Never truncated: the sentence a
  ## faulted run leaves is the only thing the pane can offer a reader who
  ## wants to know why, and it is the same text the BUILD pane shows in full.
  ui(r):
    tdiv(class = "test-results-failure-line"):
      text line

when defined(js):
  proc eventShiftKey(ev: isonim_dom.Event): bool
    {.importjs: "(#.shiftKey === true)".}
    ## `isonim/web/dom_api.Event` does not declare `shiftKey`, and this reads it
    ## without widening a sibling repo's public type for one field. `=== true`
    ## rather than a coercion so an event that has no such property answers
    ## `false` instead of `undefined`.

  proc eventRedirectKey(ev: isonim_dom.Event): bool
    {.importjs: "(function(e){return e.ctrlKey === true || (typeof navigator !== 'undefined' && /Mac/.test(navigator.platform) && e.metaKey === true);})(#)".}
    ## Test-Results-Pane.md §9.3: the redirect modifier — Ctrl, or Cmd on
    ## macOS (VS Code's `CtrlCmd`).

  proc platformIsMac(): bool
    {.importjs: "(typeof navigator !== 'undefined' && /Mac/.test(navigator.platform))".}

  proc installShiftTracking(vm: TestResultsVM) =
    ## Keydown, keyup and blur, on the DOCUMENT — for Shift and, since
    ## Test-Results-Pane.md §9.3, for the redirect modifier the same way.
    ##
    ## See the header: a listener on the button would never fire, because the
    ## user this exists for is hovering it rather than focused in it. `blur`
    ## is here because alt-tab eats the `keyup` — without it the pane stays
    ## armed and every later click silently re-records.
    let docNode = isonim_dom.Node(isonim_dom.document)
    if platformIsMac():
      vm.redirectKeyName = "Cmd"
    isonim_dom.addEventListener(docNode, cstring"keydown",
      proc(ev: isonim_dom.Event) =
        vm.setShiftHeld(eventShiftKey(ev))
        vm.setRedirectHeld(eventRedirectKey(ev)))
    isonim_dom.addEventListener(docNode, cstring"keyup",
      proc(ev: isonim_dom.Event) =
        vm.setShiftHeld(eventShiftKey(ev))
        vm.setRedirectHeld(eventRedirectKey(ev)))
    isonim_dom.addEventListener(docNode, cstring"blur",
      proc(ev: isonim_dom.Event) =
        vm.setShiftHeld(false)
        vm.setRedirectHeld(false))
    # `mouseover` carries the modifier state too, and it is what corrects the
    # flag when the pointer ARRIVES on the pane with Shift already down — a
    # keydown that happened before the pane existed reached nobody.
    isonim_dom.addEventListener(docNode, cstring"mouseover",
      proc(ev: isonim_dom.Event) =
        vm.setShiftHeld(eventShiftKey(ev))
        vm.setRedirectHeld(eventRedirectKey(ev)))


proc renderTestResultsPanel*[R, N](r: R; vm: TestResultsVM): N =
  ## The Test Results panel, under any renderer (Shared-DOM-Front-Ends D3),
  ## mounted on the desktop by `ui/panel_host`.
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin clearChildren, appendChild, setAttribute, createTextNode
  var headlineNode, bodyContainer, failureNode, absenceNode, emptyContainer,
      runButton: N
  var openHandles: seq[RowActionHandles[N]] = @[]

  let panel = ui(r):
    tdiv(class = TestResultsContainerClass, tabIndex = "2"):
      tdiv(class = "test-results-header"):
        tdiv(ref = headlineNode, class = "test-results-headline"):
          discard
        tdiv(ref = runButton, class = "test-results-run-btn",
             title = RunTestsTitle,
             onclick = proc() = vm.startRun()):
          text RunButtonLabel
      tdiv(ref = bodyContainer, class = "test-results-body"):
        discard
      tdiv(ref = failureNode, class = "test-results-failure hidden"):
        discard
      tdiv(ref = absenceNode, class = "test-results-absence hidden"):
        discard
      tdiv(ref = emptyContainer, class = "test-results-empty hidden"):
        text EmptyStateText

  createRenderEffect proc() =
    let rows = vm.rows.val
    let absence = vm.runAbsence.val
    let failures = vm.runFailure.val

    r.clearChildren(headlineNode)
    r.appendChild(headlineNode, r.createTextNode(vm.headline.val))

    r.setAttribute(runButton, "class", runButtonClass(vm))
    r.setAttribute(runButton, "title", runButtonTitle(vm))

    r.clearChildren(bodyContainer)
    openHandles = @[]
    for row in rows:
      var handle: RowActionHandles[N]
      let node = renderRow[R, N](r, vm, row, handle)
      openHandles.add handle
      r.appendChild(bodyContainer, node)

    r.clearChildren(failureNode)
    for line in failures:
      r.appendChild(failureNode, renderFailureLine[R, N](r, line))
    r.setAttribute(failureNode, "class",
      if failures.len > 0: "test-results-failure"
      else: "test-results-failure hidden")

    r.clearChildren(absenceNode)
    if absence.len > 0:
      r.appendChild(absenceNode, r.createTextNode(absence))
      r.setAttribute(absenceNode, "class", "test-results-absence")
    else:
      r.setAttribute(absenceNode, "class", "test-results-absence hidden")

    if rows.len == 0:
      r.setAttribute(emptyContainer, "class", "test-results-empty")
    else:
      r.setAttribute(emptyContainer, "class", "test-results-empty hidden")

  # THE SHIFT EFFECT. Depends on `vm.shiftHeld` and NOTHING ELSE — `openHandles`
  # is a plain `var`, so reading it creates no dependency and this effect does
  # not re-run when the rows do (the structural effect above has already
  # painted the current mode onto the buttons it just built).
  #
  # Test-Results-Pane.md §9.4: the title's last sentence — where the press
  # opens the recording — reads the redirect modifier, the setting, the
  # current tab and which tests have tabs, so those are its inputs too.
  createRenderEffect proc() =
    discard vm.shiftHeld.val
    discard vm.redirectHeld.val
    discard vm.openSetting.val
    discard vm.currentTab.val
    discard vm.currentTabReplaceable.val
    discard vm.sessionTabsShown.val
    discard vm.testTabs.val
    for handle in openHandles:
      applyOpenButton[R, N](r, vm, handle)

  # THE SELECTION EFFECT (§9.3): the selected row's class, rewritten in
  # place when the selection moves — the rows are not rebuilt.
  createRenderEffect proc() =
    discard vm.selectedTestId.val
    for handle in openHandles:
      applySelection[R, N](r, vm, handle)

  # Shift arms re-recording on the open buttons; in a browser the key state
  # is tracked on the document (see `installShiftTracking`).
  when defined(js):
    when N is isonim_dom.Element:
      installShiftTracking(vm)

  panel
