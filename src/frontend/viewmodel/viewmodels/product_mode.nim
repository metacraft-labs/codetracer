## viewmodels/product_mode.nim — PLAT-16.
##
## **WHICH SOURCE DOES A MODE SHOW.** That is the whole question this module
## answers, and `codetracer-specs/Front-Ends/CodeTracer-TUI-Edit-Mode.md` §2 is
## explicit that it is a **core** question rather than a terminal one:
##
##   *"This is not a terminal problem. It is a question about the shared core
##   that the TUI merely makes unavoidable … The answer belongs in the core and
##   applies to every front-end equally."*
##
## So the answer lives here, in `viewmodels/`, beside the other pure ViewModel
## modules that the Electron build, the web build and the terminal build all
## reach through `codetracer_embed`. A copy of it in `src/frontend/tui/` would
## be an answer one front-end had and the others did not, which is the shape
## §1 of that document exists to forbid.
##
## ## THE TWO DIMENSIONS, AND WHY THIS MODULE DECLARES ONLY ONE OF THEM
##
## §1.2 names the conflation to avoid, and this module is one half of avoiding
## it:
##
##   * **Input modes** — `NORMAL` / `COMMAND` / `SEARCH` / `INSPECT` /
##     `VISUAL` / `SEEK`. A terminal vocabulary, owned by
##     `tui/app/input/modal_state.nim` and indicated by
##     `tui/app/views/status_bar.UiMode`. **Not here, and this module does not
##     import either of them** — it cannot, they are in a different tree.
##   * **Product modes** — Edit and Debug. Owned here.
##
## They are orthogonal: a user is in Edit mode *and* in NORMAL input mode, and
## both indicators are true at once. §1.2: *"Getting this wrong produces a state
## machine with fifteen states that should have two dimensions, and it will not
## be recoverable once bindings depend on it."*
##
## `ProductMode` therefore has **two** members and `UiMode` keeps its **six**.
## `tui/app/tests/test_layout_profiles.nim` asserts the second cardinality and
## `tui/app/tests/test_product_mode_dimensions.nim` asserts the first, the
## product of the two, and that neither enum can name a member of the other.
##
## ## `ProductMode` IS NOT A SEVENTH LAYOUT MODE
##
## The product already has a mode vocabulary: `LayoutMode` in
## `common/common_types/debugger_features/debugger.nim`, five members, of which
## three are editing layouts and two are replaying ones. `edit_mode_toolbar.
## ToolbarMode` mirrors it member-for-member with a `static` derived check, and
## `edit_mode_toolbar.isEditing` is the partition.
##
## This module does not add a second mirror. It **derives** from that one:
## `productModeOf` is `isEditing` with two names instead of a `bool`, and the
## `static` block below fails the build if the partition ever stops being total.
## A sixth hand-maintained table is precisely what `edit_mode_toolbar`'s own
## header records this repository having been bitten by five times.
##
## ## PURITY
##
## No `std/os`, no process, no `cstring` — the same rule `edit_mode_toolbar`
## states for itself, so the same suites run on C (`vm-unit`) and JS
## (`vm-unit-js`). The one non-`std` import beyond the ViewModel tree is
## `../sdk/source_provider`, and it is here for the **type**: `SourceOrigin` is
## the vocabulary CTUI-4 built for exactly this distinction, and answering in a
## second enum of this module's own would mean two vocabularies for one fact.

import std/strutils

import ../sdk/source_provider
import ./edit_mode_toolbar

export SourceOrigin

type
  ProductMode* = enum
    ## CodeTracer's two application modes
    ## (`codetracer-specs/GUI/GUI-Overview.md` § Application Modes).
    ##
    ## Spelled as an indicator shows them, for the same reason `UiMode` is: the
    ## product mode appears on screen and `$` on an unnamed enum is how a
    ## failure report becomes unreadable.
    ##
    ## TWO MEMBERS, AND THAT IS A CONTRACT RATHER THAN AN OBSERVATION.
    ## DeepReview is not a third — `Mode-Transitions.md` says so in its own
    ## words ("DeepReview is **not** a third mode in this sense") — and an input
    ## mode is not a third either.
    pmDebug = "DEBUG"
    pmEdit = "EDIT"

  ModeSourceContract* = object
    ## §2's table, as a value, so a front-end reads the answer rather than
    ## re-deriving it.
    ##
    ## Every field is one column of that table. A front-end that wants to know
    ## what to show asks for the whole row, because the four facts travel
    ## together: a mode that shows the working tree is also the mode that may
    ## mutate it, and a front-end that read only the first would build a
    ## read-only editor.
    origin*: SourceOrigin
      ## Which copy of the file this mode's Source pane shows.
    mutable*: bool
      ## Whether the user may change it.
    windowed*: bool
      ## Whether `SourceVM`'s windowed, virtualised, read-only model serves it.
      ## §2.1: *"Edit mode does not use `SourceVM`."*
    statement*: string
      ## What the pane must say it is showing. §2's Requirement: *"The Source
      ## pane states which mode's source it is showing, **always** — not only
      ## when they differ, because 'only when it matters' requires the user to
      ## know when it matters."*
      ##
      ## Non-empty for every mode, by construction and by assertion.

  StaleTraceVerdict* = enum
    ## Whether a recording still describes the files the user is editing.
    ##
    ## §2.1 consequence 3: *"An edit made after a recording makes that
    ## recording's line numbers stale. … A user who edits and then toggles back
    ## to a stale trace must be told, once, plainly."*
    stvNoTrace = "no-trace"
      ## There is no recording to be stale. Distinct from `stvFresh` because
      ## "nothing to compare" and "compared and agreed" are different answers
      ## and only the second is a statement about the user's files.
    stvFresh = "fresh"
    stvStale = "stale"

  StaleTraceAssessment* = object
    ## The verdict plus the evidence for it. The evidence is carried because
    ## the notice names the files, and a notice that said only "your trace is
    ## stale" would leave the user to guess which edit caused it.
    verdict*: StaleTraceVerdict
    editedPaths*: seq[string]
      ## The recorded paths this session edited after the trace was made, in
      ## the order they were edited.

  ModeSwitch* = object
    ## What one `Ctrl+F5` did.
    ##
    ## REPORTED RATHER THAN INFERRED FROM A STATE DIFF, on the same rule
    ## `modal_state.ModalTransition` is built on: "switched to Debug and the
    ## trace is stale" and "switched to Debug" are different events, and only
    ## one of them puts a line on the user's screen.
    changed*: bool
      ## False for the idempotent switch. §6: *"Switching to the mode the
      ## session is already in changes nothing."*
    fromMode*, toMode*: ProductMode
    notice*: string
      ## What the user is TOLD, or "" for nothing to say. The stale-trace
      ## sentence is the only thing that fills it today.
    staleness*: StaleTraceAssessment

  PreservedConcern* = enum
    ## `Mode-Transitions.md` §5's preservation table, one member per row, and
    ## **the string values are the slugs that document's own rows normalise
    ## to**.
    ##
    ## That is what makes the document the oracle rather than a thing this enum
    ## was written from: `slugOfPreservedRow` below normalises a table cell,
    ## the suite parses §5 at run time and compares the resulting set against
    ## this enum, and a row added, removed or renamed in the specification
    ## reddens the suite without anybody editing a test.
    pcOpenTabs = "the-set-of-open-editor-tabs"
    pcUnsavedBuffers = "unsaved-buffer-contents"
    pcCaretAndSelection = "caret-position-and-selection"
    pcScrollPosition = "scroll-position"
    pcFoldState = "fold-state"
    pcBreakpoints = "breakpoints"

const
  ProductModeCount* = 2
    ## A LITERAL, deliberately, and the same argument
    ## `test_layout_profiles.nim` makes about `UiMode`'s `6`: a `len(...)`
    ## computed from the enum a sweep walks cannot notice that the sweep
    ## skipped a member. §1.2's fifteen-state failure is a cardinality failure,
    ## so the cardinality is what is pinned.

# ---------------------------------------------------------------------------
# The partition, DERIVED rather than mirrored
# ---------------------------------------------------------------------------

proc productModeOf*(mode: ToolbarMode): ProductMode =
  ## Which product mode a `LayoutMode` is.
  ##
  ## `edit_mode_toolbar.isEditing` is the partition and this is its two names.
  ## Nothing here re-lists the layout modes, so a sixth one added to
  ## `common/`'s enum arrives with an answer already.
  if mode.isEditing: pmEdit else: pmDebug

proc canonicalLayoutMode*(mode: ProductMode): ToolbarMode =
  ## The `LayoutMode` a front-end with no finer opinion should use for `mode`.
  ##
  ## `QuickEditMode` and `InteractiveEditMode` are also Edit; this names the
  ## one a plain toggle produces, which is what a terminal has.
  case mode
  of pmDebug: DebugMode
  of pmEdit: EditMode

static:
  # THE PARTITION IS TOTAL AND BOTH SIDES ARE INHABITED.
  #
  # Totality is free from the `bool`; what is not free is that neither answer
  # is vacuous. A `productModeOf` that answered `pmDebug` for everything would
  # satisfy every type in this module and would make Edit mode unreachable —
  # and it would do so silently, which is why this is a build failure rather
  # than a test.
  var sawDebug = false
  var sawEdit = false
  for m in ToolbarMode:
    case productModeOf(m)
    of pmDebug: sawDebug = true
    of pmEdit: sawEdit = true
  doAssert sawDebug, "no LayoutMode maps onto pmDebug"
  doAssert sawEdit, "no LayoutMode maps onto pmEdit"
  # And the round trip agrees with the partition it came from.
  for p in ProductMode:
    doAssert productModeOf(canonicalLayoutMode(p)) == p,
      "canonicalLayoutMode(" & $p & ") is not in " & $p
  # The cardinality the risk mitigation pins, checked where it is declared as
  # well as where it is swept.
  doAssert ord(high(ProductMode)) - ord(low(ProductMode)) + 1 ==
    ProductModeCount, "ProductModeCount has drifted from ProductMode"

# ---------------------------------------------------------------------------
# §2 — which source a mode shows
# ---------------------------------------------------------------------------

proc sourceContractFor*(mode: ProductMode): ModeSourceContract =
  ## §2's table, verbatim, as the one place any front-end reads it.
  ##
  ## | | Debug mode | Edit mode |
  ## |---|---|---|
  ## | Shows | the **recording's** source | the **working tree** |
  ## | Mutable | no | yes |
  ## | Model | `SourceVM` — windowed, virtualized, read-only | a text buffer |
  ##
  ## The `statement` strings are what a pane prints. They name the SOURCE, not
  ## the mode, because the mode is already on the status line and repeating it
  ## in the pane would tell the user something they can see rather than the
  ## thing they cannot.
  case mode
  of pmDebug:
    ModeSourceContract(origin: soTracePayload, mutable: false, windowed: true,
                       statement: "the recording's source")
  of pmEdit:
    ModeSourceContract(origin: soWorkingTree, mutable: true, windowed: false,
                       statement: "the working tree")

proc sourceOriginFor*(mode: ProductMode): SourceOrigin =
  ## Which copy of a file `mode` shows. The headline answer, on its own, for
  ## the callers that want only it.
  sourceContractFor(mode).origin

proc sourceStatementFor*(mode: ProductMode): string =
  ## §2's Requirement: what the Source pane says, in every mode, always.
  sourceContractFor(mode).statement

proc usesSourceVM*(mode: ProductMode): bool =
  ## §2.1 consequence 1, as a predicate a binding can branch on: *"Edit mode
  ## does not use `SourceVM`. … Reusing `SourceVM` would mean adding mutation
  ## to the type whose entire purpose is to serve a revision faithfully."*
  sourceContractFor(mode).windowed

proc isMutable*(mode: ProductMode): bool =
  sourceContractFor(mode).mutable

proc displayedSourceMayDiffer*(a, b: ProductMode): bool =
  ## §2.1 consequence 2: *"A mode switch may change what the Source pane
  ## displays, for the same path."*
  ##
  ## True exactly when the two modes read different origins — which is every
  ## real switch and no idempotent one. A front-end uses this to decide whether
  ## a switch is one the user has to be told about at all.
  sourceOriginFor(a) != sourceOriginFor(b)

# ---------------------------------------------------------------------------
# §2.1 consequence 3 — the stale trace, and what the user is told
# ---------------------------------------------------------------------------

proc assessTrace*(hasTrace: bool; editedPaths: openArray[string]):
    StaleTraceAssessment =
  ## Whether the recording still describes the files on disk.
  ##
  ## The input is the set of paths this session EDITED, not a timestamp
  ## comparison: a mtime says a file was written and says nothing about whether
  ## the bytes changed, and a session that saved a buffer unchanged would
  ## announce a staleness the user did not cause. The caller (`tui/app/
  ## edit_session.nim`) records a path when a buffer's text actually differs
  ## from what was loaded.
  result.editedPaths = @[]
  for p in editedPaths:
    if p.len > 0 and p notin result.editedPaths:
      result.editedPaths.add p
  result.verdict =
    if not hasTrace: stvNoTrace
    elif result.editedPaths.len == 0: stvFresh
    else: stvStale

proc staleTraceNotice*(assessment: StaleTraceAssessment): string =
  ## The sentence a user sees, once, when they toggle onto a recording their
  ## own edits have outrun.
  ##
  ## IT NAMES THE FILES. §2.1 says "told, once, plainly", and a notice that
  ## said only "this trace is stale" would leave the user to work out which of
  ## their edits caused it — which is the same "the user must know when it
  ## matters" failure §2's Requirement rejects one paragraph earlier.
  ##
  ## It also says what to do about it, because Mode-Transitions.md §1 is what
  ## makes the remedy non-obvious: the toggle onto an existing trace does NOT
  ## re-record, and only *Run* does.
  if assessment.verdict != stvStale:
    return ""
  let n = assessment.editedPaths.len
  var named = assessment.editedPaths
  var suffix = ""
  if named.len > 3:
    named = named[0 ..< 3]
    suffix = ", …"
  "This recording predates your edits to " & $n &
    (if n == 1: " file (" else: " files (") & named.join(", ") & suffix &
    "); its line numbers are the recorded ones. Use :run to re-record."

# ---------------------------------------------------------------------------
# The switch
# ---------------------------------------------------------------------------

proc switchProductMode*(current: ProductMode; target: ProductMode;
                        hasTrace: bool;
                        editedPaths: openArray[string]): ModeSwitch =
  ## One `Ctrl+F5`.
  ##
  ## `changed` is false for the idempotent case and the notice is empty there,
  ## which is Mode-Transitions.md §6's *"Switching to the mode the session is
  ## already in changes nothing"* — including changing what is on the status
  ## line. A switch that announced staleness every time it was pressed would
  ## teach the user to ignore the one that mattered, which is §4c obligation 3
  ## arriving through a different door.
  result.fromMode = current
  result.toMode = target
  result.changed = current != target
  result.staleness = assessTrace(hasTrace, editedPaths)
  result.notice =
    if result.changed and target == pmDebug:
      staleTraceNotice(result.staleness)
    else:
      ""

proc toggled*(mode: ProductMode): ProductMode =
  ## `Ctrl+F5` is ONE command in both directions
  ## (`Mode-Transitions.md` §1), so this is the whole of what it decides.
  case mode
  of pmDebug: pmEdit
  of pmEdit: pmDebug

# ---------------------------------------------------------------------------
# §5 — what a transition preserves, and how the document is read
# ---------------------------------------------------------------------------

proc slugOfPreservedRow*(cell: string): string =
  ## Normalise one cell of `Mode-Transitions.md` §5's first column into the
  ## slug `PreservedConcern` spells.
  ##
  ## Lives HERE rather than in the suite for one reason: a normaliser written
  ## inside the test is a normaliser written to make that test pass, and the
  ## next person to change either side has two readings of the document to
  ## reconcile. This one is exported, is the only one, and the suite's failure
  ## message prints what it produced.
  ##
  ## The rule: drop Markdown emphasis, keep the part before the first comma
  ## (row 1's clause "their order, and which is active" elaborates the subject
  ## rather than naming a second one), lowercase, and reduce every run of
  ## non-alphanumerics to a single `-`.
  var text = cell.replace("**", "").strip()
  let comma = text.find(',')
  if comma >= 0:
    text = text[0 ..< comma]
  var slug = ""
  var pendingDash = false
  for ch in text.toLowerAscii:
    if ch in {'a' .. 'z', '0' .. '9'}:
      if pendingDash and slug.len > 0:
        slug.add '-'
      pendingDash = false
      slug.add ch
    else:
      pendingDash = true
  slug

proc preservedConcernSlugs*(): seq[string] =
  ## Every slug this build claims to preserve, in declaration order. The suite
  ## compares this against what it parsed out of the document.
  result = @[]
  for c in PreservedConcern:
    result.add $c
