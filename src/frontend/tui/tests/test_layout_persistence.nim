## test_layout_persistence.nim — PLAT-6, Tier 1: **the layout document**.
##
## ## The row this closes
##
## PLAT-6's Goal reads *"move tabs, resize splits, dock panes, save and
## restore"*, and its own verification pass recorded that the fourth clause was
## the one a user did not get: `binding.saveDocument` and
## `binding.restoreDocument` existed, were asserted, and had **no caller outside
## the two Tier-1 suites**. Nothing in `runtime.nim`, `main.nim` or `host/` wrote
## a rearranged terminal layout anywhere or read one back, so an arrangement did
## not survive a restart.
##
## `app/layout/persistence.nim` and `host/layout_store.nim` are the two halves
## that close it — the decisions and the file — and `main.nim` is the caller.
## This suite owns everything about them that a terminal cannot answer:
##
##   * **the key**: which recording a document belongs to, and that two
##     recordings never share one;
##   * **the round trip**, driven through the product's own `:` prompt rather
##     than through `saveDocument`, because calling the two routines directly is
##     precisely the gap being closed;
##   * **the failure arms** — corrupt bytes, an empty file, a schema version
##     from a newer build, a pane this build does not have — each of which must
##     be REPORTED BY KIND and must leave the document untouched;
##   * **the flag-off arm**, where nothing is read, nothing is written and the
##     state directory is not touched at all.
##
## `tests/real_terminal/test_real_layout_persistence.nim` is the Tier-2 half: it
## docks a pane on a REAL pty, exits, relaunches a second process on the same
## recording, and finds the pane still docked.
##
## ## Why this is not under `app/tests/`
##
## `test_tui_facade_boundary.nim` walks `app/`'s import graph and forbids a host
## import there, so a suite that reaches `host/layout_store` belongs on this
## side of the line — which is the same reason `test_headless_mode.nim` and
## `test_ssh_tuning.nim` live here.
##
## ## No mocks
##
## There is no mock here and none is justified. The filesystem is a REAL
## temporary directory under `getTempDir()`, written and read by the product's
## own `host/layout_store.nim`; the arrangement is produced by typing `:dock
## bottom` into the product's own `handleToken`; the document is
## `layout_model`'s own JSON. The `Dispatcher` carries no ViewModels, which is
## not a stand-in for one: `app/commands/interpreter.nim` documents nil as "not
## wired" and answers `drUnavailable` BY NAME, and a layout verb needs no
## debugger at all.
##
## ## Templates, not procs, for anything that calls `check`
##
## Verification-Harness-Traps §13: `unittest.check` inside a plain `proc`
## resolves to a module-level global and the test still reports `[OK]` with its
## failed comparison printed above it. Every helper here that calls `check` is a
## `template`; the ones that are `proc`s return values and call `check` nowhere.

import std/[algorithm, json, os, strutils, tempfiles, unittest]

import headless_app/layout_model

import ../app/runtime
import ../app/theme/capabilities
import ../host/layout_store

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 202

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

# ---------------------------------------------------------------------------
# Fixtures. Values only; nothing here calls `check`.
# ---------------------------------------------------------------------------

proc caps(): TerminalCapabilities =
  ## A resolved capability set from a CONSTRUCTED environment rather than the
  ## process's own — `test_capability_resolution.nim`'s rule, for the same
  ## reason: a suite that read `getEnv` would assert something different on
  ## every host.
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc newRuntime(cols, rows: int): TuiRuntime =
  newTuiRuntime(newTuiApp(), caps(), cols, rows)

proc newBoundRuntime(cols, rows: int): TuiRuntime =
  result = newRuntime(cols, rows)
  discard result.enableLayoutBinding()

proc typeLine(rt: TuiRuntime; line: string): RuntimeOutcome =
  ## `:`, then every character, then `Enter` — through `handleToken`, ONE TOKEN
  ## AT A TIME, which is the path a terminal's bytes take.
  result = rt.handleToken(":", 0'i64)
  for ch in line:
    result = rt.handleToken($ch, 0'i64)
  result = rt.handleToken("\r", 0'i64)

proc focusedPaneOf(rt: TuiRuntime): PaneKind =
  let (had, pane) = rt.focus.focusedPane()
  if had: pane else: PaneKind.low

proc offersPane(rt: TuiRuntime; pane: PaneKind): int =
  ## How many times `Tab` would offer `pane`. A COUNT rather than a boolean,
  ## because "the ring holds it twice" and "the ring holds it once" are
  ## different defects and only one of them is the one under test.
  for offered in rt.focus.focusOrder():
    if offered == pane:
      inc result

proc filesUnder(root: string): seq[string] =
  ## Every file below `root`, as paths relative to it, sorted.
  ##
  ## THE WHOLE STATE ROOT, not the one document, because "nothing was written"
  ## has to exclude a stray `.new` a failed rename left behind as well as the
  ## document itself.
  result = @[]
  if not dirExists(root):
    return
  for path in walkDirRec(root):
    result.add path.relativePath(root)
  result.sort()

proc stripsOnScreen(rt: TuiRuntime): int =
  for d in rt.shellScreenOf().decorations:
    if d.kind == ldDockStrip:
      inc result

proc overlaysOnScreen(rt: TuiRuntime): int =
  for d in rt.shellScreenOf().decorations:
    if d.kind == ldRevealOverlay:
      inc result

proc titleRowsFor(rt: TuiRuntime; prefix: string): int =
  for row in rt.shellScreenOf().rows:
    if row.startsWith(prefix):
      inc result

proc mentionsKey(node: JsonNode; key: string): bool =
  ## Whether `key` appears anywhere in the document, at any depth.
  case node.kind
  of JObject:
    for name, value in node:
      if name == key or value.mentionsKey(key):
        return true
    false
  of JArray:
    for value in node:
      if value.mentionsKey(key):
        return true
    false
  else:
    false

type
  Sandbox = object
    ## One test's private state root and recording, plus the environment
    ## variable that points the product at them.
    root: string
    trace: string

proc newSandbox(tag: string): Sandbox =
  ## A private state root and a private "recording" folder.
  ##
  ## The folder does not have to contain a recording: nothing in the layout
  ## store reads it, and everything that does — `traceFolderProblem`,
  ## `openTuiSession` — is `main.nim`'s and runs before this. What the store
  ## needs of it is a stable, canonicalisable path, which is exactly what the
  ## key is derived from.
  let base = createTempDir("plat6-layout-" & tag & "-", "")
  result = Sandbox(root: base / "state", trace: base / "recording.ct")
  createDir(result.trace)
  putEnv(LayoutDirEnvVar, result.root)

proc documentOf(box: Sandbox): string =
  layoutDocumentPathFor(box.trace)

proc dispose(box: Sandbox) =
  delEnv(LayoutDirEnvVar)
  removeDir(box.root.parentDir)

# ---------------------------------------------------------------------------

suite "PLAT-6: a terminal's arrangement is saved, restored, and never guessed":

  test "the document is keyed by the recording, so two recordings never share one":
    # THE KEY RULE. A layout saved for one recording must not silently apply to
    # another, which is the decision `app/layout/persistence.nim`'s header
    # records; this is that decision as a measurement.
    let a = layoutDocumentFileName("/home/u/traces/calc.ct")
    let b = layoutDocumentFileName("/home/u/other/calc.ct")
    let again = layoutDocumentFileName("/home/u/traces/calc.ct")
    checkpoint("calc.ct in two places -> " & a & " and " & b)
    # SAME PATH, SAME DOCUMENT — the property a restart depends on.
    ck a == again
    # SAME BASENAME, DIFFERENT PARENT, DIFFERENT DOCUMENT. This is the half a
    # slug-only key would fail, and it is why the digest is over the whole path.
    ck a != b
    # …and they still LOOK the same to a human reading the state directory,
    # which is why the slug is there at all.
    ck a.startsWith("calc.ct-")
    ck b.startsWith("calc.ct-")
    ck a.endsWith(LayoutDocumentExt)
    ck b.endsWith(LayoutDocumentExt)

    # A NAME NO FILESYSTEM WOULD ACCEPT VERBATIM still produces one component.
    var slugged = 0
    for folder in ["/tmp/a b/c:d*/e?f", "/tmp/../", "/", "",
                   "/tmp/" & repeat("x", 200)]:
      inc slugged
      let name = layoutDocumentFileName(folder)
      checkpoint(folder & " -> " & name)
      ck name.len > 0
      ck not name.contains('/')
      ck not name.contains('\\')
      ck not name.contains(':')
      ck not name.contains('*')
      ck not name.contains('?')
      ck not name.contains(' ')
      ck name.endsWith(LayoutDocumentExt)
      # THE NON-VACUITY FLOOR on the digest: a key that had collapsed to the
      # slug alone would be shorter than this and would collide.
      ck name.len > LayoutKeyDigestChars + LayoutDocumentExt.len
    ck slugged == 5

    # AND THE PATH IS UNDER THE STATE ROOT THE HOST RESOLVES, in its own
    # directory, so a user can find it and delete it.
    let box = newSandbox("key")
    try:
      let path = box.documentOf()
      checkpoint("the document for " & box.trace & " is " & path)
      ck path.parentDir == box.root / LayoutDocumentDirName
      ck path.extractFilename ==
        layoutDocumentFileName(canonicalTraceFolder(box.trace))
      # TWO SPELLINGS OF ONE RECORDING KEY TO ONE DOCUMENT, which is what
      # canonicalising in the host buys.
      ck layoutDocumentPathFor(box.trace & "/") == path
      ck layoutDocumentPathFor(box.trace & "/./") == path
    finally:
      box.dispose()

  test "a docked pane survives a restart, through the product's own `:` prompt":
    # **THE ROW ITSELF.** The arrangement is produced by typing `:dock bottom`
    # into `handleToken` and saved by the same call `main.nim` makes on the way
    # out; a SECOND runtime — a fresh `TuiApp`, a fresh binding, nothing shared
    # — restores it by the same call `main.nim` makes on the way in.
    let box = newSandbox("roundtrip")
    try:
      ck filesUnder(box.root).len == 0

      let first = newBoundRuntime(80, 24)
      let restoredNothing = restoreLayoutForSession(first, box.trace)
      # A FIRST RUN HAS NOTHING TO SAY, and says nothing.
      ck restoredNothing.status == lrsNoDocument
      ck restoredNothing.message.len == 0
      ck first.layoutDocument == box.documentOf()
      let docked = first.focusedPaneOf()
      ck docked == paneCalltrace
      ck first.app.layoutBinding.layout.tree.contains(docked)

      discard first.typeLine("dock bottom")
      checkpoint(":dock bottom -> " & first.app.notification)
      ck first.app.layoutBinding.layout.dockedIndex(docked) >= 0
      ck first.app.layoutBinding.userModified
      let saved = persistLayoutForSession(first)
      checkpoint("persist -> " & $saved.outcome & " " & saved.path)
      ck saved.outcome == lpoWritten
      ck saved.message.len == 0
      ck fileExists(box.documentOf())
      # EXACTLY ONE FILE. A `.new` left behind would mean the rename did not
      # happen and the next launch would read a half-written document.
      ck filesUnder(box.root) ==
        @[LayoutDocumentDirName / box.documentOf().extractFilename]

      # THE DOCUMENT ITSELF, before anything reads it back: versioned, with the
      # docked pane in it, and WITHOUT `revealed` (Layout-ViewModel §3.2).
      let doc = parseJson(readFile(box.documentOf()))
      ck doc["version"].getInt == LayoutSchemaVersion
      ck doc["docked"].len == 1
      ck doc["docked"][0]["pane"].getStr == $docked
      ck doc["docked"][0]["edge"].getStr == $leBottom
      ck not doc.mentionsKey("revealed")
      # …and the positive twin for that scan, through the same predicate: a key
      # the document DOES carry is found, so `not mentionsKey` is a measurement
      # rather than a walk that reaches nothing.
      ck doc.mentionsKey("docked")
      ck doc.mentionsKey("pane")

      # ---- THE SECOND SESSION -------------------------------------------
      let second = newBoundRuntime(80, 24)
      ck second.app.layoutBinding.layout.tree.contains(docked)
      ck second.stripsOnScreen() == 0
      ck second.titleRowsFor("CALL STACK") == 1
      let report = restoreLayoutForSession(second, box.trace)
      checkpoint("restore -> " & $report.status & " | " & report.message)
      ck report.status == lrsRestored
      ck report.kind.len == 0
      ck report.message.contains(box.documentOf())
      # THE MODEL: the pane is docked, exactly as the first session left it.
      ck second.app.layoutBinding.layout.dockedIndex(docked) >= 0
      ck not second.app.layoutBinding.layout.tree.contains(docked)
      ck second.app.layoutBinding.layout.dockedAt(leBottom).len == 1
      # THE SCREEN: the strip is there and the pane's own title row is gone.
      ck second.stripsOnScreen() == 1
      ck second.titleRowsFor("CALL STACK") == 0
      # `revealed` IS NOT PERSISTED: no overlay is open and no gesture is in
      # flight, whatever the previous session was doing when it exited.
      ck second.overlaysOnScreen() == 0
      ck second.app.layoutBinding.interaction.kind == ikNone
      # THE FOCUS RING WAS REBUILT from the restored arrangement, so `Tab`
      # cannot offer the pane that is no longer on screen.
      ck second.offersPane(docked) == 0
      ck second.focusedPaneOf() != docked
      ck second.app.layoutBinding.focus == second.focusedPaneOf()
      # THE TWO SESSIONS AGREE, compared as the document rather than as prose.
      ck $second.app.layoutBinding.saveDocument() ==
        $first.app.layoutBinding.saveDocument()
    finally:
      box.dispose()

  test "a restored arrangement freezes the responsive profile":
    # PLAT-6 decided a user modification freezes the profile. **A RESTORED
    # DOCUMENT IS A USER MODIFICATION**, made in a previous session, and that is
    # a decision rather than an accident of `restoreDocument`'s implementation —
    # see `app/layout/persistence.nim`'s header.
    let box = newSandbox("freeze")
    try:
      let first = newBoundRuntime(80, 24)
      discard restoreLayoutForSession(first, box.trace)
      discard first.typeLine("dock bottom")
      ck persistLayoutForSession(first).outcome == lpoWritten

      let second = newBoundRuntime(80, 24)
      ck restoreLayoutForSession(second, box.trace).status == lrsRestored
      ck second.app.layoutBinding.userModified
      ck second.app.layoutBinding.profile == lpCompact
      let mine = $second.app.layoutBinding.saveDocument()
      second.resize(200, 60)
      checkpoint("after a resize the profile is " &
                 $second.app.layoutBinding.profile)
      # The profile TRACKS the size — the status bar names it — and the TREE is
      # the user's.
      ck second.app.layoutBinding.profile == lpUltraWide
      ck $second.app.layoutBinding.saveDocument() == mine
      ck second.app.layoutBinding.layout.dockedAt(leBottom).len == 1

      # THE NEGATIVE TWIN, through the same code path: a session that restored
      # NOTHING re-flows, so the assertion above is about the freeze rather than
      # about a `resize` that never rebuilds anything.
      let untouched = newBoundRuntime(80, 24)
      discard restoreLayoutForSession(untouched, layoutStateRoot() / "absent")
      ck not untouched.app.layoutBinding.userModified
      let before = $untouched.app.layoutBinding.saveDocument()
      untouched.resize(200, 60)
      ck untouched.app.layoutBinding.profile == lpUltraWide
      ck $untouched.app.layoutBinding.saveDocument() != before
    finally:
      box.dispose()

  test "an unreadable document is reported BY KIND and is never overwritten":
    # **THE ARM THAT MATTERS MOST.** `layout_model.PaneKind`'s design note says
    # an unrepresentable state must be a typed, reportable error and never a
    # silently blank region; a restore that quietly fell back to the profile
    # default after failing to read a document is that failure wearing different
    # clothes. Four ways a document can be unreadable, each named, each leaving
    # the file exactly as it was found.
    var armsChecked = 0
    for arm in [
        ("corrupt bytes", "{not json at all", NotJsonKind),
        ("an empty file", "   \n  ", EmptyDocumentKind),
        ("a schema version from a NEWER build",
         """{"version": 99, "layout": {"kind": "pane", "pane": "editor"},
             "docked": []}""", $ldeUnknownVersion),
        ("a pane this build does not have",
         """{"version": 2, "layout": {"kind": "pane", "pane": "holodeck"},
             "docked": []}""", $ldeUnknownPane)]:
      inc armsChecked
      let box = newSandbox("bad")
      try:
        createDir(box.documentOf().parentDir)
        writeFile(box.documentOf(), arm[1])
        let planted = readFile(box.documentOf())

        let rt = newBoundRuntime(80, 24)
        let report = restoreLayoutForSession(rt, box.trace)
        checkpoint(arm[0] & " -> " & $report.status & " [" & report.kind &
                   "] " & report.message)
        ck report.status == lrsUnreadable
        # THE KIND IS A VALUE, not a substring of prose.
        ck report.kind == arm[2]
        # …and the message LEADS with it, because `status_bar.statusBarText`
        # fits the notification to the columns that are left and truncates the
        # tail: a diagnosis behind a 90-character path is a warning the user
        # cannot see.
        ck report.message.startsWith("saved layout ignored (" & arm[2] & ")")
        ck report.message.contains(box.documentOf())
        # THE SESSION IS USABLE, on the profile's own arrangement.
        ck rt.app.layoutBinding.layout.tree.contains(paneCalltrace)
        ck rt.stripsOnScreen() == 0
        ck rt.titleRowsFor("CALL STACK") == 1
        # AND THE DOCUMENT IS QUARANTINED. Overwriting a document written by a
        # NEWER build would destroy a user's arrangement because they opened an
        # older binary once, which is the whole reason the schema chain refuses
        # forward rather than guessing.
        ck rt.layoutDocumentQuarantined
        let persisted = persistLayoutForSession(rt)
        ck persisted.outcome == lpoQuarantined
        ck readFile(box.documentOf()) == planted
        ck filesUnder(box.root) ==
          @[LayoutDocumentDirName / box.documentOf().extractFilename]
      finally:
        box.dispose()
    checkpoint("unreadable-document arms: " & $armsChecked)
    ck armsChecked == 4

    # THE POSITIVE TWIN, through the SAME two calls: a document this build CAN
    # read is adopted and IS rewritten on the way out. Without it, every
    # assertion above is satisfied by a store that refuses everything.
    let box = newSandbox("good")
    try:
      let first = newBoundRuntime(80, 24)
      discard restoreLayoutForSession(first, box.trace)
      discard first.typeLine("dock right")
      ck persistLayoutForSession(first).outcome == lpoWritten
      let written = readFile(box.documentOf())

      let second = newBoundRuntime(80, 24)
      let report = restoreLayoutForSession(second, box.trace)
      ck report.status == lrsRestored
      ck not second.layoutDocumentQuarantined
      discard second.typeLine("dock top")
      let rewritten = persistLayoutForSession(second)
      ck rewritten.outcome == lpoWritten
      ck readFile(box.documentOf()) != written
      # The restored pane is still docked right AND the second session's own
      # gesture is in the document too, so what was rewritten is the union
      # rather than a fresh default.
      var edges: seq[string] = @[]
      for entry in parseJson(readFile(box.documentOf()))["docked"]:
        edges.add entry["edge"].getStr
      edges.sort()
      checkpoint("after a second session's gesture the edges are " & $edges)
      ck edges == @[$leRight, $leTop]
    finally:
      box.dispose()

  test "no gesture, no document — and `:reset-layout` deletes a stale one":
    # THE OTHER HALF OF THE FREEZE DECISION. Persisting a profile DEFAULT would
    # freeze the profile on the next launch, so opening a recording once in an
    # 80x24 terminal would pin the Compact tree on a 200x60 one for ever without
    # the user having touched anything.
    let box = newSandbox("reset")
    try:
      let untouched = newBoundRuntime(80, 24)
      discard restoreLayoutForSession(untouched, box.trace)
      ck not untouched.app.layoutBinding.userModified
      let nothing = persistLayoutForSession(untouched)
      checkpoint("an untouched session persists as " & $nothing.outcome)
      ck nothing.outcome == lpoRemoved
      ck not fileExists(box.documentOf())
      ck filesUnder(box.root).len == 0

      # Now rearrange, save, and reset: the explicit way back reaches the DISK,
      # so the next launch cannot restore an arrangement the user abandoned.
      let rt = newBoundRuntime(80, 24)
      discard restoreLayoutForSession(rt, box.trace)
      discard rt.typeLine("dock bottom")
      ck persistLayoutForSession(rt).outcome == lpoWritten
      ck fileExists(box.documentOf())

      let after = newBoundRuntime(80, 24)
      ck restoreLayoutForSession(after, box.trace).status == lrsRestored
      discard after.typeLine("reset-layout")
      checkpoint(":reset-layout -> " & after.app.notification)
      ck not after.app.layoutBinding.userModified
      let removed = persistLayoutForSession(after)
      ck removed.outcome == lpoRemoved
      ck not fileExists(box.documentOf())
      ck filesUnder(box.root).len == 0

      # …and a THIRD launch is on the profile's own arrangement again.
      let fresh = newBoundRuntime(80, 24)
      ck restoreLayoutForSession(fresh, box.trace).status == lrsNoDocument
      ck fresh.app.layoutBinding.layout.tree.contains(paneCalltrace)
      ck fresh.stripsOnScreen() == 0
    finally:
      box.dispose()

  test "OFF BY DEFAULT: with no binding nothing is read and nothing is written":
    # THE ARM THE WHOLE OPT-IN RESTS ON, for persistence as for the gestures.
    # A document is planted at exactly the path a bound session would use, and a
    # session without `--layout-binding` neither reads it nor writes it — and
    # never computes the path, so the state directory is not touched even by a
    # `stat`.
    let box = newSandbox("off")
    try:
      let source = newBoundRuntime(80, 24)
      discard restoreLayoutForSession(source, box.trace)
      discard source.typeLine("dock bottom")
      ck persistLayoutForSession(source).outcome == lpoWritten
      let planted = readFile(box.documentOf())
      let plantedFiles = filesUnder(box.root)
      ck plantedFiles.len == 1

      var sessionsChecked = 0
      for size in [(80, 24), (120, 40), (200, 60)]:
        inc sessionsChecked
        let rt = newRuntime(size[0], size[1])
        ck not rt.layoutBindingEnabled()
        ck not rt.layoutPersistenceEnabled()
        let report = restoreLayoutForSession(rt, box.trace)
        checkpoint("with no binding, restore -> " & $report.status &
                   " path '" & report.path & "'")
        ck report.status == lrsNoDocument
        ck report.message.len == 0
        # NO PATH IS EVEN COMPUTED, which is the stronger statement.
        ck report.path.len == 0
        ck rt.layoutDocument.len == 0
        let persisted = persistLayoutForSession(rt)
        ck persisted.outcome == lpoDisabled
        ck persisted.path.len == 0
        # The screen is the one a session with no binding has always painted.
        ck rt.stripsOnScreen() == 0
        ck rt.titleRowsFor("CALL STACK") == 1
      ck sessionsChecked == 3
      # NOT ONE BYTE MOVED, and nothing was created beside it.
      ck readFile(box.documentOf()) == planted
      ck filesUnder(box.root) == plantedFiles
    finally:
      box.dispose()

  test "assertion count":
    checkpoint("CHECKS: " & $countedAssertions)
    echo "CHECKS: ", countedAssertions
    check countedAssertions == ExpectedAssertions
