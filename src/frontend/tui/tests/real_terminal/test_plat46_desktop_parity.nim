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
const ExpectedAssertions = 13

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 120
  Rows = 30
    ## The Compact profile, so a tab stack is on screen for the tab roles.
  TallRows = 40
  CaptureRecipe = "just plat46-capture-electron"
  SharedRoles = ["tab-active-bg", "tab-active-fg", "tab-inactive-fg",
                 "surface-canvas", "surface-panel", "chrome-text"]
    ## Roles both front-ends paint with ONE token.
  KnownDivergences: array[3, (string, string)] = [
    ("syntax-keyword",
     "the desktop's Monaco syntax theme (`src/public/third_party/monaco-themes/" &
     "themes/customThemes/json/codetracerDark.json`) is hand-written, not " &
     "generated from `colors/editor/syntax/*` — codetracer-specs/issues/" &
     "2026-09-26-desktop-editor-syntax-not-from-design-tokens.md"),
    ("surface-editor",
     "the desktop's editor background is transparent over the pane " &
     "(`ui/surface/base/panel`); the terminal paints " &
     "`editor/surface/primary`, which PLAT-46 names for the editor — " &
     "recorded in codetracer-design-system docs/DESIGN-DIVERGENCES.md"),
    ("tab-inactive-bg",
     "the desktop's inactive GoldenLayout tab resolves to the panel surface; " &
     "the terminal puts inactive tabs on the strip's own " &
     "`ui/surface/primary/default` so the active tab is distinguished by " &
     "surface (PLAT-46 deliverable 4) — recorded in DESIGN-DIVERGENCES.md")]

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

proc terminalColumn(sess: var TuiTestSession): Table[string, string] =
  ## Each shared role's colour as the terminal painted it.
  result = initTable[string, string]()
  let tabs = rowOf(sess, "[Variables]")
  if tabs >= 0:
    let active = sess.cellAt(tabs, colOf(sess, tabs, "Variables"))
    let inactive = sess.cellAt(tabs, colOf(sess, tabs, "Timeline"))
    result["tab-active-bg"] = hexOfColor(active.bg)
    result["tab-active-fg"] = hexOfColor(active.fg)
    result["tab-inactive-bg"] = hexOfColor(inactive.bg)
    result["tab-inactive-fg"] = hexOfColor(inactive.fg)
    # THE LAYOUT'S OWN GROUND. The desktop's `.lm_goldenlayout` background
    # (`ui/surface/primary/default`) is what shows through its tab strip; the
    # terminal paints its strip with the same token (`srTabBar`), read here
    # past the last tab.
    result["surface-canvas"] = hexOfColor(sess.cellAt(tabs, Cols - 3).bg)
  let varRow = rowOf(sess, "VARIABLES")
  if varRow >= 0:
    result["surface-panel"] = hexOfColor(sess.cellAt(varRow + 2, Cols - 2).bg)
  let srcRow = rowOf(sess, "   3 ")
  if srcRow >= 0:
    result["surface-editor"] = hexOfColor(
      sess.cellAt(srcRow, colOf(sess, srcRow, "   3 ") + 30).bg)
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
