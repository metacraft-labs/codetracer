## test_plat71_terminal_pty.nim — PLAT-71, Tier 2. The shipped binary adapts
## to the terminal it runs in, read off a REAL pty
## (CodeTracer-TUI-Terminal-Adaptation.md §13.2).
##
## The subject is `build/bin/codetracer-tui`, spawned on a real pty under
## TermAssert; the pty's other end is a PERSONA PEER (`persona_peer.nim`)
## that answers the binary's start-up round as one terminal would. Cases:
##
##   * the profile (`--capabilities=json`) per persona — kitty, foot, a VTE
##     set to ambiguous WIDE, xterm, the Linux console (whose round is
##     restricted to the width probe and the fence), a silent terminal —
##     identity, tier, widths, synchronized output and grapheme mode with the
##     source of each, and `modern-unicode`: off by default, on under `auto`
##     only where the terminal draws the range itself (TA-9);
##   * TA-3 — nothing the probe writes is visible after the debugger's frame,
##     answered and silent;
##   * TA-4 — keys typed while the round waits reach the key journal in order;
##   * TA-10 — every mode set is reset on a normal exit, on SIGTERM, on
##     SIGHUP and on a crash (SIGSEGV): DEC 2027 (set by the binary on a
##     terminal that recognised it), 2026, 1003; on a stop (SIGTSTP) they are
##     reset and the alternate screen left BEFORE the stop, and taken again
##     after it, with a whole frame painted — the pty's session is the
##     binary's own, so the kernel discards the stop itself (an orphaned
##     group) and the continue follows at once; `nim-termctl`'s own suite
##     stops and continues a real job;
##   * §6.5 / §6.6 on `test-programs/grapheme_text` (a decomposed accent, an
##     em dash and an ellipsis — East Asian Width `A` — and a ZWJ emoji
##     sequence in the program's own text): the combining mark and the
##     joiner are written with the cell before them and the screen holds the
##     accent; a cell whose width the terminal left unmeasured is followed by
##     `CSI <col> G` (the ellipsis on a silent terminal, the joined sequence
##     on xterm, which sums ZWJ sequences), and none is on foot, which
##     measured everything;
##   * TA-11 — a silent terminal costs frame 0 no more than the round's bound;
##   * TA-12 — the per-terminal cache gives a silent session the last
##     answers, and a live answer replaces them;
##   * TA-14 — with a REAL tmux behind `TMUX`, the facts come from one
##     `tmux display -p` and no passthrough (`DCS tmux;`) is ever written;
##   * a slow link (answers 300 ms late) is measured and makes the session
##     link-conservative (§4.6);
##   * §4.3's F3 rule on the real framer: after the round a `CSI 1 ; 5 R` is
##     a key (Ctrl+F3), journalled as one.
##
## ## The one stand-in, and why it is not a mock
##
## The persona peer types the TERMINAL'S half of the start-up round. The
## subject — the binary, its round, its framer, its resolver, its repaint,
## its restore — is real and untouched; the peer stands in for the terminal
## emulator because fifteen emulators cannot run in CI. Its answers are
## WRITTEN FROM each terminal's documentation (§3.2), not yet captured from
## the real emulators (PLAT-71 Part E, owed); each persona says so. The tmux
## case needs no stand-in for tmux: a real tmux server answers `display -p`.
##
## ## No skips
##
## A missing binary, fixture or `tmux` FAILS by name with the recipe.
##
## Templates, not procs, for anything that calls `check`.

import std/[json, monotimes, os, osproc, posix, strutils, tables, times,
            unicode, unittest]

import isonim_tui
import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support
import ./persona_peer

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 120

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 120
  Rows = 40
  ProbeGlyphs = ["\u{1FB87}", "中", "\u{1F469}"]
    ## What the width probe prints and this front-end never draws itself:
    ## none may survive on the screen (TA-3). (`⏮`, the fourth probe, is
    ## also the `unicode` icons' jump-to-start control, so it is not proof.)
  QueryTexts = ["[>q", "[>c", "2026$p", "2027$p", "[6n"]

var stateRoot = getTempDir() / ("plat71-state-" & $getCurrentProcessId())

proc freshState(tag: string): string =
  ## A state root of its own per case: the cache and the remembered settings
  ## are files under it.
  result = stateRoot / tag
  removeDir(result)
  createDir(result)

proc builder(args: seq[string]; term = "xterm-256color"; state = "";
             probeMs = 1500; extra: seq[(string, string)] = @[]):
    TuiTestBuilder =
  # BLOCKED OR SET, NEVER BOTH (`lifecycle_support.tuiSession`'s rule): a
  # variable a case sets is not also removed.
  var blocked: seq[string] = @[]
  for v in ["COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE",
            "TMUX", "STY", "ZELLIJ", "KITTY_WINDOW_ID", "VTE_VERSION",
            "SSH_CONNECTION", "SSH_TTY", "CODETRACER_TUI_GLYPHS",
            "CODETRACER_TUI_MODERN_UNICODE", "CODETRACER_TUI_PROBE",
            "CODETRACER_TUI_AMBIGUOUS_WIDTH", "CODETRACER_TUI_COLORS",
            "CODETRACER_HOME"]:
    var setHere = false
    for (k, _) in extra:
      if k == v: setHere = true
    if not setHere: blocked.add v
  result = newTuiTest(tuiBinary(), args).width(Cols).height(Rows).transcript()
    .envRemove(blocked)
    .envSet("TERM", term).envSet("LANG", "en_US.UTF-8")
    .envSet("CT_TUI_PROBE_TIMEOUT_MS", $probeMs)
    .carryRunMark()
  let root = if state.len > 0: state else: freshState("default")
  result = result.envSet("XDG_STATE_HOME", root)
    .envSet("CODETRACER_TUI_LAYOUT_DIR", root / "layout")
  for (k, v) in extra:
    result = result.envSet(k, v)

proc jsonOf(sess: var TuiTestSession): JsonNode =
  ## The `--capabilities=json` report the binary printed after giving the
  ## terminal back.
  let bytes = sess.transcriptBytes()
  let leave = bytes.rfind("\x1b[?1049l")
  let start = bytes.find('{', max(0, leave))
  let stop = bytes.rfind('}')
  if start < 0 or stop < start:
    raise newException(ValueError, "no JSON report in the transcript: " &
                       bytes[max(0, bytes.len - 400) .. ^1].escape)
  parseJson(bytes[start .. stop].replace("\r\n", "\n"))

proc reportFor(p: Persona; term = "xterm-256color"; args: seq[string] = @[];
               state = ""; probeMs = 1500): (JsonNode, PeerLog, string) =
  var sess = builder(@["--capabilities=json"] & args, term, state,
                     probeMs).spawn()
  let log = sess.serve(p)
  discard sess.waitExit(initDuration(seconds = 20))
  discard sess.drainOutput(100)
  let bytes = sess.transcriptBytes()
  let j = jsonOf(sess)
  sess.close()
  (j, log, bytes)

proc axis(j: JsonNode; name: string): JsonNode = j[name]["value"]
proc source(j: JsonNode; name: string): string = j[name]["from"].getStr

proc pythonSpec(name: string): FixtureSpec =
  FixtureSpec(
    name: name, program: "test-programs/" & name & "/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: "")

proc finishSession(sess: var TuiTestSession) =
  sess.send("\x11")  # Ctrl+Q, the CUA base's quit
  discard sess.waitExit(initDuration(seconds = 20))
  discard sess.drainOutput(100)

proc screenText(sess: var TuiTestSession): string =
  sess.regionText(0, 0, Cols, Rows)

suite "PLAT-71 Tier 2: the binary adapts to the terminal it runs in":

  test "the binary exists":
    ck fileExists(tuiBinary())

  test "the profile per persona, every axis with its source":
    block kittyCase:
      let (j, log, _) = reportFor(kitty())
      checkpoint(kitty().provenance)
      ck log.cursorReports == 6
      ck j["identity"]["value"]["name"].getStr == "kitty"
      ck j["identity"]["value"]["version"].getStr == "0.36.4"
      ck j.source("identity") == "probe"
      ck j.axis("tier").getStr == "extended"
      ck j.axis("syncOutput").getBool and j.source("syncOutput") == "probe"
      ck not j.axis("graphemeMode").getBool       # 2027 not recognised (Ps 0)
      ck not j.axis("ambiguousWide").getBool and
         j.source("ambiguousWide") == "probe"
      ck not j.axis("modernUnicode").getBool      # off by default (TA-9)
      ck j["keyProtocol"]["value"].getStr == "kitty"
    block kittyAuto:
      let (j, _, _) = reportFor(kitty(), args = @["--modern-unicode=auto"])
      ck j.axis("modernUnicode").getBool
      ck j.source("modernUnicode") == "identity"
    block footCase:
      let (j, _, _) = reportFor(foot(), term = "foot")
      ck j["identity"]["value"]["name"].getStr == "foot"
      ck j.axis("graphemeMode").getBool           # recognised, off: set
    block wideCase:
      let (j, _, _) = reportFor(vteWide())
      checkpoint(vteWide().provenance)
      ck j["identity"]["value"]["name"].getStr == "vte"
      ck j.axis("ambiguousWide").getBool and j.source("ambiguousWide") == "probe"
      ck not j.axis("syncOutput").getBool         # VTE answers 4
    block xtermCase:
      let (j, _, _) = reportFor(xterm())
      ck j["identity"]["value"]["name"].getStr == "xterm"
      ck not j.axis("syncOutput").getBool and j.source("syncOutput") == "probe"
      ck j["widths"]["value"]["clusters"].getStr == "no"
    block linuxCase:
      let (j, log, bytes) = reportFor(linuxConsole(), term = "linux")
      ck j.axis("tier").getStr == "basic"
      ck "\x1b[>q" notin log.queries          # the restricted round
      ck "\x1b]11;?\x1b\\" notin log.queries
      ck log.cursorReports == 6
      ck not bytes.contains("\x1b[>q")
    block silentCase:
      let started = getMonoTime()
      let (j, _, _) = reportFor(silent(), probeMs = 50)
      let ms = (getMonoTime() - started).inMilliseconds
      checkpoint("silent --capabilities took " & $ms & " ms")
      ck j.source("widths") == "default"
      ck j["widths"]["value"]["utf8"].getStr == "unknown"
      ck j.axis("tier").getStr == "extended"     # the UTF-8 locale's hint
    block noProbe:
      var sess = builder(@["--capabilities=json", "--no-probe"]).spawn()
      discard sess.waitExit(initDuration(seconds = 20))
      discard sess.drainOutput(100)
      let bytes = sess.transcriptBytes()
      ck not bytes.contains("\x1b[c")
      ck not bytes.contains("\x1b[6n")
      let j = jsonOf(sess)
      ck not j.axis("probe").getBool
      sess.close()

  test "a slow link is measured and makes the session link-conservative":
    let (j, _, _) = reportFor(slowKitty(300), probeMs = 3000)
    checkpoint("rtt " & $j.axis("rttMs"))
    ck j.axis("rttMs").getInt >= 300
    ck j.axis("linkConservative").getBool
    ck j.axis("reduceMotion").getBool and j.source("reduceMotion") == "probe"

  test "TA-12: the cache answers a silent session, a live answer replaces it":
    let state = freshState("cache")
    discard reportFor(kitty(), state = state)
    let cacheFile = state / "codetracer" / "terminal-profiles.json"
    var found = fileExists(cacheFile)
    if not found:
      for f in walkDirRec(state):
        if f.endsWith("terminal-profiles.json"):
          found = true
    ck found
    let (cached, _, _) = reportFor(silent(), state = state, probeMs = 50)
    ck cached["identity"]["value"]["name"].getStr == "kitty"
    ck cached.source("identity") == "cache"
    ck cached.source("widths") == "cache"
    let (live, _, _) = reportFor(xterm(), state = state)
    ck live["identity"]["value"]["name"].getStr == "xterm"
    ck live.source("identity") == "probe"
    ck live.source("widths") == "probe"

  test "TA-3, TA-10: an interactive session, its screen and its restore":
    let calc = resolveFixture(pythonSpec("calc"))
    if calc.outcome != foRecorded:
      checkpoint(calc.detail)
    ck calc.outcome == foRecorded
    if calc.outcome == foRecorded:
      # foot: 2027 recognised and off, so the binary sets it.
      var sess = builder(@[calc.tracePath], term = "foot").spawn()
      discard sess.serve(foot())
      settleOnDebugger(sess, Cols, Rows)
      let screen = sess.screenText()
      for g in ProbeGlyphs:
        ck not screen.contains(g)
      for q in QueryTexts:
        ck not screen.contains(q)
      ck sess.transcriptBytes().contains("\x1b[?2027h")
      let before = sess.transcriptBytes().len
      finishSession(sess)
      let restored = sess.transcriptBytes()[before .. ^1]
      ck restored.contains("\x1b[?2027l")
      ck restored.contains("\x1b[?2026l")
      ck restored.contains("\x1b[?1003l")
      sess.close()
      # SIGTERM: the same bytes, from the signal handler.
      var term = builder(@[calc.tracePath], term = "foot").spawn()
      discard term.serve(foot())
      settleOnDebugger(term, Cols, Rows)
      let mark = term.transcriptBytes().len
      term.sendSignal(SIGTERM)
      discard term.waitExit(initDuration(seconds = 20))
      discard term.drainOutput(100)
      let afterTerm = term.transcriptBytes()[mark .. ^1]
      checkpoint("after SIGTERM: " & afterTerm.escape)
      ck afterTerm.contains("\x1b[?2027l")
      ck afterTerm.contains("\x1b[?2026l")
      ck afterTerm.contains("\x1b[?1003l")
      term.close()
      # Silent: frame 0 within the bound, and the screen clean (TA-3, TA-11).
      let started = getMonoTime()
      var quiet = builder(@[calc.tracePath], probeMs = 10).spawn()
      waitForOpeningFrame(quiet, Cols, Rows)
      let frame0 = (getMonoTime() - started).inMilliseconds
      checkpoint("silent terminal: frame 0 after " & $frame0 & " ms")
      settleOnDebugger(quiet, Cols, Rows)
      let silentScreen = quiet.screenText()
      for g in ProbeGlyphs:
        ck not silentScreen.contains(g)
      finishSession(quiet)
      quiet.close()

  test "TA-10: SIGHUP and a crash reset every mode; a stop resets them, then takes the terminal again":
    let calc = resolveFixture(pythonSpec("calc"))
    ck calc.outcome == foRecorded
    if calc.outcome == foRecorded:
      for sig in [SIGHUP, SIGSEGV]:
        var s = builder(@[calc.tracePath], term = "foot").spawn()
        discard s.serve(foot())
        settleOnDebugger(s, Cols, Rows)
        ck s.transcriptBytes().contains("\x1b[?2027h")
        let mark = s.transcriptBytes().len
        s.sendSignal(sig)
        discard s.waitExit(initDuration(seconds = 20))
        discard s.drainOutput(100)
        let after = s.transcriptBytes()[mark .. ^1]
        checkpoint("after signal " & $sig & ": " & after.escape)
        ck after.contains("\x1b[?2027l")
        ck after.contains("\x1b[?2026l")
        ck after.contains("\x1b[?1003l")
        ck after.contains("\x1b[?1049l")
        s.close()
      # SIGTSTP: the restore before the stop, the claim after it, and a
      # whole frame — the screen the user returns to is the session's.
      var t = builder(@[calc.tracePath], term = "foot").spawn()
      discard t.serve(foot())
      settleOnDebugger(t, Cols, Rows)
      let before = t.screenText()
      let mark = t.transcriptBytes().len
      t.sendSignal(SIGTSTP)
      let deadline = getMonoTime() + initDuration(seconds = 20)
      var after = ""
      while getMonoTime() < deadline:
        discard t.drainOutput(100)
        after = t.transcriptBytes()[mark .. ^1]
        let claimed = after.find("\x1b[?1049h")
        if claimed >= 0 and after.find("\x1b[?1003h", claimed) >= 0 and
           t.screenText() == before:
          break
      checkpoint("after SIGTSTP: " & after[0 .. min(after.len, 400) - 1].escape)
      let left = after.find("\x1b[?1049l")
      let back = after.find("\x1b[?1049h")
      ck after.contains("\x1b[?2027l") and after.contains("\x1b[?1003l")
      ck left >= 0 and back > left
      ck after.find("\x1b[?2027h", max(0, back)) > back
      ck after.find("\x1b[?1003h", max(0, back)) > back
      ck t.screenText() == before
      finishSession(t)
      t.close()

  test "§6.5, §6.6: content's zero-width runes are drawn; unmeasured widths are fenced":
    let text = resolveFixture(pythonSpec("grapheme_text"))
    if text.outcome != foRecorded:
      checkpoint(text.detail)
    ck text.outcome == foRecorded
    if text.outcome == foRecorded:
      const Woman = "\u{1F469}"
      const Laptop = "\u{1F4BB}"
      proc isFence(bytes: string; at: int): bool =
        ## `CSI <digits> G` starts at `at`.
        if at + 3 > bytes.len or bytes[at] != '\x1b' or bytes[at + 1] != '[':
          return false
        var k = at + 2
        while k < bytes.len and bytes[k] in Digits: inc k
        k > at + 2 and k < bytes.len and bytes[k] == 'G'
      proc fencedAfter(bytes, glyph: string): bool =
        var at = bytes.find(glyph)
        while at >= 0:
          if bytes.isFence(at + glyph.len): return true
          at = bytes.find(glyph, at + 1)
        false
      proc session(p: Persona; persona: string): (string, string) =
        var sess = builder(@[text.tracePath], term = persona).spawn()
        discard sess.serve(p)
        settleOnDebugger(sess, Cols, Rows)
        discard sess.drainOutput(200)
        result = (sess.transcriptBytes(), sess.screenText())
        finishSession(sess)
        sess.close()
      # xterm: the ambiguous policy measured (narrow), ZWJ sequences summed.
      let (xb, xs) = session(xterm(), "xterm-256color")
      ck xb.contains("cafe\u0301")
      ck xs.contains("cafe\u0301")
      ck xb.contains(Woman & "\u200D")
      ck xb.fencedAfter(Woman & "\u200D")
      ck not xb.fencedAfter("\u2026")
      # A silent terminal: nothing measured, so the ellipsis is fenced too.
      let (sb, _) = session(silent(), "xterm-256color")
      ck sb.fencedAfter("\u2026")
      ck sb.fencedAfter("\u2014")
      # foot measured every width and clusters: no fence anywhere.
      let (fb, fs) = session(foot(), "foot")
      ck fb.contains(Woman & "\u200D" & Laptop)
      ck not fb.fencedAfter("\u2026") and not fb.fencedAfter(Woman & "\u200D")
      ck fs.contains("cafe\u0301")

  test "TA-5, TA-8: a terminal measured ambiguous-WIDE gets the safe glyphs":
    let calc = resolveFixture(pythonSpec("calc"))
    ck calc.outcome == foRecorded
    if calc.outcome == foRecorded:
      var content: seq[string] = @[]
      for r in readFile(lifecycle_support.repoRoot() / calc.spec.program).runes:
        if int(r) >= 0x80 and $r notin content: content.add $r
      var sess = builder(@[calc.tracePath]).spawn()
      discard sess.serve(vteWide())
      settleOnDebugger(sess, Cols, Rows)
      var ambiguous: seq[string] = @[]
      for row in 0 ..< Rows:
        for r in sess.regionText(row, 0, Cols, 1).runes:
          # `…` is the truncation marker drawn as two cells by decision
          # (OQ-T2); the program's own text is drawn as recorded.
          if eawClass(int32(r)) == eawAmbiguous and $r != "…" and
             $r notin content:
            ambiguous.add $row & ":" & $r
      checkpoint("EAW-A cells on the wide terminal: " & $ambiguous)
      ck ambiguous.len == 0
      finishSession(sess)
      sess.close()

  test ":terminal-info: the live report, the card, and y for this terminal":
    let calc = resolveFixture(pythonSpec("calc"))
    ck calc.outcome == foRecorded
    if calc.outcome == foRecorded:
      let state = freshState("info")
      var sess = builder(@[calc.tracePath], term = "xterm-kitty",
                         state = state).spawn()
      discard sess.serve(kitty())
      settleOnDebugger(sess, Cols, Rows)
      # The palette (F1), the command, Enter — as a user reaches it.
      sess.send("\x1bOP")
      discard sess.drainOutput(300)
      sess.send(":terminal-info")
      discard sess.drainOutput(300)
      sess.send("\r")
      let deadline = getMonoTime() + initDuration(seconds = 20)
      while not sess.screenText().contains("TERMINAL CAPABILITIES") and
            getMonoTime() < deadline:
        discard sess.drainOutput(50)
      var screen = sess.screenText()
      ck screen.contains("TERMINAL CAPABILITIES")
      ck screen.contains("kitty 0.36.4")
      ck screen.contains("modern-unicode off")
      ck screen.contains("Glyph test card")
      # A key is shown decoded.
      sess.send("x")
      discard sess.drainOutput(300)
      ck sess.screenText().contains("key: x")
      # `y`: the Legacy Computing glyphs look right, so modern-unicode ON for
      # kitty only — remembered in a [terminal "kitty"] section.
      sess.send("y")
      let until = getMonoTime() + initDuration(seconds = 10)
      while not sess.screenText().contains("modern-unicode on") and
            getMonoTime() < until:
        discard sess.drainOutput(50)
      screen = sess.screenText()
      checkpoint(screen)
      ck screen.contains("modern-unicode on")
      var prefs = ""
      for f in walkDirRec(state):
        if f.endsWith("tui-preferences"):
          prefs = readFile(f)
      checkpoint("preferences: " & prefs)
      ck prefs.contains("[terminal \"kitty\"]")
      ck prefs.contains("modern-unicode=on")
      sess.send("\x1b")
      discard sess.drainOutput(400)
      ck not sess.screenText().contains("TERMINAL CAPABILITIES")
      finishSession(sess)
      sess.close()

  test "TA-7: on the ASCII tier the program's text is drawn as recorded":
    let calc = resolveFixture(pythonSpec("calc"))
    ck calc.outcome == foRecorded
    if calc.outcome == foRecorded:
      var content: seq[string] = @[]
      for r in readFile(lifecycle_support.repoRoot() / calc.spec.program).runes:
        if int(r) >= 0x80 and $r notin content: content.add $r
      ck "—" in content        # the calc docstring's em dash: content
      var sess = builder(@["--glyphs=ascii", calc.tracePath]).spawn()
      discard sess.serve(kitty())
      settleOnDebugger(sess, Cols, Rows)
      let screen = sess.screenText()
      ck screen.contains("—")  # verbatim, not transliterated
      var chrome: seq[string] = @[]
      for r in screen.runes:
        if int(r) >= 0x80 and $r notin content:
          chrome.add $r
      checkpoint("non-ASCII cells that are not the program's: " & $chrome)
      ck chrome.len == 0
      finishSession(sess)
      sess.close()

  test "late answers over a slow link are applied and make it conservative":
    let calc = resolveFixture(pythonSpec("calc"))
    ck calc.outcome == foRecorded
    if calc.outcome == foRecorded:
      var sess = builder(@[calc.tracePath], probeMs = 10).spawn()
      waitForOpeningFrame(sess, Cols, Rows)   # frame 0, before any answer
      discard sess.serve(slowKitty(400))
      settleOnDebugger(sess, Cols, Rows)
      sess.send("\x1bOP")
      discard sess.drainOutput(300)
      sess.send(":terminal-info")
      discard sess.drainOutput(300)
      sess.send("\r")
      let deadline = getMonoTime() + initDuration(seconds = 20)
      while not sess.screenText().contains("TERMINAL CAPABILITIES") and
            getMonoTime() < deadline:
        discard sess.drainOutput(50)
      let screen = sess.screenText()
      checkpoint(screen)
      ck screen.contains("kitty 0.36.4")       # the late identity, applied
      ck screen.contains("slow link")
      ck screen.contains("Motion       reduced")
      sess.send("\x1b")
      finishSession(sess)
      sess.close()

  test "TA-11: the tmux spawn runs beside the round, not before it":
    # THE ONE STAND-IN OF THIS CASE: a `tmux` on PATH that takes a second to
    # answer `display -p` (a loaded tmux server, exaggerated so a loaded test
    # host cannot blur it). It is not a mock of what is under test — the
    # binary's ordering of the spawn against the round is — and the real
    # tmux's formats are asserted in TA-14 above.
    let stubDir = freshState("tmux-stub")
    let stub = stubDir / "tmux"
    writeFile(stub, "#!/bin/sh\nsleep 1\nprintf '\\t\\t\\t\\t3.4\\toff\\toff\\toff\\t0\\t1\\n'\n")
    discard chmod(stub.cstring, 0o755)
    let started = getMonoTime()
    var sess = builder(@["--capabilities=json"], term = "tmux-256color",
                       extra = @[("TMUX", "/nonexistent/sock,1,0"),
                                 ("PATH", stubDir & ":" & getEnv("PATH"))]).spawn()
    let deadline = getMonoTime() + initDuration(seconds = 20)
    while not sess.transcriptBytes().contains("\x1b[c") and
          getMonoTime() < deadline:
      discard sess.drainOutput(5)
    let asked = (getMonoTime() - started).inMilliseconds
    checkpoint("the round was written " & $asked & " ms after the spawn")
    ck asked < 900
    discard sess.serve(xterm())
    discard sess.waitExit(initDuration(seconds = 20))
    discard sess.drainOutput(100)
    let j = jsonOf(sess)
    sess.close()
    ck j["identity"]["value"]["via"][0].getStr == "tmux 3.4"

  test "TA-4 and the F3 rule: typed-ahead keys survive, a late CSI 1;5R is a key":
    let calc = resolveFixture(pythonSpec("calc"))
    ck calc.outcome == foRecorded
    if calc.outcome == foRecorded:
      let journal = freshState("journal") / "keys.txt"
      var sess = builder(@["--record-keys=" & journal, calc.tracePath],
                         probeMs = 3000).spawn()
      # The round is out and waiting: type before the terminal answers.
      let deadline = getMonoTime() + initDuration(seconds = 20)
      while not sess.transcriptBytes().contains("\x1b[c") and
            getMonoTime() < deadline:
        discard sess.drainOutput(20)
      sess.send("j")
      sess.send("k")
      discard sess.serve(kitty())
      settleOnDebugger(sess, Cols, Rows)
      # After the round: Ctrl+F3 in legacy xterm's encoding.
      sess.send("\x1b[1;5R")
      discard sess.drainOutput(300)
      finishSession(sess)
      sess.close()
      ck fileExists(journal)
      let tokens = readFile(journal)
      checkpoint("journal: " & tokens.escape)
      let j = tokens.find("j")
      let k = tokens.find("k", max(0, j))
      ck j >= 0 and k > j
      ck tokens.contains("[1;5R")

  test "TA-14: under a real tmux, one display spawn and no passthrough":
    let tmux = findExe("tmux")
    if tmux.len == 0:
      checkpoint("tmux is not on PATH: the lane's environment provides it")
    ck tmux.len > 0
    if tmux.len > 0:
      # The binary runs in a pane of a REAL tmux, which answers the pane's
      # queries itself; `pipe-pane` records every byte the binary writes.
      let dir = freshState("tmux")
      let paneOut = dir / "pane.bytes"
      let sock = "plat71-" & $getCurrentProcessId()
      let inner = "tmux pipe-pane -o " & quoteShell("cat > " & paneOut) &
        "; sleep 0.5; env -u COLORTERM TERM=tmux-256color " &
        "CT_TUI_PROBE_TIMEOUT_MS=1500 CODETRACER_TUI_LAYOUT_DIR=" &
        quoteShell(dir / "layout") & " " & quoteShell(tuiBinary()) &
        " --capabilities=json; sleep 60"
      var client = newTuiTest(tmux, @["-L", sock, "-f", "/dev/null",
                                      "new-session", "-x", "100", "-y", "30",
                                      inner])
        .width(100).height(31)
        .envRemove("TMUX", "COLORTERM", "TERM_PROGRAM", "NO_COLOR")
        .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
        .spawn()
      var bytes = ""
      let deadline = getMonoTime() + initDuration(seconds = 60)
      while getMonoTime() < deadline:
        discard client.drainOutput(100)
        if fileExists(paneOut):
          bytes = readFile(paneOut)
          if bytes.rfind("}") > bytes.rfind("\x1b[?1049l") and
             bytes.contains("\x1b[?1049l"):
            break
      discard execCmdEx(quoteShell(tmux) & " -L " & sock & " kill-server")
      client.close()
      checkpoint("pane bytes: " & $bytes.len)
      ck bytes.contains("\x1b[c")                # the round reached tmux
      ck not bytes.contains("\x1bPtmux;")         # and nothing passed through
      let leave = bytes.rfind("\x1b[?1049l")
      let start = bytes.find('{', max(0, leave))
      let stop = bytes.rfind('}')
      ck start >= 0 and stop > start
      if start >= 0 and stop > start:
        let j = parseJson(bytes[start .. stop].replace("\r\n", "\n"))
        let via = j["identity"]["value"]["via"]
        checkpoint("via " & $via & ", identity " & $j["identity"])
        ck via.len == 1 and via[0].getStr.startsWith("tmux ")
        # The facts came from tmux's own formats: its version, and the
        # client's TERM behind it.
        ck via[0].getStr.len > "tmux ".len

  test "assertion count":
    removeDir(stateRoot)
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
