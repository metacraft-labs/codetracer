## test_files_menu_pty.nim — K19, Tier 2: the Files pane's menu in a REAL
## terminal, acting on REAL files.
##
## codetracer-pm `spec/GUI/Core-Panes/Filesystem-Pane.md` § "Context menu":
## a row of the tree opens Create, Rename, Delete and Edit. In Edit mode
## (`ct edit --ui=tui <folder>`, which hands off to `codetracer-tui --edit
## <folder>`) the opened folder's entries act on the disk; the terminal has
## no inline name field, so a name is typed on the command line, and Delete
## asks first.
##
## The shipped binary in a real pty (TermAssert + libvterm), on a project
## directory this suite builds under the system's temporary directory, driven
## by the bytes a terminal sends — SGR-1006 presses, `Down`, `Shift+F10`,
## `Enter`, `Escape`, typed characters — and every claim about a file is read
## back from the disk:
##
##   * a right-click on a row opens the four entries, none disabled;
##   * Create: the line opens with `create ` typed; a name creates the empty
##     file on disk, the pane lists it and the editor opens it;
##   * from the keyboard: a press on a row gives the pane the focus, `Down`
##     moves the selection, `Shift+F10` (CUA's `context-menu.open`) opens the
##     selected row's menu, `Down` / `Enter` choose Rename; the name typed
##     renames the file on disk;
##   * Delete asks first: `Escape` keeps the file; `Enter` moves it into the
##     trash — `$XDG_DATA_HOME/Trash`, here a directory inside the project
##     suite's own temporary directory, never the user's.
##
## No mocks: the compiled binary, a real pty, a real terminal state machine,
## real files.

import std/[monotimes, os, strutils, tempfiles, times, unittest]

import term_assert

import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 28

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 140
  Rows = 40
  StatusRow = Rows - 1
  RightButton = 2
  ShiftF10 = "\x1b[21;2~"
    ## Shift+F10: `CSI 21 ; 2 ~` (F10's code 21, modifier 1 + Shift).
  QuitByte = "\x11"
    ## Ctrl+Q, the CUA base's quit.

type Paths = object
  root, project, xdg, state: string

proc layout(): Paths =
  ## The project — `notes.txt`, `src/main.py` — and, beside it, the data and
  ## state directories the binary is pointed at.
  result.root = createTempDir("ct-files-menu-pty-", "")
  result.project = result.root / "proj"
  result.xdg = result.root / "xdg-data"
  result.state = result.root / "state"
  createDir(result.project / "src")
  createDir(result.state)
  writeFile(result.project / "notes.txt", "notes\n")
  writeFile(result.project / "src" / "main.py", "print(1)\n")

proc spawnEditor(p: Paths): TuiTestSession =
  newTuiTest(tuiBinary(), @["--edit", p.project])
    .width(Cols).height(Rows)
    .transcript()
    .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE",
               "TMUX", "STY")
    .envSet("TERM", "xterm-256color")
    .envSet("LANG", "en_US.UTF-8")
    .envSet("XDG_DATA_HOME", p.xdg)
    .envSet("XDG_STATE_HOME", p.state)
    .envSet("CODETRACER_HOME", p.state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", p.state / "layout")
    .spawn()

proc screen(sess: var TuiTestSession): seq[string] =
  discard sess.drainOutput(60)
  sess.screenContents().split('\n')

proc findRow(rows: seq[string]; needle: string; fromRow = 0): (int, int) =
  for r in fromRow ..< rows.len:
    let c = rows[r].find(needle)
    if c >= 0:
      return (r, rows[r][0 ..< c].len)
  (-1, -1)

proc waitFor(sess: var TuiTestSession; needle: string; present = true;
             timeoutMs = 20000; fromRow = 0): (int, int) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var rows: seq[string] = @[]
  while getMonoTime() < deadline:
    rows = sess.screen()
    let at = rows.findRow(needle, fromRow)
    if (at[0] >= 0) == present:
      return at
    if not sess.isAlive:
      break
    sleep(40)
  raise newException(AssertionFailedError,
    (if present: "never showed '" else: "kept showing '") & needle &
    "'; screen:\n" & rows.join("\n"))

proc waitUntil(cond: proc(): bool; timeoutMs = 20000): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    if cond(): return true
    sleep(40)
  false

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc press(sess: var TuiTestSession; row, col: int; code = 0) =
  sess.mouse(code, row, col)
  sess.mouse(code, row, col, release = true)

proc filesRow(sess: var TuiTestSession; name: string): (int, int) =
  ## A file's row in the Files pane (the pane is at the left: the first
  ## occurrence in the left half of the screen, below the tab strip).
  let deadline = getMonoTime() + initDuration(milliseconds = 20000)
  while getMonoTime() < deadline:
    let rows = sess.screen()
    for r in 2 ..< Rows - 1:
      let c = rows[r].find(name)
      if c >= 0 and rows[r][0 ..< c].len < Cols div 2:
        return (r, rows[r][0 ..< c].len)
    sleep(40)
  raise newException(AssertionFailedError, "no Files row for " & name)

proc quit(sess: var TuiTestSession) =
  sess.send(QuitByte)
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

suite "K19 on a real terminal: Edit mode's Files menu acts on the disk":

  test "the binary exists":
    checkpoint("binary: " & tuiBinary())
    ck fileExists(tuiBinary())

  test "a right-click opens the four entries; Create makes a file and opens it":
    let p = layout()
    var sess = spawnEditor(p)
    try:
      discard sess.waitFor("[EDIT]")
      let (rn, cn) = sess.filesRow("notes.txt")
      sess.press(rn, cn + 1, RightButton)
      let (rc, cc) = sess.waitFor("Create", fromRow = rn)
      var rows = sess.screen()
      ck rows[rc + 1].contains("Rename")
      ck rows[rc + 2].contains("Delete")
      ck rows[rc + 3].contains("Edit")
      # Nothing is disabled on a file of the opened folder: no reason is
      # drawn beside any entry.
      for r in rc .. rc + 3:
        ck not rows[r].contains("read-only")
        ck not rows[r].contains("cannot")
      sess.press(rc, cc + 1)
      discard sess.waitFor(":create ")
      ck sess.waitFor("New file in proj")[0] == StatusRow
      sess.send("fresh.txt")
      discard sess.waitFor(":create fresh.txt")
      sess.sendKey("enter")
      discard sess.waitFor("created fresh.txt")
      ck fileExists(p.project / "fresh.txt")
      ck readFile(p.project / "fresh.txt") == ""
      # Listed, and the file the editor holds (the pane's open marker).
      ck sess.filesRow("•fresh.txt")[0] > 0
    finally:
      sess.quit()
    removeDir(p.root)

  test "from the keyboard: Down, Shift+F10, Rename renames the file on disk":
    let p = layout()
    var sess = spawnEditor(p)
    try:
      discard sess.waitFor("[EDIT]")
      # A press on the first row gives the Files pane the focus.
      let (rn, cn) = sess.filesRow("notes.txt")
      sess.press(rn, cn + 1)
      discard sess.waitFor("editing notes.txt")
      # `src/main.py` is listed below it; Down selects it.
      sess.sendKey("down")
      sleep(200)
      sess.send(ShiftF10)
      let (rc, _) = sess.waitFor("Create", fromRow = 2)
      ck sess.screen()[rc + 1].contains("Rename")
      sess.sendKey("down")
      sess.sendKey("enter")
      discard sess.waitFor(":rename main.py")
      ck sess.screen()[StatusRow].contains("Rename main.py")
      for _ in 0 ..< "main.py".len:
        sess.sendKey("backspace")
      sess.send("app.py")
      discard sess.waitFor(":rename app.py")
      sess.sendKey("enter")
      discard sess.waitFor("renamed src/main.py to app.py")
      ck not fileExists(p.project / "src" / "main.py")
      ck readFile(p.project / "src" / "app.py") == "print(1)\n"
      ck sess.filesRow("src/app.py")[0] > 0
    finally:
      sess.quit()
    removeDir(p.root)

  test "Delete asks first: Escape keeps the file, Enter moves it to the trash":
    let p = layout()
    var sess = spawnEditor(p)
    try:
      discard sess.waitFor("[EDIT]")
      proc chooseDelete(sess: var TuiTestSession) =
        let (rn, cn) = sess.filesRow("notes.txt")
        sess.press(rn, cn + 1, RightButton)
        let (rc, _) = sess.waitFor("Create", fromRow = rn)
        let rows = sess.screen()
        let cd = rows[rc + 2].find("Delete")
        sess.press(rc + 2, rows[rc + 2][0 ..< cd].len + 1)
      sess.chooseDelete()
      discard sess.waitFor(":trash notes.txt")
      ck sess.screen()[StatusRow].contains("Move \"notes.txt\" to the trash?")
      sess.sendKey("escape")
      discard sess.waitFor("kept notes.txt")
      ck fileExists(p.project / "notes.txt")
      ck not dirExists(p.xdg / "Trash" / "files") or
        not fileExists(p.xdg / "Trash" / "files" / "notes.txt")
      sess.chooseDelete()
      discard sess.waitFor(":trash notes.txt")
      sess.sendKey("enter")
      discard sess.waitFor("moved notes.txt to the trash")
      ck not fileExists(p.project / "notes.txt")
      ck readFile(p.xdg / "Trash" / "files" / "notes.txt") == "notes\n"
      ck readFile(p.xdg / "Trash" / "info" / "notes.txt.trashinfo").contains(
        "Path=" & (p.project / "notes.txt"))
      # The pane no longer lists it (its rows: the left half, above the
      # status line).
      ck waitUntil(proc(): bool =
        let rows = sess.screen()
        for r in 2 ..< Rows - 1:
          let c = rows[r].find("notes.txt")
          if c >= 0 and rows[r][0 ..< c].len < Cols div 2:
            return false
        true)
    finally:
      sess.quit()
    removeDir(p.root)

suite "K19 on a real terminal: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
