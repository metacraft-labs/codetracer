## test_plat46_desktop_parity.nim — PLAT-46, desktop parity: for the roles
## both front-ends paint, the TUI's read-back hex equals the desktop's
## COMPUTED CSS colour.
##
## ## The two sides
##
##   * the DESKTOP column is a capture from the Electron lane —
##     `just plat46-capture-electron` runs
##     `src/tests/gui/tests/visual/plat46-token-parity-capture.spec.ts` in the
##     real Electron app on the `calc` recording and writes each role's
##     `getComputedStyle` colour to
##     `src/tests/visual/answers/plat46-token-parity.electron.json`;
##   * the TERMINAL column is read here, off libvterm's cells, from the shipped
##     `codetracer-tui` on the same recording in a real pty, in the Dark mode
##     (the desktop's stylus is generated without a mode, i.e. `$value`, which
##     the generator's module header records is the Dark mode).
##
## Both are generated from one `codetracer-design-system` revision by one
## resolver (`scripts/tokens-to-styl.sh`), and this is where that is checked
## end to end.
##
## ## Where the two front-ends do NOT paint one token, and why that is counted
##
## Some roles the desktop paints are not taken from the design system at all,
## or are taken from a different token than the one PLAT-46 binds for the
## terminal. Each is in `KnownDivergences` with its reason and where it is
## filed; the register's COUNT is asserted, so a new divergence reddens this
## suite until it is filed, and a divergence that closes (the two start to
## agree) reddens it too, so the register cannot outlive its reason.
##
## ## No mocks
##
## Both columns come from real runs. The capture's absence FAILS BY NAME with
## its recipe rather than skipping.

import std/[json, os, strutils, unicode, unittest]

import nim_libvterm
import term_assert

import ../../app/theme/colour_math
import ../../../styles/generated/design_tokens
import ../../testing/dual_snap
import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 14

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 30
    ## Wide enough that the Variables stack's strip spells its inactive tab
    ## and the rightmost strip has bar left over past its label: the shared
    ## default gives every region its minimum first, and at 120 columns the
    ## strips are cut at their labels (PLAT-45).
  TallRows = 40
  CaptureRecipe = "just plat46-capture-electron"
  SharedRoles = ["tab-inactive-fg", "surface-panel", "chrome-text",
                 "syntax-keyword", "syntax-identifier", "surface-editor"]
    ## Every role the capture measures that the two front-ends paint alike.
  KnownDivergences = [
    ("tab-active-bg",
     "PLAT-49 finding 4, the user's direction (2026-10-01): the selected " &
     "tab has a ground of its own (ui/surface/primary/tertiary), overriding " &
     "PLAT-47's measurement of the desktop's single #282828"),
    ("tab-active-fg",
     "PLAT-49 finding 4: the selected tab's text is in the headings tier, " &
     "so it differs from the others by foreground as well as ground"),
    ("tab-inactive-bg",
     "PLAT-49 finding 4: the strip has a ground of its own " &
     "(ui/surface/base/raised), distinct from the pane body"),
    ("surface-canvas",
     "PLAT-49 finding 13: a divider is drawn on its neighbours' own ground " &
     "(the panel surface) with the subtle border foreground, where the " &
     "desktop's splitter shows the layout's darker ground")]
    ## Counted, so a divergence that appears reddens this suite until it is
    ## filed here with its reason, and one that closes reddens it too. PLAT-47
    ## had emptied it; PLAT-49 files the four the user asked for: the tab
    ## strip's own ground and the selected tab's own ground and foreground
    ## (finding 4), and dividers on the panes' ground (finding 13).

proc hexOfColor(c: Color): string =
  if c.kind == ckRgb: hexOf((c.r.int, c.g.int, c.b.int)) else: ""

proc rowOf(sess: var TuiTestSession; needle: string; rows = Rows): int =
  for r in 0 ..< rows:
    if sess.regionText(r, 0, Cols, 1).contains(needle):
      return r
  -1

proc colOf(sess: var TuiTestSession; row: int; needle: string): int =
  let text = sess.regionText(row, 0, Cols, 1)
  let at = text.find(needle)
  if at < 0: return -1
  text[0 ..< at].runeLen

proc lastColBeforeRule(sess: var TuiTestSession; row, fromCol: int): int =
  ## The last body cell of the region `fromCol` is in: the column left of the
  ## first `│` at or right of it, or `Cols - 2` at the screen's edge. Since
  ## PLAT-45 the Variables and Source panes are not the rightmost regions, so
  ## a fixed offset from the edge lands in a neighbour.
  for c in fromCol ..< Cols:
    if $sess.cellAt(row, c).rune == "│":
      return max(fromCol, c - 1)
  Cols - 2

proc terminalColumn(sess: var TuiTestSession): Table[string, string] =
  ## Each shared role's colour as the terminal painted it.
  result = initTable[string, string]()
  let tabs = rowOf(sess, " Variables ")
  if tabs >= 0:
    let active = sess.cellAt(tabs, colOf(sess, tabs, "Variables"))
    # The Variables stack's inactive tab — Scratchpad in the shared default
    # (PLAT-45); the Timeline is a tab of the events stack, on another row.
    let inactive = sess.cellAt(tabs, colOf(sess, tabs, "Scratch"))
    result["tab-active-bg"] = hexOfColor(active.bg)
    result["tab-active-fg"] = hexOfColor(active.fg)
    result["tab-inactive-bg"] = hexOfColor(inactive.bg)
    result["tab-inactive-fg"] = hexOfColor(inactive.fg)
    # THE LAYOUT'S OWN GROUND. The desktop's `.lm_goldenlayout` background
    # (`ui/surface/primary/default`) is what shows between its panels — its
    # splitters; the terminal's splitters are its dividers, painted on the
    # same ground (PLAT-47), read here at the divider left of the Variables
    # stack.
    let divider = colOf(sess, tabs, "Variables") - 2
    if divider >= 0:
      result["surface-canvas"] = hexOfColor(sess.cellAt(tabs, divider).bg)
  let varRow = rowOf(sess, " Variables ")
  if varRow >= 0:
    result["surface-panel"] = hexOfColor(sess.cellAt(varRow + 2,
      lastColBeforeRule(sess, varRow + 2, colOf(sess, varRow, " Variables "))).bg)
  let srcRow = rowOf(sess, "   3 ")
  if srcRow >= 0:
    result["surface-editor"] = hexOfColor(
      sess.cellAt(srcRow,
        lastColBeforeRule(sess, srcRow, colOf(sess, srcRow, "   3 "))).bg)
  # `ui/text/primary/body` on a pane body: the call stack's frame name.
  let frameRow = rowOf(sess, "<__main__>")
  if frameRow >= 0:
    result["chrome-text"] = hexOfColor(
      sess.cellAt(frameRow, colOf(sess, frameRow, "<__main__>") + 1).fg)

suite "PLAT-46: the terminal and the desktop paint one design system":

  test "the shared roles agree; the divergences are the registered ones":
    let answers = lifecycle_support.repoRoot() / "src" / "tests" / "visual" /
                  "answers" / "plat46-token-parity.electron.json"
    if not fileExists(answers):
      checkpoint("missing " & answers & " — run `" & CaptureRecipe & "`")
    ck fileExists(answers)
    let desktop = parseFile(answers)["colours"]
    let resolved = resolveFixture("calc")
    ck resolved.outcome == foRecorded

    var sess = newTuiTest(tuiBinary(), @["--theme=dark", resolved.tracePath])
      .width(Cols).height(Rows)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
                 "COLORFGBG")
      .envSet("TERM", "xterm-256color").envSet("COLORTERM", "truecolor")
      .envSet("LANG", "en_US.UTF-8").envSet("CT_TUI_PROBE_TIMEOUT_MS", "200")
      .spawn()
    settleOnDebugger(sess, Cols, Rows)
    var terminal = terminalColumn(sess)
    sess.send("q")
    discard sess.waitExit(initDuration(seconds = 15))
    sess.close()
    # THE EDITOR'S SYNTAX needs a taller screen: `def add` is line 29.
    var tall = newTuiTest(tuiBinary(), @["--theme=dark", resolved.tracePath])
      .width(Cols).height(TallRows)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
                 "COLORFGBG")
      .envSet("TERM", "xterm-256color").envSet("COLORTERM", "truecolor")
      .envSet("LANG", "en_US.UTF-8").envSet("CT_TUI_PROBE_TIMEOUT_MS", "200")
      .spawn()
    settleOnDebugger(tall, Cols, TallRows)
    let defRow = rowOf(tall, "def add", TallRows)
    if defRow >= 0:
      terminal["syntax-keyword"] = hexOfColor(
        tall.cellAt(defRow, colOf(tall, defRow, "def add")).fg)
      # The function's name: an identifier, the default token colour.
      terminal["syntax-identifier"] = hexOfColor(
        tall.cellAt(defRow, colOf(tall, defRow, "def add") + 4).fg)
    tall.send("q")
    discard tall.waitExit(initDuration(seconds = 15))
    tall.close()
    checkpoint("terminal: " & $terminal)
    checkpoint("desktop:  " & $desktop)

    var agreed = 0
    for role in SharedRoles:
      let d = desktop{role}.getStr("")
      let t = terminal.getOrDefault(role, "")
      if d != t:
        checkpoint("PARITY BROKEN for " & role & ": desktop " & d &
                   ", terminal " & t)
      ck d.len == 7 and d == t
      if d == t: inc agreed
    ck agreed == SharedRoles.len

    var diverged = 0
    for (role, why) in KnownDivergences:
      let d = desktop{role}.getStr("")
      let t = terminal.getOrDefault(role, "")
      checkpoint("divergence " & role & ": desktop " & d & ", terminal " & t &
                 " — " & why)
      # STILL A DIVERGENCE: a register entry whose two sides now agree is an
      # entry to delete, not to keep.
      ck d.len == 7 and t.len == 7 and d != t
      if d != t: inc diverged
    ck diverged == KnownDivergences.len

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
