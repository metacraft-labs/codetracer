## PLAT-43 — the keymap selector, Tier 1.
##
## Run:
##   nim c -r <tui lane flags> src/frontend/tui/tests/test_plat43_keymap_selector.nim
##
## PLAT-31 built three keymap models and PLAT-34 made a document take one, but
## no key the terminal accepts chose between them. `:keymap <name>` (Edit mode)
## now does, through ONE function — `keymap_selection.selectKeymap` — which the
## stored preference (`viewmodel/host/keymap_preference`) goes through too.
## This suite asserts, without a terminal:
##
##   * THE MODEL PARTITION: every `KeymapModel` member is selectable by name,
##     and every selectable name is a member, with the cardinality on both
##     sides;
##   * an unknown name REFUSED BY NAME, naming the accepted set — typed or
##     stored — and the model left as it was;
##   * `:keymap` through the runtime's own prompt re-keys the OPEN buffer and
##     asks the host to remember the choice;
##   * the preference on a real filesystem: absent, stored, refused;
##   * `DIFF-12`: every one of PLAT-31's divergent tasks, on every corpus
##     document, through a SELECTED model and through the model constructed
##     directly, yields the same editor state — the selector is not a fourth
##     keymap.
##
## ## The one stand-in, and why it is not a mock
##
## `rt.editServices.saveKeymap` is a closure the case installs to record what
## the runtime asked the host to remember — the same seam
## `test_edit_mode_build.nim` uses for `startBuild`, because `app/` may not
## touch a file. The real saver (`saveKeymapPreference`) is exercised against
## a real directory in its own case below, and through the shipped binary in
## `real_terminal/test_real_keymap_selector.nim`.

import std/[os, sequtils, strutils, tempfiles, unittest]

import codetracer_embed
import ../app/edit_binding
import ../app/runtime
import ../app/theme/capabilities
import ../../viewmodel/host/keymap_preference
import ../../viewmodel/host/native_state
import ../../viewmodel/tests/generators/keymap_task_set

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 120
  Rows = 40
  FileA = "src/alpha.nim"
  TextA = "proc alpha() =\n  echo 1\n"
  ModelCount = 3
    ## `KeymapModel`'s cardinality, stated so both directions of the partition
    ## law are compared with a number rather than with each other.
  ExpectedScenarioDocs = 18

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc editingRuntime(): TuiRuntime =
  let app = newTuiApp()
  app.modes = initModeRegister(pmEdit)
  app.editSession = newEditSession()
  discard app.editSession.openFile(FileA, TextA)
  newTuiRuntime(app, caps(), Cols, Rows)

proc runPrompt(rt: TuiRuntime; line: string) =
  ## The prompt opened and typed exactly as `test_edit_mode_build.nim` does,
  ## then submitted with a real `Enter` token.
  discard rt.prompt.open(pkCommand)
  for ch in line:
    discard rt.prompt.applyKey($ch, @[])
  discard rt.handleToken("\r", 0)

suite "PLAT-43: the model partition, and refusal by name":

  test "every model is selectable, and every selectable name is a model":
    let names = selectableKeymapNames()
    var members: seq[KeymapModel] = @[]
    for m in KeymapModel: members.add m
    ck members.len == ModelCount
    ck names.len == ModelCount
    ck names.deduplicate().len == ModelCount
    for m in KeymapModel:
      let s = selectKeymap($m)
      ck s.ok
      ck s.model == m
      ck s.refusal.len == 0
    for n in names:
      let s = selectKeymap(n)
      ck s.ok
      ck $s.model == n

  test "an unknown name is refused BY NAME, with the accepted set":
    for bad in ["emacs", "Vim", " vim", "vim ", "", "kak"]:
      let s = selectKeymap(bad)
      checkpoint("'" & bad & "' -> " & s.refusal)
      ck not s.ok
      ck s.refusal.contains("'" & bad & "'")
      for n in selectableKeymapNames():
        ck s.refusal.contains(n)

  test "a stored preference goes through the same selector":
    for m in KeymapModel:
      let back = decodeKeymapPreference(encodeKeymapPreference(m))
      ck back.ok
      ck back.model == m
    let bad = decodeKeymapPreference("nano\n")
    ck not bad.ok
    ck bad.refusal.contains("'nano'")
    ck bad.refusal.contains(KeymapSourceStored)

suite "PLAT-43: `:keymap` through the runtime's own prompt":

  test "`:keymap vim` re-keys the OPEN buffer and asks the host to remember it":
    let rt = editingRuntime()
    var remembered: seq[KeymapModel] = @[]
    rt.editServices.saveKeymap = proc(m: KeymapModel): string =
      remembered.add m
      ""
    let buf = rt.app.editSession.activeBuffer()
    ck buf.doc.model == kmProductDefault
    ck buf.doc.state.mode == emInsert
    rt.runPrompt(":keymap vim")
    ck rt.app.notification == "keymap vim"
    ck rt.app.editSession.model == kmVim
    ck buf.doc.model == kmVim
    ck buf.doc.state.mode == emNormal
    ck buf.text == TextA
    ck rt.keymapModel == kmVim
    ck remembered == @[kmVim]
    # A file opened AFTER the choice opens under it.
    let second = rt.app.editSession.openFile("src/beta.nim", "x\n")
    ck rt.app.editSession.buffers[second].doc.model == kmVim

  test "`:keymap emacs` is refused by name and changes nothing":
    let rt = editingRuntime()
    var remembered: seq[KeymapModel] = @[]
    rt.editServices.saveKeymap = proc(m: KeymapModel): string =
      remembered.add m
      ""
    rt.runPrompt(":keymap emacs")
    checkpoint(rt.app.notification)
    ck rt.app.notification.contains("'emacs'")
    ck rt.app.notification.contains("kakoune")
    ck rt.app.editSession.model == kmProductDefault
    ck rt.app.editSession.activeBuffer().doc.model == kmProductDefault
    ck remembered.len == 0

  test "`:keymap` alone names the current model and the accepted set":
    let rt = editingRuntime()
    rt.runPrompt(":keymap")
    ck rt.app.notification.startsWith("keymap default")
    ck rt.app.notification.contains(acceptedKeymapNamesText())

  test "a host that keeps no state says the choice is not remembered":
    let rt = editingRuntime()
    rt.runPrompt(":keymap kakoune")
    ck rt.app.editSession.model == kmKakoune
    ck rt.app.notification.contains("not remembered")

  test "switching keeps the document and its history":
    let rt = editingRuntime()
    let buf = rt.app.editSession.activeBuffer()
    discard buf.applyEditKey("Z", 1)
    let text = buf.text
    let undoDepth = buf.doc.state.history.undoDepth
    ck text.startsWith("Z")
    ck undoDepth > 0
    rt.app.editSession.selectModel(kmVim)
    ck buf.text == text
    ck buf.doc.state.history.undoDepth == undoDepth
    ck buf.doc.state.mode == emNormal
    # …and the history is USABLE under the new model: Vim's `u` undoes it.
    discard buf.applyEditKey("u", 2)
    ck buf.text == TextA

suite "PLAT-43: which keys the editor owns, per model":

  test "Tab is never the editor's; a model's own non-printable keys are":
    # The runtime asks the active model's resolver whether it claims a key,
    # so Vim's `Esc` and Kakoune's `Ctrl+x` reach the buffer. `Tab` must NOT,
    # under any model: it is the one chord guaranteed to move focus off the
    # editor, and the product default binds it to `indent` — the pty suite's
    # first run measured exactly that swallowing.
    proc focusedRuntime(): TuiRuntime =
      result = editingRuntime()
      discard result.focus.focusPaneKind(paneEditor)
    for model in KeymapModel:
      let rt = focusedRuntime()
      rt.app.editSession.selectModel(model)
      checkpoint($model)
      ck not rt.editorOwnsToken("\t")
      ck not rt.editorOwnsToken("\x1b[Z")      # Shift+Tab
      ck rt.editorOwnsToken("x")
    let vim = focusedRuntime()
    vim.app.editSession.selectModel(kmVim)
    # Vim binds `Esc` in insert, visual and operator-pending modes and NOT in
    # normal mode — so in normal mode it is not the editor's, and after `i`
    # it is. Both halves, because the clause is a question about the model's
    # CURRENT state, not a list.
    ck not vim.editorOwnsToken("\x1b")         # Esc, normal mode
    discard vim.app.editSession.activeBuffer().applyEditKey("i", 1)
    ck vim.editorOwnsToken("\x1b")             # Esc, insert mode
    let kak = focusedRuntime()
    kak.app.editSession.selectModel(kmKakoune)
    ck kak.editorOwnsToken("\x18")             # Ctrl+x
    # …and the product default does not claim `Ctrl+x`: the clause is the
    # MODEL's answer, not a widened constant.
    let def = focusedRuntime()
    ck not def.editorOwnsToken("\x18")

suite "PLAT-43: the stored preference, on a real filesystem":

  test "absent, stored, and refused":
    let dir = createTempDir("plat43-", "-state")
    let before = getEnv(NativeStateDirEnvVar)
    putEnv(NativeStateDirEnvVar, dir)
    try:
      let absent = loadKeymapPreference()
      ck absent.status == kplAbsent
      ck absent.model == kmProductDefault
      ck saveKeymapPreference(kmKakoune) == ""
      ck readFile(dir / KeymapPreferenceFileName) == "kakoune\n"
      ck not fileExists(dir / (KeymapPreferenceFileName & StagedWriteSuffix))
      let stored = loadKeymapPreference()
      ck stored.status == kplLoaded
      ck stored.model == kmKakoune
      writeFile(dir / KeymapPreferenceFileName, "nano\n")
      let refused = loadKeymapPreference()
      checkpoint(refused.message)
      ck refused.status == kplRefused
      ck refused.model == kmProductDefault
      ck refused.message.contains("'nano'")
      ck refused.message.contains(acceptedKeymapNamesText())
      ck refused.message.contains(dir)
      # The refused file is EVIDENCE and is left as it was.
      ck readFile(dir / KeymapPreferenceFileName) == "nano\n"
    finally:
      if before.len > 0: putEnv(NativeStateDirEnvVar, before)
      else: delEnv(NativeStateDirEnvVar)
      removeDir(dir)

suite "PLAT-43: DIFF-12 — a selected model is the model, not a fourth keymap":

  test "PLAT-31's divergent tasks, selected vs constructed, on every corpus document":
    let docs = scenarioDocs()
    ck docs.len == ExpectedScenarioDocs
    var divergent: seq[EditingTask] = @[]
    for t in TaskSet:
      if t.id notin CoincidentOperationTasks:
        divergent.add t
    ck divergent.len == DivergentOperationTasks
    var compared = 0
    var mismatches: seq[string] = @[]
    for d in docs:
      for t in divergent:
        for model in [kmVim, kmKakoune]:
          let keys = if model == kmVim: t.vimKeys else: t.kakouneKeys
          # SELECTED: opened under the default, then chosen BY NAME through
          # the selector and re-keyed through the session.
          let selected = newEditSession()
          discard selected.openFile("doc", d.text)
          let choice = selectKeymap($model)
          selected.selectModel(choice.model)
          # CONSTRUCTED: the model handed to the session directly.
          let direct = newEditSession(model)
          discard direct.openFile("doc", d.text)
          let a = selected.activeBuffer()
          let b = direct.activeBuffer()
          a.doc.state.selection = caretSelection(caretOffset(d, t.caret))
          b.doc.state.selection = caretSelection(caretOffset(d, t.caret))
          var now = 0'i64
          for k in keys:
            inc now
            discard a.applyEditKey(k, now)
            discard b.applyEditKey(k, now)
          inc compared
          if a.doc.state != b.doc.state or a.doc.model != b.doc.model:
            mismatches.add d.id & "/" & t.id & "/" & $model
    checkpoint("mismatches: " & mismatches.join(", "))
    ck compared == ExpectedScenarioDocs * DivergentOperationTasks * 2
    ck mismatches.len == 0

  test "the population can tell the two models apart":
    # §20: a task set that cannot tell Vim from Kakoune would pass DIFF-12
    # under either. On the first corpus document, running each task's VIM keys
    # under the Kakoune model must differ from running them under Vim for at
    # least one task — otherwise the selector could hand back the wrong model
    # and nothing above would notice.
    let d = scenarioDocs()[0]
    var differing = 0
    for t in TaskSet:
      if t.id in CoincidentOperationTasks: continue
      let v = newEditSession(kmVim)
      discard v.openFile("doc", d.text)
      let k = newEditSession(kmKakoune)
      discard k.openFile("doc", d.text)
      let a = v.activeBuffer()
      let b = k.activeBuffer()
      a.doc.state.selection = caretSelection(caretOffset(d, t.caret))
      b.doc.state.selection = caretSelection(caretOffset(d, t.caret))
      var now = 0'i64
      for key in t.vimKeys:
        inc now
        discard a.applyEditKey(key, now)
        discard b.applyEditKey(key, now)
      if a.doc.state.doc != b.doc.state.doc: inc differing
    checkpoint("tasks whose Vim keys edit differently under Kakoune: " & $differing)
    ck differing > 0

suite "PLAT-43 — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
