## test_project_definitions_pty.nim — Tier 2: the shipped `codetracer-tui`,
## in a real pty, opening a recording whose checkout carries a `.codetracer/`.
##
## A user-visible feature asserted on the user's screen. The binary is started
## the way a user starts it — in the checkout, on the recording — and its
## bytes are parsed by libvterm (TermAssert):
##
##   (What the panes draw from the definitions is asserted, stop by stop, by
##   `../test_project_definitions_session.nim` over the same program.)
##
##   * `:project` puts what the checkout declared on the screen: the point
##     collection and what each point resolved to, the visualiser rule, and
##     the code the project ships that was NOT run;
##   * `:project review` shows the trust disclosure — the file, the checkout,
##     the digest — and `:project grant` grants it.
##
## No mocks: the binary, a real `ct record` of a real Python program in a
## scratch checkout, a real `replay-server`, a real pty. Waits are on the
## SCREEN's state with generous ceilings, never on a fixed delay.

import std/[monotimes, options, os, osproc, strutils, times, unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../../../common/project_wasm_fixtures

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 7

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 180
  Rows = 56

const Points = """
schema = "codetracer.points.v1"

[[collection]]
name = "hot path"
enabled = true

[[collection.point]]
kind = "breakpoint"
path = "main.py"
anchor = "total = m[0] * k"

[[collection.point]]
kind = "tracepoint"
path = "main.py"
anchor = "this line is not in the program"
expression = "x"
"""

const Visualisers = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Tuple"
summary = "a pair"
"""

proc rowOf(sess: var TuiTestSession; row: int): string =
  sess.regionText(row, 0, Cols, 1).split('\n')[0]

proc screen(sess: var TuiTestSession): seq[string] =
  discard sess.drainOutput(60)
  for r in 0 ..< Rows:
    result.add sess.rowOf(r)

proc waitScreen(sess: var TuiTestSession; needle: string;
                timeoutMs = 120000): seq[string] =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.screen()
    if needle in result.join("\n"):
      return
    if not sess.isAlive:
      break
    sleep(50)
  raise newException(AssertionFailedError,
    "'" & needle & "' never appeared; screen:\n" & result.join("\n"))

suite "project definitions on a real terminal":

  test ":project, the visualised value, the trust disclosure and the grant":
    let prereq = resolveFixture(pythonScriptSpec("project_definitions"))
    if prereq.outcome == foMissingPrereq:
      let message = missingPrereqMessage(prereq.spec, prereq.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      skip()
    else:
      let base = getTempDir() / ("ct-projdefs-pty-" & $getCurrentProcessId())
      removeDir(base)
      let checkout = base / "checkout"
      createDir(checkout / ".codetracer")
      copyFile(lifecycle_support.repoRoot() /
               "test-programs/project_definitions/main.py",
               checkout / "main.py")
      writeFile(checkout / ".codetracer/points.toml", Points)
      writeFile(checkout / ".codetracer/visualisers.toml", Visualisers)
      writeFile(checkout / ".codetracer/visualisers.wasm", echoLengthModule())
      let rec = base / "rec"
      let (output, code) = execCmdEx(
        quoteShell(fixture_provider.findCtBinary()) & " record -o " &
        quoteShell(rec) & " " & quoteShell(checkout / "main.py"))
      checkpoint("ct record: " & output)
      doAssert code == 0, output
      var trace = rec
      if not isUsableTraceDir(rec):
        for kind, p in walkDir(rec):
          if kind == pcDir and isUsableTraceDir(p): trace = p
      let state = base / "state"
      createDir(state)
      var sess = newTuiTest(tuiBinary(), @["--theme=dark", trace])
        .width(Cols).height(Rows).transcript()
        .workDir(checkout)
        .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
                   "STY", "NERD_FONT", "NERDFONT", "COLORFGBG")
        .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
        .envSet("COLORTERM", "truecolor")
        .envSet("XDG_STATE_HOME", state)
        .envSet("CODETRACER_HOME", state / "ct-home")
        .envSet("CODETRACER_USER_ROOT", state / "user-root")
        .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
        .carryRunMark()
        .spawn()
      settleOnDebugger(sess, Cols, Rows)

      # `:project` — what the checkout declared, on the screen.
      sess.send(":project\r")
      var s = sess.waitScreen("PROJECT DEFINITIONS")
      let shown = s.join("\n")
      ck "collection 'hot path'" in shown
      ck "1 visualiser rule(s)" in shown
      ck "not run: .codetracer/visualisers.wasm" in shown
      sess.send("\x1b")

      # `:project review` — the disclosure, derived from the grant.
      sess.send(":project review\r")
      s = sess.waitScreen("You are being asked to trust")
      ck "visualisers.wasm" in s.join("\n")
      ck "sha256:" in s.join("\n")
      sess.send("\x1b")

      # `:project grant` — granted, and said so on the status line.
      sess.send(":project grant\r")
      s = sess.waitScreen("granted .codetracer/visualisers.wasm")
      ck "granted .codetracer/visualisers.wasm" in s[^1]

      sess.send(":quit\r")
      ck sess.waitExit(initDuration(seconds = 60)).isSome
      sess.close()
      removeDir(base)
