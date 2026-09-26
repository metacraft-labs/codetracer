## flow_line_rule.nim — THE PER-LINE FLOW RULE, with no rendering in it.
##
## Moved here on 2026-09-23 (PLAT-42) from `frontend/ui/flow_line_styles.nim`,
## which keeps the CSS class names and re-exports this module. The move is what
## lets the ViewModel layer (`viewmodel/viewmodels/flow_vm.nim`, the source of
## `FlowVM.styledLines`) call THE SAME rule without the Embed SDK facade
## reaching a module of the desktop UI tree — `ci/test/sdk-facade-boundary.sh`
## refuses any rendering, CSS or component module in the facade's graph, and
## `flow_line_styles.nim` exports CSS class names. One rule, two importers.
##
## Everything below is unchanged from its old home, including the history that
## explains it.
##
## (Formerly the header of `ui/flow_line_styles.nim`.) Pure per-line rules for
## the Omniscience flow overlay.
##
## Like `ui/flow_loop_math.nim`, `ui/trace_redraw_policy.nim` and
## `ui/editor_decoration_layers.nim`, this module deliberately has **no
## imports**: `ui/editor.nim` is JS-only (karax plus the Monaco bindings), so
## the decision that turns a loaded flow window into one inline CSS class per
## source line could not be unit-tested at all while it lived inline in
## `flowStyleLines`. Everything here compiles on the C backend, so
## `src/tests/gui/tests/editor/flow_line_styles_test.nim` exercises it
## headlessly on both the native and the JS lane.
##
## Why it was extracted (RV-5)
## ---------------------------
## `flowStyleLines` read
##
##     flow.flow.branchesTaken[0][0].table.hasKey(position)
##
## with no bounds and no nil check. `FlowViewUpdate.branchesTaken` is a
## `seq[seq[BranchesTaken]]`, and the backend's own constructor
## (`FlowViewUpdate::new` in `src/db-backend/src/task.rs`) is the only thing
## that guarantees it starts life as `vec![vec![BranchesTaken::default()]]`.
## Any `FlowViewUpdate` that did *not* come from that constructor — a hand-built
## one, a partially decoded one, or the review-dataset adapter this milestone
## adds — makes that expression an out-of-bounds access rather than a no-op, and
## the resulting `IndexDefect` aborts `applyEventualStylesLines` before any
## decoration is applied. `conditionStyleLines` in the same file already checked
## all three conditions; this one did not. The guard now lives in
## `hasBranchStateAt` and is shared by both readings of the same data.
##
## Genericity
## ----------
## The procs are generic over the flow value rather than typed against
## `FlowViewUpdate` because that type is declared in an *included* module
## (`common/common_types/codetracer_features/flow.nim`) and therefore exists
## twice with incompatible field types — once through `common/types.nim`
## (`langstring = string`, `TableLike = Table`) and once through
## `frontend/types.nim` (`langstring = cstring`, `TableLike = JsAssoc`). A
## module naming either copy would only be usable from one of the two worlds.
## Instantiating one generic proc over both is what makes the renderer and the
## headless tests run *the same* code — the same reasoning `review_entry.
## reviewDatasetFrom` records.

type
  FlowLineStyleKind* = enum ## Which inline flow class a source line earns.
    flskHit      ## the line was executed in this flow window
    flskSkip     ## the window is finished and the line was never reached
    flskUnknown  ## the window is still loading, so nothing is known yet

  FlowStyledLine* = object
    ## One line of the displayed function and the class it earns.
    position*: int
    kind*: FlowLineStyleKind

proc hasBranchStateAt*[B](branchesTaken: openArray[B]; position: int): bool =
  ## Does the *outer* branch table — `branchesTaken[0][0]`, the one holding the
  ## conditions that are not inside any loop — record a state for `position`?
  ##
  ## False whenever the answer cannot be looked up: an empty outer seq, an
  ## empty inner seq, or a nil table. Those are the three ways the unguarded
  ## `[0][0].table` raised instead of answering. Reporting "no state recorded"
  ## for them is the correct reading, not a papering-over: a flow window that
  ## carries no branch information has no branch to exclude from the per-line
  ## styling, which is exactly what an absent key means.
  if branchesTaken.len == 0:
    return false
  if branchesTaken[0].len == 0:
    return false
  let table = branchesTaken[0][0].table
  # `JsAssoc` is nilable, `Table` is not; `when compiles` picks the check that
  # exists in the world this instantiation is compiled for.
  when compiles(table.isNil):
    if table.isNil:
      return false
  table.hasKey(position)

proc branchStateAnywhere*[B, S](branchesTaken: openArray[B]; header: int;
                                state: S): bool =
  ## Does ANY cell of the payload record `state` for the arm at `header`?
  ##
  ## The state is a PARAMETER rather than the name `Taken` spelled here, and
  ## that is forced rather than stylistic: this module names no types (see the
  ## Genericity note above), so a branch state can only reach it through
  ## `mixin` — and a `mixin` binds where the proc that DECLARES it is
  ## instantiated, which for a generic called from another generic is this
  ## file, not the renderer. `nim js src/frontend/ui_js.nim` says so directly:
  ## *"template/generic instantiation of `branchStateAnywhere` from here …
  ## Error: undeclared identifier: 'Taken'"*. `insideUntakenBranch` has the
  ## value in scope through its own `mixin`, so it passes it in.
  ##
  ## `S` is generic for the same reason the module is generic over `B`: the
  ## state is `BranchState` for the two `FlowViewUpdate` worlds and a bare
  ## ordinal `int` for `viewmodel/viewmodels/flow_vm.nim`'s `FlowLineWindow`,
  ## whose constants `test_flow_line_facts.nim` pins against the enum.
  ##
  ## `Omniscience-Flow.md` § *Dimming means "the run did not take this branch"*:
  ## "**Dimming does not depend on the loop iteration on display.** A line in a
  ## loop body is not dimmed because the reader is looking at an iteration other
  ## than the one it ran in. It ran."
  ##
  ## An arm's state is per (loop, iteration), but DIMMING is per window — one
  ## verdict for the whole overlay — so the question the dimming rule has to ask
  ## is "did this arm ever run", and that ranges over every cell, not over
  ## `[0][0]` alone.
  ##
  ## It is also what makes the rule safe when two cells of one payload
  ## disagree. They can: `expr_loader.final_branch_load` sweeps the file and
  ## stamps `NotTaken` into `[0][0]` for arms it believes the walk never
  ## reached, and until `observed_branch_lines` existed its check list was
  ## `[0][0]` alone, so an arm entered on every pass of a LOOP was swept anyway.
  ## Measured on a two-pass Rust loop whose `else` arm ran both times:
  ## `branchesTaken[0][0] = [(5,NotTaken),(7,NotTaken)]` beside
  ## `[1][0] = [(5,NotTaken),(7,Taken)]` — line 7's arm both ran and, said the
  ## outer table, did not (`src/db-backend/tests/flow_branch_state_test.rs`).
  ## That disagreement is issue #758's second complaint: "even when a branch
  ## DOES show green (taken), the code inside is still grayed out".
  ##
  ## `Taken` outranks `NotTaken` here because they are not two opinions of equal
  ## standing. `Taken` is written from an OBSERVATION — the walker stepped into
  ## the arm — and the sweep's `NotTaken` is inferred from an ABSENCE. When a
  ## proof and an inference-from-silence disagree, the silence was wrong.
  for iterations in branchesTaken:
    for cell in iterations:
      let table = cell.table
      when compiles(table.isNil):
        if table.isNil:
          continue
      if table.hasKey(header) and table[header] == state:
        return true
  false

proc insideUntakenBranch*[B](branchesTaken: openArray[B]; position: int): bool =
  ## Does `position` fall inside the interior of an arm the run DECLINED?
  ##
  ## This is the whole of the dimming rule
  ## (`GUI/Debugging-Features/Omniscience-Flow.md` § *Dimming means "the run did
  ## not take this branch"*):
  ##
  ##   > A source line is dimmed when, and only when, it belongs to a branch of
  ##   > a conditional — `if`, `else`, `else if`, `switch`/`case`, `match` arm —
  ##   > that the recorded run did not enter. Not having executed is not, by
  ##   > itself, a reason to dim a line.
  ##
  ## The two tables are joined by header line: `table` says what the run did
  ## with the arm that header introduces, `extents` says which lines that arm
  ## occupies. A header with a state and no extent contributes NOTHING — the
  ## state is known, the arm's lines are not, and inventing a span would turn
  ## "nothing is claimed" into a claim.
  ##
  ## `NotTaken` is a `mixin` because this module names no types: `BranchState`
  ## lives in an *included* module and therefore exists twice with incompatible
  ## field types, once through `common/types.nim` and once through
  ## `frontend/types.nim`. Naming either copy would make this module usable from
  ## only one of the two worlds — the same reason `hasKey` and `isNil` are left
  ## to instantiation above, and the reason the headless tests can run the very
  ## code the renderer runs.
  mixin NotTaken
  mixin Taken
  if branchesTaken.len == 0:
    return false
  if branchesTaken[0].len == 0:
    return false
  let states = branchesTaken[0][0].table
  let extents = branchesTaken[0][0].extents
  when compiles(states.isNil):
    if states.isNil:
      return false
  when compiles(extents.isNil):
    # A window built by hand rather than by `FlowViewUpdate::new` — the
    # review-dataset adapter builds one — has no extents at all. No arm can be
    # shown to have been declined, so nothing is dimmed.
    if extents.isNil:
      return false
  for header, state in states:
    if state != NotTaken:
      continue
    # ORDER MATTERS HERE, and only for cost — the three tests below are an
    # independent conjunction, so any order answers the same question.
    #
    # `branchStateAnywhere` scans EVERY cell of `branchesTaken`, and the cells
    # grow one per loop iteration (bounded only by `STEP_COUNT_LIMIT`). This
    # proc runs once per source line of the rendered window, and the loop it
    # sits in runs once per recorded header. Put the scan first and a long
    # loop costs lines x headers x iterations on every repaint, in the JS
    # renderer, for a question the two cheap tests usually settle: a header
    # whose arm does not even contain this line can never dim it, whatever any
    # other cell says about it.
    #
    # So: the hash lookup and the range compare first, both O(1), then the
    # scan — reached only for a header that would otherwise dim this very
    # line.
    if not extents.hasKey(header):
      continue
    let extent = extents[header]
    if position < extent.firstLine or position > extent.lastLine:
      continue
    # An arm this window recorded as ENTERED anywhere is an arm that ran, and
    # no claim to the contrary in another cell may dim its interior. See
    # `branchStateAnywhere` for which claim loses and why.
    if branchStateAnywhere(branchesTaken, header, Taken):
      continue
    return true
  false

proc flowStyledLines*[F](flow: F; finished: bool): seq[FlowStyledLine] =
  ## Every line of the function `flow` describes that EARNS a class, with the
  ## class it earns.
  ##
  ## ## What changed, and why the old rule was wrong
  ##
  ## This used to be `position in relevantStepCount ? hit : (finished ? skip :
  ## unknown)`, and both non-hit outcomes render at `opacity: 0.5`
  ## (`styles/components/flow.styl`), so the effective rule was **"dim every
  ## line this window has no step for"**. Reported as: *"I jump into a function
  ## and all of its lines before the current line get dimmed."*
  ##
  ## Dimming is a claim about the PROGRAM; "the flow window has no step for this
  ## line" is a claim about the WINDOW. The second moves with the cursor, with
  ## the loop iteration on the slider, and with how far a bounded walk got —
  ## `relevantStepCount` is not even the backend's answer by the time it is read
  ## here, because `ui/flow.nim` clears it and rebuilds it down to the displayed
  ## loop iteration. Rendering the second as the first tells the reader
  ## something false in exactly the case that matters: a line that already
  ## executed, above the current position, dimmed as though it never ran.
  ##
  ## Three lines that ran and were dimmed by the old rule, all now correct: a
  ## loop body while the reader looks at a different iteration; every line of a
  ## loop whose slider widget does not exist yet; and a line carrying no step of
  ## its OWN — a closing brace, a declaration, or the continuation line of a
  ## multi-line statement, which is the case in the failing report.
  ##
  ## ## Two states, not three
  ##
  ## A line is dimmed because a branch was not taken, or it is left alone.
  ## `flskUnknown` is no longer produced: it existed to avoid over-claiming
  ## while a window loaded, and it rendered identically to `flskSkip`, so the
  ## downgrade was real in the data and invisible on screen. Under the new rule
  ## there is nothing to downgrade — a window with no branch information dims
  ## nothing. `finished` is therefore no longer consulted, which is just as well:
  ## it is never `true` in live replay at all (`FlowUpdate::new` sets it
  ## `false` and only `FlowUpdate::error` sets it `true`), so the safeguard it
  ## gated had been inert since it was written.
  ##
  ## ## Excluded
  ##
  ##   * lines the outer branch table has a state for — the arm HEADERS. Those
  ##     are painted by `conditionStyleLines`' `flow-taken` / `flow-not-taken`
  ##     pass, and painting both would fight over the same line. This is also
  ##     what keeps the header of a declined arm undimmed, which the spec
  ##     requires by name: the condition line is the line whose test was
  ##     evaluated, so it ran.
  ##   * comment lines, which are not executable.
  ##   * lines about which nothing is claimed — emitted as no entry at all
  ##     rather than as a third kind, because "undimmed" is the absence of a
  ##     statement, not a statement of absence.
  ##
  ## A nil flow, or one whose location spans no lines, yields an empty seq
  ## rather than raising.
  result = @[]
  when compiles(flow.isNil):
    if flow.isNil:
      return
  let first = flow.location.functionFirst + 1
  let last = flow.location.functionLast
  for position in first .. last:
    if hasBranchStateAt(flow.branchesTaken, position):
      continue
    if position in flow.commentLines:
      continue
    if insideUntakenBranch(flow.branchesTaken, position):
      result.add(FlowStyledLine(position: position, kind: flskSkip))
    elif position in flow.relevantStepCount:
      result.add(FlowStyledLine(position: position, kind: flskHit))
