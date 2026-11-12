## test_terminal_diagnostics_pty.nim — two defects the real-emulator lane
## found in what the terminal front-end reports (CodeTracer-TUI-Terminal-
## Adaptation.md §4.5, §4.6, §10.1), on a real pty:
##
##   * `--capabilities` (what `ct doctor terminal` runs) waits for a terminal
##     that answers LATE: a terminal answering 300 ms after the round is
##     reported from its answers (XTVERSION's identity, the measured round
##     trip), where a session's 10 ms bound — still in force when
##     `CT_TUI_PROBE_TIMEOUT_MS` says so — reports it from the environment
##     alone (the control);
##   * inside tmux, the wrapped OSC 22 query is written after the fence, in
##     a write of its own: tmux 3.6a drops a passthrough sequence read
##     together with the pane's switch to the alternate screen;
##   * inside tmux, extended key reporting waits for the outer terminal's
##     answer to the wrapped OSC 22 query: tmux delivers that answer as INPUT,
##     and once the pane has asked for `modifyOtherKeys` it re-encodes the
##     answer's `ESC ]` as Alt+`]` (`CSI 27 ; 3 ; 93 ~`, measured on tmux 3.6a
##     in kitty 0.44.0) and the reply is lost. So no `CSI > 4 ; 2 m` is
##     written before the answer, it is written after it, and the shapes then
##     go through tmux.
##
## ## The stand-ins, and why they are not mocks
##
## The persona peer (`persona_peer`) types the TERMINAL'S half of the round
## with captured answers (kitty 0.44.0; tmux 3.6a in kitty 0.44.0, whose
## wrapped query went unanswered), as PLAT-71's suites do; the outer
## terminal's late OSC 22 answer is typed by the test at the moment it
## chooses, which is the one thing the case is about. A `tmux` script on
## `PATH` prints the one `display -p` line the binary asks tmux for (the
## format `terminal_probe.TmuxFormats` names), so no tmux server's state
## decides the case. The subject — the shipped `codetracer-tui`, its round,
## its key reporting, its pointer shapes — is real and untouched.
##
## Templates, not procs, for anything that calls `check`.

import std/[json, os, posix, strutils, times, unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support
import ./persona_peer

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 14

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 120
  Rows = 40
  ModifyOtherKeysOn = "\x1b[>4;2m"
  WrappedPush = "\x1bPtmux;\x1b\x1b]22;>"

var scratch = getTempDir() / ("ct-diagnostics-" & $getCurrentProcessId())
var runs = 0

proc builder(args: seq[string]; extra: seq[(string, string)] = @[];
             term = "xterm-kitty"): TuiTestBuilder =
  var blocked: seq[string] = @[]
  for v in ["COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE",
            "TMUX", "STY", "ZELLIJ", "KITTY_WINDOW_ID", "VTE_VERSION",
            "SSH_CONNECTION", "SSH_TTY", "CODETRACER_TUI_GLYPHS",
            "CODETRACER_TUI_MODERN_UNICODE", "CODETRACER_TUI_PROBE",
            "CODETRACER_TUI_AMBIGUOUS_WIDTH", "CODETRACER_TUI_COLORS",
            "CODETRACER_TUI_SCREEN_READER", "ACCESSIBLE", "CODETRACER_HOME",
            "CT_TUI_PROBE_TIMEOUT_MS"]:
    var setHere = false
    for (k, _) in extra:
      if k == v: setHere = true
    if not setHere: blocked.add v
  # A state root of its own per run: the per-terminal cache under it must
  # not carry one run's answers into the next.
  inc runs
  let root = scratch / ("s" & $runs)
  removeDir(root)
  createDir(root)
  result = newTuiTest(tuiBinary(), args).width(Cols).height(Rows).transcript()
    .envRemove(blocked)
    .envSet("TERM", term).envSet("LANG", "en_US.UTF-8")
    .envSet("XDG_STATE_HOME", root)
    .envSet("CODETRACER_TUI_LAYOUT_DIR", root / "layout")
    .carryRunMark()
  for (k, v) in extra:
    result = result.envSet(k, v)

proc jsonOf(bytes: string): JsonNode =
  let leave = bytes.rfind("\x1b[?1049l")
  let start = bytes.find('{', max(0, leave))
  let stop = bytes.rfind('}')
  if start < 0 or stop < start:
    raise newException(ValueError, "no JSON report: " &
                       bytes[max(0, bytes.len - 400) .. ^1].escape)
  parseJson(bytes[start .. stop].replace("\r\n", "\n"))

proc reportWith(p: Persona; extra: seq[(string, string)] = @[]): JsonNode =
  var sess = builder(@["--capabilities=json"], extra,
                     term = "xterm-256color").spawn()
  discard sess.serve(p)
  discard sess.waitExit(initDuration(seconds = 30))
  discard sess.drainOutput(100)
  result = jsonOf(sess.transcriptBytes())
  sess.close()

proc pythonSpec(name: string): FixtureSpec =
  FixtureSpec(
    name: name, program: "test-programs/" & name & "/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: "")

proc tmuxStub(passthrough: string): string =
  ## The `tmux` stand-in's directory (see the header).
  result = scratch / ("tmux-" & passthrough)
  createDir(result)
  let stub = result / "tmux"
  writeFile(stub, "#!/bin/sh\nprintf 'RGB\\txterm-kitty\\tkitty(0.44.0)\\t1" &
            "\\t3.6a\\t" & passthrough & "\\ton\\ton\\ton\\ton\\n'\n")
  discard chmod(stub.cstring, 0o755)

suite "what the terminal front-end reports, on a real pty":

  test "the binary exists":
    createDir(scratch)
    ck fileExists(tuiBinary())

  test "--capabilities waits for a terminal that answers after 10 ms":
    let late = slowKitty(300)
    let j = reportWith(late)
    checkpoint($j["identity"])
    ck j["identity"]["value"]["name"].getStr == "kitty"
    ck j["identity"]["from"].getStr != "environment"
    ck j["rttMs"]["value"].getInt >= 300
    ck j["rttMs"]["from"].getStr == "probe"
    # THE CONTROL: the session's bound, set explicitly, reports the same
    # terminal from the environment (here: nothing names it).
    let bounded = reportWith(late, @[("CT_TUI_PROBE_TIMEOUT_MS", "10")])
    checkpoint($bounded["identity"])
    ck bounded["identity"]["value"]["name"].getStr != "kitty"
    ck bounded["rttMs"]["value"].getInt < 300

  test "inside tmux, extended keys wait for the outer terminal's answer":
    let calc = resolveFixture(pythonSpec("calc"))
    ck calc.outcome == foRecorded
    if calc.outcome == foRecorded:
      let stub = tmuxStub("on")
      var sess = builder(@[calc.tracePath],
        @[("TMUX", "/tmp/ct-none,1,0"), ("CT_TUI_PROBE_TIMEOUT_MS", "1500"),
          ("PATH", stub & ":" & getEnv("PATH"))],
        term = "tmux-256color").spawn()
      # tmux in kitty as captured: tmux answers the round; the outer
      # terminal's answer to the wrapped query is the test's to type.
      var tmuxPersona = tmuxInKitty()
      tmuxPersona.pointerReply = ""
      let log = sess.serve(tmuxPersona)
      ck Da1Query in log.queries
      # The fence is answered; the query goes after it, in a write of its own
      # (tmux drops a passthrough read with the alternate-screen switch).
      sleep(300)
      discard sess.drainOutput(100)
      let early = sess.transcriptBytes()
      ck early.contains(WrappedPointerQuery)
      ck early.find(WrappedPointerQuery) > early.find(Da1Query)
      checkpoint("before the answer: " & $early.count(ModifyOtherKeysOn))
      ck not early.contains(ModifyOtherKeysOn)
      # The outer terminal's answer comes through tmux, inside the window.
      sess.send("\x1b]22;1,1,1,1,1,1,1,1,1,1\x1b\\")
      let deadline = epochTime() + 60
      while epochTime() < deadline and
            not sess.transcriptBytes().contains(ModifyOtherKeysOn):
        discard sess.drainOutput(40)
      let bytes = sess.transcriptBytes()
      ck bytes.find(ModifyOtherKeysOn) >= early.len
      settleOnDebugger(sess, Cols, Rows)
      # …and the shapes go through tmux's passthrough.
      sess.sendMouseMove(Rows div 2, 60)
      let shapesBy = epochTime() + 5
      while epochTime() < shapesBy and
            not sess.transcriptBytes().contains(WrappedPush):
        discard sess.drainOutput(40)
      ck sess.transcriptBytes().contains(WrappedPush)
      sess.send("\x11")
      discard sess.waitExit(initDuration(seconds = 20))
      sess.close()

  test "the count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions

removeDir(scratch)
