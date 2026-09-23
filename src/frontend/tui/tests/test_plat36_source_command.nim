## PLAT-36 — `:source <file>`: a user's Vim configuration, imported and
## INSTALLED, Tier 1.
##
## Run:
##   nim c -r <tui lane flags> src/frontend/tui/tests/test_plat36_source_command.nim
##
## PLAT-36 built the importer (`viewmodel/keymap/vim_import`) and graded it at
## the value level; no key the shipped terminal accepted put a buffer under an
## imported configuration. `:source <file>` (Edit mode) now does. This suite
## asserts, without a terminal:
##
##   * `DIFF-5` THROUGH THE RUNTIME: a translated mapping, typed into a buffer
##     under the `:source`d configuration, produces the document its
##     right-hand side produces under the hand-written Vim keymap — for a
##     single-operation right-hand side and for a multi-operation one (the
##     macro path, which only works if the import's macros are installed);
##   * §6.3's report on the status line: the count, and the first untranslated
##     line with its reason from the closed set;
##   * the import follows the SESSION: a file opened after `:source` is under
##     it, and `:keymap vim` afterwards returns to the shipped keymap and takes
##     the import's macros with it;
##   * refusals by name: no argument, a missing file, a file over the ceiling;
##   * where a spelled path resolves (`~`, absolute, project-relative).
##
## NO MOCKS. The configuration files are real files in a real temporary
## directory, and `rt.editServices.readConfig` is wired to the shipped reader
## (`host/edit_host.readUserConfigFile`) exactly as `main.wireEditServices`
## wires it — the closure is the seam `app/` is given because it may not touch
## a file, not a stand-in for one.

import std/[os, strutils, tables, tempfiles, unittest]

import codetracer_embed
import ../app/edit_binding
import ../app/runtime
import ../app/theme/capabilities
import ../host/edit_host
import ../host/native_host

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 120
  Rows = 40
  FileA = "src/alpha.nim"
  TextA = "first line\nsecond line\nthird line\nfourth line\n"
  SingleOpRc = "nnoremap Q D\n"
    ## One operation on the right (delete to the end of the line) — a row of
    ## `DIFF-5`'s own table. `dd` would NOT do: it is `begin-operator` plus a
    ## motion, and §6.4 reports such a right-hand side rather than binding it.
  MacroRc = "nnoremap Z jJ\n"
    ## Two operations on the right — the `replay-macro` path, also a `DIFF-5`
    ## row.
  AfterQ = "\nsecond line\nthird line\nfourth line\n"
  VimscriptLine = "nnoremap <leader>f :call Foo()<CR>"

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc editingRuntime(root: string): TuiRuntime =
  let app = newTuiApp()
  app.modes = initModeRegister(pmEdit)
  app.editSession = newEditSession()
  discard app.editSession.openFile(FileA, TextA)
  result = newTuiRuntime(app, caps(), Cols, Rows)
  result.editServices.readConfig = proc(spelled: string): EditReadResult =
    try:
      EditReadResult(ok: true, text: readUserConfigFile(root, spelled))
    except TuiHostError as e:
      EditReadResult(ok: false, message: e.msg)

proc runPrompt(rt: TuiRuntime; line: string) =
  ## The prompt opened and typed as `test_plat43_keymap_selector.nim` does,
  ## then submitted with a real `Enter` token.
  discard rt.prompt.open(pkCommand)
  for ch in line:
    discard rt.prompt.applyKey($ch, @[])
  discard rt.handleToken("\r", 0)

proc typed(buf: EditBuffer; keys: openArray[string]): string =
  var now = 0'i64
  for k in keys:
    now += 1
    discard buf.applyEditKey(k, now)
  buf.text

proc underPlainVim(text: string; keys: openArray[string]): string =
  ## The same keystrokes' answer under the HAND-WRITTEN Vim keymap — a session
  ## constructed with `kmVim` and never `:source`d.
  let s = newEditSession(kmVim)
  discard s.openFile("doc", text)
  s.activeBuffer().typed(keys)

proc withRc(body: string): string =
  ## A project directory holding `vimrc` with `body`; returns the directory.
  result = createTempDir("plat36-source-", "")
  writeFile(result / "vimrc", body)

suite "PLAT-36: `:source` installs a translated mapping, and it does what Vim's keys do":

  test "a single-operation mapping: `Q` under the import is `D` under Vim":
    let root = withRc(SingleOpRc)
    defer: removeDir(root)
    let rt = editingRuntime(root)
    rt.runPrompt(":source vimrc")
    checkpoint(rt.app.notification)
    ck rt.app.notification == "sourced vimrc: 1 of 1 mapping line(s) translated"
    let buf = rt.app.editSession.activeBuffer()
    ck buf.doc.model == kmVim
    ck not buf.doc.imported.isNil
    ck rt.keymapModel == kmVim
    let viaImport = buf.typed(["Q"])
    let viaVim = underPlainVim(TextA, ["D"])
    ck viaImport == viaVim
    ck viaImport != TextA
    ck viaImport == AfterQ

  test "a multi-operation mapping replays through the macros the import installed":
    let root = withRc(MacroRc)
    defer: removeDir(root)
    let rt = editingRuntime(root)
    rt.runPrompt(":source vimrc")
    checkpoint(rt.app.notification)
    ck rt.app.notification.contains("1 of 1 mapping line(s) translated")
    let buf = rt.app.editSession.activeBuffer()
    # The macro path is what this case is about, so it asserts it IS one.
    ck buf.doc.imported.macros.len == 1
    for id in buf.doc.imported.macros.keys:
      ck buf.doc.state.macros.hasKey(id)
    let viaImport = buf.typed(["Z", "Z"])
    let viaVim = underPlainVim(TextA, ["j", "J", "j", "J"])
    ck viaImport == viaVim
    ck viaImport != TextA

  test "an untranslatable line is REPORTED on the status line, with its reason":
    let root = withRc(SingleOpRc & VimscriptLine & "\n")
    defer: removeDir(root)
    let rt = editingRuntime(root)
    rt.runPrompt(":source vimrc")
    checkpoint(rt.app.notification)
    ck rt.app.notification ==
      "sourced vimrc: 1 of 2 mapping line(s) translated; 1 not translated, " &
      "first at line 2: " & $irVimscript
    # The translated half is still installed: a partial import that reports
    # is §6.3's useful product.
    ck rt.app.editSession.activeBuffer().typed(["Q"]) == AfterQ

suite "PLAT-36: the import follows the session":

  test "a file opened after `:source` is opened under it":
    let root = withRc(SingleOpRc)
    defer: removeDir(root)
    let rt = editingRuntime(root)
    rt.runPrompt(":source vimrc")
    let idx = rt.app.editSession.openFile("src/beta.nim", "one\ntwo\n")
    let beta = rt.app.editSession.buffers[idx]
    ck beta.doc.model == kmVim
    ck not beta.doc.imported.isNil
    ck beta.typed(["Q"]) == "\ntwo\n"

  test "`:keymap` alone names the sourced file":
    let root = withRc(SingleOpRc)
    defer: removeDir(root)
    let rt = editingRuntime(root)
    rt.runPrompt(":source vimrc")
    rt.runPrompt(":keymap")
    ck rt.app.notification.startsWith("keymap vim with vimrc sourced; ")

  test "`:keymap vim` afterwards is the SHIPPED keymap, macros and all":
    let root = withRc(MacroRc)
    defer: removeDir(root)
    let rt = editingRuntime(root)
    rt.runPrompt(":source vimrc")
    let buf = rt.app.editSession.activeBuffer()
    var ids: seq[string] = @[]
    for id in buf.doc.imported.macros.keys: ids.add id
    ck ids.len == 1
    rt.runPrompt(":keymap vim")
    ck buf.doc.imported.isNil
    ck rt.app.editSession.imported.isNil
    for id in ids:
      ck not buf.doc.state.macros.hasKey(id)
    # `Z` is Vim's own prefix (`ZZ`, `ZQ`), so under the shipped keymap one
    # `Z` changes nothing — the mapping is gone, not shadowed.
    ck buf.typed(["Z"]) == TextA

suite "PLAT-36: `:source` refuses by name":

  test "no argument, a missing file, a file over the ceiling":
    let root = withRc(SingleOpRc)
    defer: removeDir(root)
    let rt = editingRuntime(root)
    rt.runPrompt(":source")
    ck rt.app.notification == ":source needs a file, e.g. ':source ~/.vimrc'"
    rt.runPrompt(":source nope.vim")
    ck rt.app.notification == "nope.vim: no such file"
    ck rt.app.editSession.activeBuffer().doc.model == kmProductDefault
    writeFile(root / "huge.vim", "\" x\n".repeat(MaxConfigFileBytes div 4 + 1))
    rt.runPrompt(":source huge.vim")
    checkpoint(rt.app.notification)
    ck rt.app.notification.startsWith("huge.vim: is ")
    ck rt.app.notification.contains("the ceiling is 1024 KiB")
    ck rt.app.editSession.imported.isNil

  test "a session with no host reader says so":
    let rt = editingRuntime(getTempDir())
    rt.editServices.readConfig = nil
    rt.runPrompt(":source ~/.vimrc")
    ck rt.app.notification == ":source has no reader in this session"

suite "PLAT-36: where a spelled path resolves":

  test "`~`, absolute, and project-relative":
    let root = "/work/project"
    ck resolveConfigPath(root, "~/.vimrc") == getHomeDir() / ".vimrc"
    ck resolveConfigPath(root, "/etc/vim/vimrc") == "/etc/vim/vimrc"
    ck resolveConfigPath(root, "cfg/init.vim") == "/work/project/cfg/init.vim"
    ck resolveConfigPath(root, "../x.vim") == "/work/x.vim"

suite "PLAT-36 :source — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
