## host/layout_store.nim — PLAT-6. **The file a terminal's rearranged layout
## lives in**, and the only thing in this front-end that opens it.
##
## ## Why this is in `host/` and not in `app/`
##
## `app/cli.nim`'s layer rule puts the DECISION in `app/` and the EFFECT in
## `host/`, and `host/capabilities.nim` is the worked example: it performs the
## seven `getEnv`s and hands a `TerminalEnv` VALUE to
## `app/theme/capabilities.resolveCapabilities`, which decides what a colour
## depth is without ever asking the environment anything.
##
## This module is that shape for the layout document. It owns the `getEnv`, the
## `readFile`, the `writeFile`, the `removeFile` and the `createDir`;
## `app/layout/persistence.nim` owns the file's NAME, what an unreadable
## document MEANS, and whether there is anything to write at all. Everything
## interesting is therefore assertable with no filesystem, and what is left
## here is small enough to read in one screen.
##
## ## THE STATE ROOT, AND THE ONE OVERRIDE
##
## `$CODETRACER_TUI_LAYOUT_DIR` if it is set, else
## `$XDG_STATE_HOME/codetracer`, else `~/.local/state/codetracer`. The XDG
## fallback is spelled the same way `src/ct_test/run_store.defaultRunStoreRoot`
## spells it, which is this repository's existing answer for "state a program
## writes for itself".
##
## The override exists for the same reason `CODETRACER_TEST_RUN_STORE` and
## `CODETRACER_TUI_HANDSHAKE_MS` do: a Tier-2 suite has to be able to point a
## real spawned binary at a directory of its own. A suite that wrote into the
## developer's own state directory would be a suite that changes the machine it
## runs on.
##
## ## WRITING IS A RENAME
##
## The document is written to `<path>.new` and moved onto `<path>`, so a
## process killed mid-write leaves the previous arrangement intact rather than
## a half-written document that the next launch reports as `NotJson`. The
## failure this prevents is the one the user would blame the feature for: they
## rearranged the panes, the machine went down, and the arrangement came back
## corrupt.
##
## **AND THAT IS NOW ASSERTED, POSITIVELY, RATHER THAN PROMISED HERE.** For one
## milestone the paragraph above was the only thing saying it, and a paragraph
## costs a defect nothing: collapsing the two lines below to a single
## `writeFile(path, plan.text)` left all four of PLAT-6's suites at **0
## failed**, and no arm in the then 83-arm mutation harness touched `moveFile`.
## The only mentions of `.new` in either suite were NEGATIVE — *"a stray `.new`
## would mean the rename did not happen"* — and a lone negative assertion has
## nothing to fail (Verification-Harness-Traps §4a).
##
## `tests/test_layout_persistence_matrix.nim`'s case *"DURABILITY: the write is
## STAGED at `<path>.new` and renamed onto the document"* is the positive twin.
## It puts a DIRECTORY where the staging file must go and nothing else: the
## write below cannot open its file, the report names `<path>.new` — which is
## the assertion that the bytes are staged rather than written in place — and
## **the previous document is still there byte for byte**, which is the promise
## itself. Remove the obstruction and the same session's same plan writes and
## renames. Arm `M58` is the collapse; `S27` is its control.
##
## ## NOTHING IS WRITTEN AND NOTHING IS READ WITH THE FLAG OFF
##
## Both entry points below refuse on `runtime.layoutPersistenceEnabled`, which
## is false whenever there is no layout binding — so a session without
## `--layout-binding` neither opens nor creates a file, and `main.nim` does not
## have to remember that.
##
## ## THE DECISION THIS MODULE CARRIES OUT IS ENUMERATED ELSEWHERE
##
## Nothing here decides anything, so nothing here is the place to reason about
## what a session should do with its document. `app/layout/persistence.nim`'s
## header holds that table — session wiring x what is on disk x what the user
## did — and `tests/test_layout_persistence_matrix.nim` asserts every cell of
## it at the FILE. Two facts from it are about THIS module and are worth having
## in front of a reader editing it:
##
##   * `lpoDisabled` and `lpoQuarantined` are different facts and the ternary
##     below is the only thing keeping them apart: "this feature is off" and
##     "this feature refused to save" are not the same report;
##   * **`lpoFailed` is reached by a table of its own, and both `except` arms
##     below are in it.** It is not a cell of the session cross, because no
##     session OBSTRUCTS the filesystem — reaching a failure arm is a fourth
##     thing to do to the world, not a fourth thing to do in a session — so
##     `FailureTable` enumerates the two arms beside the cross. Both are
##     reached on an ordinary `createTempDir()`, with a real obstruction and
##     never an injected failure: a DIRECTORY at `<path>.new` for the write,
##     and the state directory stripped of its write permission for the
##     remove. An earlier version of this comment claimed both arms needed a
##     filesystem a temporary directory cannot provide; that was false, and the
##     remove arm uses the very `setFilePermissions` technique the suite's own
##     `EACCES` lane already runs on this host.

import std/[os, strutils]

import ../app/runtime

export LayoutRestoreStatus, LayoutRestoreReport, LayoutPersistIntent

const
  LayoutDirEnvVar* = "CODETRACER_TUI_LAYOUT_DIR"
    ## Overrides the whole state root. See the module header.

  StateHomeEnvVar* = "XDG_STATE_HOME"

  LayoutDocumentTempSuffix* = ".new"

type
  LayoutPersistOutcome* = enum
    ## What exiting actually did with the document.
    lpoDisabled = "disabled"
      ## Persistence was off for this session — no binding, or no document was
      ## ever named. **Nothing was opened, created or removed**, which is the
      ## claim the flag-off arm of every suite here asserts.
    lpoQuarantined = "quarantined"
      ## The session started from a document it could not read, and it was left
      ## byte for byte as it was found.
    lpoWritten = "written"
    lpoRemoved = "removed"
      ## The arrangement was the profile's own, so a stale document was deleted
      ## rather than left to be restored next launch. `:reset-layout` is what
      ## reaches this on purpose.
    lpoFailed = "failed"

  LayoutPersistReport* = object
    outcome*: LayoutPersistOutcome
    path*: string
    message*: string
      ## Empty except for `lpoFailed`, which names the path and the errno's own
      ## message: a save that could not be made is a fact about the user's disk
      ## and they are told, on the same rule the restore half follows.

proc layoutStateRoot*(): string =
  ## Where this front-end keeps the state it writes for itself.
  let override = getEnv(LayoutDirEnvVar)
  if override.len > 0:
    return override
  let stateHome = getEnv(StateHomeEnvVar)
  if stateHome.len > 0:
    return stateHome / "codetracer"
  getHomeDir() / ".local" / "state" / "codetracer"

proc canonicalTraceFolder*(traceFolder: string): string =
  ## The path the document is keyed by: absolute and normalised, so two
  ## spellings of one recording key to one file.
  ##
  ## THE FILESYSTEM IS ASKED HERE AND NOWHERE ELSE, which is why
  ## `persistence.layoutDocumentFileName` takes a canonical path rather than
  ## canonicalising one. A failure falls back to the string as given: a
  ## recording that cannot be resolved is one this session is about to fail to
  ## open anyway, and keying it by its literal path is a worse key rather than
  ## a wrong answer.
  try:
    result = absolutePath(traceFolder).normalizedPath
  except CatchableError:
    result = traceFolder
  while result.len > 1 and (result[^1] == '/' or result[^1] == '\\'):
    result.setLen(result.len - 1)

proc layoutDocumentPathFor*(traceFolder: string): string =
  ## The document for one recording, under this host's state root.
  layoutStateRoot() / LayoutDocumentDirName /
    layoutDocumentFileName(canonicalTraceFolder(traceFolder))

proc restoreLayoutForSession*(rt: TuiRuntime;
                              traceFolder: string): LayoutRestoreReport =
  ## Bind this session to its recording's document and adopt it if there is one.
  ##
  ## The three answers are `app/layout/persistence.LayoutRestoreStatus`'s, and
  ## the caller is expected to SHOW the message for two of them. Absent is not
  ## one of the two: a first run has nothing to say.
  if not rt.layoutBindingEnabled():
    # WITH THE FLAG OFF NOTHING IS READ, and no path is even computed — so the
    # state directory is not touched, not even by a `stat`.
    return LayoutRestoreReport(status: lrsNoDocument, path: "", message: "")
  let path = layoutDocumentPathFor(traceFolder)
  rt.bindLayoutDocument(path)
  if not fileExists(path):
    return LayoutRestoreReport(status: lrsNoDocument, path: path, message: "")
  var text = ""
  try:
    text = readFile(path)
  except CatchableError as e:
    # THE ONE FAILURE THIS SIDE OF THE LINE MEETS AND `persistence.nim` cannot:
    # a file that would not open at all. It is worded by that module's own
    # composer rather than here, so there is one sentence to keep true and one
    # mutation arm (M44) covering both paths into it.
    rt.markLayoutDocumentUnreadable()
    return unreadableLayoutDocument(path, UnreadableFileKind,
                                    e.msg.splitLines()[0])
  rt.adoptLayoutDocument(path, text)

proc persistLayoutForSession*(rt: TuiRuntime): LayoutPersistReport =
  ## Carry out this session's persist plan. Called once, on the way out.
  ##
  ## Nothing here decides anything: the plan is
  ## `runtime.layoutPersistPlanOf`'s, so "write it", "delete the stale one" and
  ## "leave it alone" are one function of the session's own state rather than
  ## three conditions spread across the callers.
  let path = rt.layoutDocument
  let plan = rt.layoutPersistPlanOf()
  case plan.intent
  of lpiQuarantine:
    LayoutPersistReport(
      outcome: (if rt.layoutPersistenceEnabled(): lpoQuarantined
                else: lpoDisabled),
      path: path, message: "")
  of lpiRemove:
    try:
      if path.len > 0 and fileExists(path):
        removeFile(path)
      LayoutPersistReport(outcome: lpoRemoved, path: path, message: "")
    except CatchableError as e:
      LayoutPersistReport(
        outcome: lpoFailed, path: path,
        message: "the saved layout could not be removed: " & path & ": " & e.msg)
  of lpiWrite:
    let temp = path & LayoutDocumentTempSuffix
    try:
      createDir(path.parentDir)
      writeFile(temp, plan.text)
      moveFile(temp, path)
      LayoutPersistReport(outcome: lpoWritten, path: path, message: "")
    except CatchableError as e:
      try:
        if fileExists(temp):
          removeFile(temp)
      except CatchableError:
        discard
      LayoutPersistReport(
        outcome: lpoFailed, path: path,
        message: "the layout could not be saved: " & path & ": " & e.msg)
