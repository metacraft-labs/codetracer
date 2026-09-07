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
## ## NOTHING IS WRITTEN AND NOTHING IS READ WITH THE FLAG OFF
##
## Both entry points below refuse on `runtime.layoutPersistenceEnabled`, which
## is false whenever there is no layout binding — so a session without
## `--layout-binding` neither opens nor creates a file, and `main.nim` does not
## have to remember that.

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
