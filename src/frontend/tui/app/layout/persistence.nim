## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/layout/persistence.nim — PLAT-6. **Where a terminal's rearranged layout
## lives, and what happens when the document there cannot be read.**
##
## ## Nothing here does I/O of any kind
##
## No `getEnv`, no file, no fd — the same statement `app/theme/capabilities.nim`
## makes about itself, and for the same reason. That module is the shape this
## one copies: `host/capabilities.nim` performs the seven `getEnv`s and hands a
## `TerminalEnv` VALUE to `app/theme/capabilities.resolveCapabilities`, which
## decides what it means. Here, `host/layout_store.nim` performs the read, the
## write and the remove (`readFile`, `moveFile`, `removeFile` — none of which
## this module may name in code, and `std/os`, where they live, is not in its
## import list), and this module decides
##
##   * **what the document is called** — `LayoutDocumentFileName`, one name
##     for the terminal product (PLAT-45);
##   * **what an unreadable one means** — `adoptLayoutDocument`, which returns a
##     typed `LayoutRestoreReport` and never a silent fallback;
##   * **whether there is anything to write at all** — `layoutPersistPlan`.
##
## Splitting it that way is what makes the interesting half assertable with no
## filesystem: every arm below is a value in and a value out.
##
## ## WHERE THE DOCUMENT LIVES, AND WHAT IT IS KEYED BY
##
## **Under the user's own state directory, ONE file for the terminal product.**
## `host/layout_store.layoutDocumentPath` composes
## `<state root>/<LayoutDocumentFileName>`.
##
## Three decisions are packed into that sentence, and each had a plausible
## alternative:
##
##   1. **NOT INSIDE THE TRACE FOLDER.** A recording is an artefact that gets
##      copied, archived and shared — `ct host` serves one to a browser and
##      `src/ct/online_sharing/` uploads one — and it may sit on a read-only
##      mount. A pane arrangement is one user's preference about one terminal,
##      and writing it into the recording would put a preference inside a
##      shared artefact.
##   2. **STATE, NOT CONFIG.** `$XDG_STATE_HOME/codetracer` rather than
##      `$XDG_CONFIG_HOME/codetracer`, because this is something the program
##      writes for itself and not something a user edits — the same call
##      `src/ct_test/run_store.defaultRunStoreRoot` already makes in this
##      repository, and the XDG basedir spec's own distinction.
##   3. **ONE DOCUMENT PER PRODUCT, NOT PER RECORDING (PLAT-45).** PLAT-6 keyed
##      the document by the recording, on the argument that the three
##      responsive profiles showed DIFFERENT PANE SETS, so an arrangement made
##      against one recording's panes would silently misapply to another.
##      PLAT-45 removed the premise: every product opens with the same panes
##      (the shared default, folded only when a terminal is too small), so an
##      arrangement is a preference about the TERMINAL, and the user's intent
##      is stated plainly — each product remembers ITS OWN last layout and
##      restores it on the next start. The desktop keeps its GoldenLayout
##      config under `$XDG_CONFIG_HOME/codetracer/`, the GPUI window its own
##      file beside this one (`gpui-layout.json`), and none of the three reads
##      another's: a layout arranged in the terminal does not change the
##      desktop's next start.
##
## ## AN UNREADABLE DOCUMENT IS A REPORT, NEVER A SILENT DEFAULT
##
## `layout_model.PaneKind`'s design note is explicit that an unrepresentable
## state must be a typed, reportable error and never a silently blank region.
## A restore that quietly fell back to the profile default after failing to
## read a document is that same failure wearing different clothes: the user
## asked for their arrangement, did not get it, and was told nothing. So
## `adoptLayoutDocument` answers `lrsUnreadable` with a message that names the
## KIND — `UnknownVersion`, `UnknownPane`, `NotJson` — and `main.nim` puts that
## message on the status line and keeps it there past the "opened" message that
## would otherwise overwrite it.
##
## **AND THE DOCUMENT IS LEFT ALONE.** `layoutPersistPlan` answers
## `lpiQuarantine` for a session that started from an unreadable document, so
## exiting does not overwrite it. That matters most in the case the schema
## chain is built for: a document written by a NEWER build is `UnknownVersion`
## here, and a build that answered by overwriting it would destroy the user's
## arrangement simply because they opened an older binary once.
##
## ### `UnreadableFile` IS THE ARM WHERE "LEFT ALONE" IS NOT AUTOMATIC
##
## The sentence above is one guarantee with two implementations, and only one
## of them is inside this module. `adoptLayoutDocument` sets the session's
## quarantine flag for every failure it can see — `NotJson`, `EmptyDocument`,
## `UnknownVersion`, `UnknownPane` — because the bytes reached it. **The fifth
## failure never reaches it**: a file that would not OPEN at all, which
## `host/layout_store.restoreLayoutForSession` meets on its `readFile` and
## reports through `unreadableLayoutDocument` above. On that one path the flag
## is set by a SEPARATE call, `runtime.markLayoutDocumentUnreadable`, and
## nothing else in the product sets it.
##
## Delete that call and the difference is not a worse message — it is the
## user's file. Measured, on a real document with its permissions removed:
##
## ```
##   restore -> unreadable kind='UnreadableFile'   (the user is still told)
##   quarantined=false  ->  plan intent=remove  ->  persist -> removed
##   0 files left — the document is DELETED
## ```
##
## So a **transient `EACCES` costs a user their arrangement permanently**,
## while the report they see says the file was left alone. The report and the
## quarantine are two facts and only the first of them is composed here.
##
## `tests/test_layout_persistence.nim`'s case *"a document that will not OPEN
## is quarantined and survives byte-identical"* is the measurement — it removes
## the permissions from a real file rather than injecting a failure, and it
## asserts the FILE (still present, byte-identical) rather than the report,
## because the report survives the defect. `M45` in
## `app/tests/run-plat6-mutations.py` is the arm, with `S18` as its control.
##
## ## `revealed` IS NOT PERSISTED, AND THAT IS INHERITED RATHER THAN RESTATED
##
## Layout-ViewModel §3.2 says a revealed dock overlay is interaction state.
## `layout_model.toJson(DockedPane)` does not write the field and
## `binding.restoreDocument` resets `interaction` to `noInteraction()`, so a
## restore cannot reopen an overlay — a decoder cannot resurrect what an
## encoder never wrote. Nothing here adds a second rule; the Tier-1 and Tier-2
## suites assert the property through this path rather than through `toJson`.
##
## ## THE PROFILE FREEZE: A RESTORED DOCUMENT IS A USER MODIFICATION
##
## PLAT-6 decided that a user modification freezes the responsive profile —
## `binding.resize` re-selects the profile but rebuilds the tree only while
## `userModified` is false. **A restored document sets it**, and that is a
## decision rather than an accident of `restoreDocument`'s implementation:
##
##   * the arrangement in the document IS the user's, made in a previous
##     session, and §8.4's whole argument — "a reflow that silently reset what
##     the user chose is indistinguishable from a bug" — does not weaken
##     overnight;
##   * `:reset-layout` remains the explicit way back, and it clears
##     `userModified`, which is what makes the round trip complete: after a
##     reset, `layoutPersistPlan` answers `lpiRemove` and the exit DELETES the
##     document rather than leaving a stale one to be restored next time.
##
## The same flag is why **an untouched session writes nothing**. Persisting a
## profile default would freeze the profile on the next launch, so opening a
## recording once in an 80x24 terminal would pin the Compact tree on a 200x60
## one for ever, without the user having touched anything. No gesture, no
## document.
##
## ## THE DECISION, ENUMERATED — AND WHY A TABLE RATHER THAN MORE CASES
##
## Everything above is a REASON. This section is the decision itself, because
## three separate verification passes each found a different **unmeasured
## combination** in it, and every one of them destroys a user's file:
##
##   1. neuter `runtime.markLayoutDocumentUnreadable` and a transient `EACCES`
##      DELETES the document — the section above, arm `M45`;
##   2. delete `rt.rebuildFocus()` from the mouse path and the focus ring goes
##      on offering a pane a drop has docked away — arm `M37`;
##   3. weaken the quarantine branch below so it fires only when the session
##      also left the arrangement alone, and a session that could not read its
##      document and **then moved a pane** writes over it. Open a recording
##      with an older build (its document is `version: 99`), rearrange, quit —
##      and a `version: 2` document is on disk where the user's newer one was.
##      Permanent loss, not a session's; arms `M46` and `M47`.
##
## Each was found by somebody hand-picking one more arm, and the third is the
## proof that this does not scale: the failure arms had a case, the persist
## plan had a case, and the COMBINATION of the two had nobody. So the decision
## is now enumerated rather than sampled.
## `tests/test_layout_persistence_matrix.nim` holds the table as DATA, asserts
## its own cardinality and completeness, and asserts every cell **at the FILE**
## — because in all three findings the report was unchanged while the file
## moved. Under (1) the message the user still sees says *"the file was left
## alone"* about a file the program has just removed.
##
## ### THE FREE INPUTS ARE THREE, NOT FIVE
##
## `userModified` and `quarantined` read like inputs and are not. A restore
## sets the first (`binding.restoreDocument`) and `:reset-layout` clears it;
## `bindLayoutDocument` clears the second, `runtime.adoptLayoutDocument` sets
## it from the restore status, and `markLayoutDocumentUnreadable` sets it on
## the one path the decoder never sees. Both are OUTPUTS of three things a
## session is actually handed:
##
##   * **how the session is wired** — no binding; a binding with no document
##     named; or bound. The middle one is the dimension a summary drops, and it
##     is a real one: `runtime.layoutPersistenceEnabled` needs BOTH halves, so
##     a host may enable the binding and never name a document — the
##     "rearrangeable session that forgets";
##   * **what is at the document's path** — absent, this build's version, an
##     older version, or unreadable for one of five reasons: the bytes, an
##     empty file, the schema, the pane vocabulary, or the open itself;
##   * **what the user did** — nothing, `:reset-layout`, a rearrangement, or a
##     rearrangement they then reset.
##
## ### THE TABLE, FOR A BOUND SESSION
##
## | on disk | untouched | `:reset-layout` | rearranged | rearranged, then reset |
## | --- | --- | --- | --- | --- |
## | absent | remove (nothing to remove) | remove | **WRITE a new one** | remove |
## | this build's version | **REWRITE it** | **DELETE it** | **REWRITE it** | **DELETE it** |
## | an older version | **REWRITE it, migrated forward** | **DELETE it** | **REWRITE it** | **DELETE it** |
## | unreadable, any of the five | leave alone | leave alone | **leave alone** | leave alone |
##
## Two rows repay reading twice:
##
##   * **A RESTORE IS A USER MODIFICATION**, so the *untouched* column REWRITES
##     rather than leaving alone — and on the *older version* row that rewrite
##     is the v1 → v2 migration reaching the disk: a document REPLACED with no
##     gesture at all. It is intended (`layout_model` §6 has no backward
##     migration), and it is written down here because a replacement nobody
##     wrote down is how the next finding starts.
##   * **THE BOTTOM ROW IS THE PRECEDENCE, AND IT HAS TWO SIDES.** Its third
##     cell is where finding (3) lives: `quarantined` and `userModified` are
##     both true and the two branches below disagree, so weakening the first
##     one WRITES over the user's document. Its other three cells are what a
##     REORDERING breaks the opposite way: test the modification first and an
##     unreadable document is DELETED rather than left. One cell establishes
##     the rule for one half of the disagreement, which is exactly how the
##     weakening survived a 66-arm harness.
##
## With no binding, or with a binding and no document named, all 32 of the
## remaining cells answer `disabled` and nothing on disk moves — including for
## the document states that would make a bound session quarantine or write.
##
## The suite carries three smaller tables beside it: `layoutPersistPlan`'s own
## six cells, two of which no session can present because
## `runtime.layoutPersistPlanOf` returns first — asserted against that guard
## rather than claimed; the thirteen values `LayoutRestoreReport.kind` can
## take, of which eleven are produced and two (`Refused`,
## `DockedPanesUnsupported`) are unreachable, each with its reason and a
## measurement that it cannot be constructed; and the two arms that answer
## `lpoFailed`.
##
## **`lpoFailed` IS A TABLE OF ITS OWN, NOT A COLUMN OF THE CROSS.** No cell
## above reaches it, and that is a property of the cross rather than a gap in
## it: a failure arm is reached by OBSTRUCTING THE FILESYSTEM, which is a
## fourth thing to do to the world and not a fourth thing to do in a session,
## so adding it as a value of a session dimension would have meant 96 cells
## carrying an obstruction that 94 of them ignore. `FailureTable` enumerates
## the two arms instead — a directory at `<path>.new` for the write, a state
## directory with no write permission for the remove — and both are reached on
## an ordinary `createTempDir()`. An earlier version of this paragraph said
## they could not be, which was false and was the shape this file exists to
## refuse: a claim about the population, inside the instrument whose value is
## its claim to be exhaustive.

import std/[json, options, strutils]

import ./binding

export binding

type
  LayoutRestoreStatus* = enum
    ## What reading this session's saved arrangement produced.
    lrsNoDocument = "no-document"
      ## The terminal has nothing saved. The ordinary first run, and NOT a
      ## failure: the session opens on the shared default and says nothing,
      ## because there is nothing to say.
    lrsRestored = "restored"
    lrsUnreadable = "unreadable"
      ## A document is there and this build cannot read it — corrupt bytes, a
      ## pane this build does not have, or a schema version from a newer one.
      ## The session opens on the profile's default AND THE USER IS TOLD, and
      ## the document is not overwritten on the way out.

  LayoutRestoreReport* = object
    ## The answer, as a value the host puts on the status line.
    status*: LayoutRestoreStatus
    path*: string
    message*: string
      ## Empty for `lrsNoDocument` and never empty otherwise. The KIND COMES
      ## FIRST, before the path, because `views/status_bar.statusBarText` fits
      ## the notification to the columns that are left and truncates the tail —
      ## so a message whose diagnosis trailed a 90-character path would be a
      ## warning the user cannot see, which is the failure that row exists to
      ## prevent.
    kind*: string
      ## The failure's own name — a `LayoutDecodeErrorKind` for a document this
      ## build understands the shape of, or one of this module's own for the
      ## ones it never reaches the decoder with. Reported separately from
      ## `message` so a check asserts a kind rather than matching prose.

  LayoutPersistIntent* = enum
    ## What exiting (or a committed change) should do with the terminal's
    ## document.
    lpiWrite = "write"
      ## The user rearranged something. Write it.
    lpiRemove = "remove"
      ## The arrangement is the profile's own — either untouched all session or
      ## put back by `:reset-layout`. Any document that is there is stale, and
      ## leaving it would restore an arrangement the user explicitly abandoned.
    lpiQuarantine = "quarantine"
      ## This session started from a document it could not read. LEAVE IT
      ## EXACTLY AS IT IS: see the module header on why overwriting a
      ## newer-schema document is the expensive mistake here.

  LayoutPersistPlan* = object
    intent*: LayoutPersistIntent
    text*: string
      ## The bytes to write, for `lpiWrite`; empty otherwise.

const
  LayoutDocumentFileName* = "tui-layout.json"
    ## THE terminal product's remembered arrangement, directly under the state
    ## root. One name, one file — see the module header's decision 3. Named
    ## here rather than in the host so the layout of the state directory is
    ## one decision in one place.

  NotJsonKind* = "NotJson"
  EmptyDocumentKind* = "EmptyDocument"
  UnreadableFileKind* = "UnreadableFile"
    ## The three failures that never reach `layout_model`'s decoder, named in
    ## the same vocabulary as the ones that do, so a caller reporting
    ## `report.kind` has one kind of thing to report.

proc unreadableLayoutDocument*(path, kind, why: string): LayoutRestoreReport =
  ## **THE ONE PLACE A RESTORE FAILURE IS WORDED.** Exported because
  ## `host/layout_store.nim` meets a failure this module cannot — a file that
  ## would not open at all — and a second message composed there would drift
  ## from this one the first time either was edited.
  LayoutRestoreReport(
    status: lrsUnreadable, path: path, kind: kind,
    # KIND FIRST, PATH LAST. See `LayoutRestoreReport.message`.
    message: "saved layout ignored (" & kind & "): " & why & " — this session " &
             "is on the default arrangement and the file was left alone: " & path)

proc adoptLayoutDocument*(b: LayoutBinding; path, text: string):
    LayoutRestoreReport =
  ## Adopt one saved document, or say exactly why it was not adopted.
  ##
  ## **Every failure arm produces a message**, which is the property this
  ## routine exists for. There is no path through it that leaves the binding on
  ## the profile default and the caller with nothing to show — see the module
  ## header on why a silent fallback is the same defect as a blank region.
  if b.isNil:
    return unreadableLayoutDocument(path, UnreadableFileKind,
                                   "there is no layout binding")
  if text.strip().len == 0:
    return unreadableLayoutDocument(path, EmptyDocumentKind,
                                   "the file is empty")
  var doc: JsonNode = nil
  try:
    doc = parseJson(text)
  except CatchableError as e:
    return unreadableLayoutDocument(path, NotJsonKind,
                                   e.msg.splitLines()[0])
  var problem = none(LayoutDecodeErrorKind)
  let acted = b.restoreDocument(doc, problem)
  if acted.status != lasApplied:
    # `restoreDocument`'s own message already carries `layout_model`'s typed
    # kind, and `problem` carries it as a value — reported both ways because a
    # status line needs prose and a check needs a kind.
    let kind = if problem.isSome: $problem.get else: "Refused"
    return unreadableLayoutDocument(path, kind, acted.message)
  LayoutRestoreReport(
    status: lrsRestored, path: path, kind: "",
    message: "layout restored from " & path)

proc layoutPersistPlan*(b: LayoutBinding; quarantined: bool):
    LayoutPersistPlan =
  ## What to do with the terminal's document after a committed change and on
  ## the way out.
  ##
  ## The three answers and their reasons are in the module header; what is here
  ## is that they are a FUNCTION of two facts the session already has —
  ## `userModified` and "did this session start from a document it could not
  ## read" — rather than a sequence of conditions spread through `main.nim`.
  if quarantined:
    return LayoutPersistPlan(intent: lpiQuarantine, text: "")
  if b.isNil or not b.userModified:
    return LayoutPersistPlan(intent: lpiRemove, text: "")
  LayoutPersistPlan(intent: lpiWrite, text: pretty(b.saveDocument()) & "\n")
