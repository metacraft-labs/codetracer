## test_plat68_diff13.nim — PLAT-68 DIFF-13 (Base-Keymaps-And-Layer-Stack.md
## KL-6): THE SAME CONFIGURATION, THE SAME BASE AND THE SAME SCOPE PATH YIELD
## THE SAME OPERATION ON EVERY FRONT-END.
##
## THE POPULATION is derived from the tables, never listed
## (`support/diff13_population`): every row of the CUA, Emacs, Vim and
## Kakoune bases in every situation whose scope path puts the row's table on
## it, each probed by its first chord; a user `keybindings.json` with, per
## situation, one override, one removal, one `when`-split pair and one global
## row shadowing an inner base row; and the §3.10 legacy fallbacks under
## `keyProtocol == legacy`. Its size is asserted as a count derived from the
## tables, so a table that shrinks reddens here.
##
## THE TWO HALVES, BOTH ASSERTED, for every tuple a front-end can express:
##   * the SCOPE PATH each front-end's own producer reads off its own focus
##     model equals the situation's declared path — the terminal's
##     `isonim-tui` focus tree (`runtime.scopePath`), GPUI's element focus
##     chain (`windowScopePath`, inside the shipped binary);
##   * the RESOLUTION equals the shared router's for that path and the
##     situation's facts under that front-end's delivery
##     (`diff13_population.expected`).
## Two front-ends each equal to the one answer are equal to each other. The
## desktop is held to the same committed answers by
## `src/tests/gui/tests/keymaps/plat68-diff13-desktop.spec.ts`, through its
## own decoder and DOM producer in the real Electron app
## (`window.__ctKeymapProbe`); the answers it reads are
## `src/tests/gui/tests/keymaps/diff13/answers-<base>.json`, which this suite
## asserts is the population derived now (`CT_DIFF13_WRITE=1` rewrites it).
##
## EACH KEY ARRIVES IN ITS DEVICE FORM and is decoded by the front-end's own
## decoder: the terminal's bytes (Kitty flag 1, or the classic encoding for
## the legacy rows) through `terminal_driver`'s framer and `runtime.keyOf`;
## GPUI's keystroke (`key` + modifier list) through `canonicalKeyOfGpui`
## inside the binary (`--window-ops=probe:`). Every synthesised form is
## first checked to decode back to its own name, on all three decoders
## (Verification-Harness-Traps §25). A tuple a device has no form for is
## COUNTED as inexpressible there, by reason.
##
## WHAT IS SHIPPED AND WHAT IS THE DRIVER. Shipped: the terminal runtime
## (`TuiRuntime`, its focus tree, its decoder, its router) over a real
## `replay-server` session of the `calc` recording, and the `codetracer-gpui`
## binary over the same recording with its own engine. The suite's driver:
## the key synthesiser (`support/key_devices` — it plays the keyboard), the
## population and its expected answers (`support/diff13_population` — the
## shared router asked over the declared path, i.e. the rule both front-ends
## are held to), and the input that puts each front-end in a situation.
##
## No mocks.

import std/[json, os, osproc, sets, streams, strtabs, strutils, tables,
            tempfiles, unittest]
import ../../gpui/tests/gpui_child_env

import codetracer_embed
import keymap/base_keymaps
import keymap/context_keys
import keymap/editing_keymap
import keymap/keymap_router
import keymap/user_keymap
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../host/terminal_driver
import ../host/tui_session
import ../../gpui/app/gpui_keys
import ../../../common/key_event_names
import ../../../common/key_names
import ./fixtures/fixture_provider
import ./support/diff13_population
import ./support/key_devices

# The suite's RUNTIME assertion count is printed as `CHECKS:` (read by
# `ci/lib/run-nim-test-lane.sh`), because the population — and so the count —
# is derived from the tables rather than declared.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50

type
  Reach = object
    ## How each front-end puts the focus for a situation: the pane, or a
    ## pane's tab. A situation that `opens` something is then reached with
    ## the base's own chord for it (`openingChords`).
    tuiPane: PaneKind
    gpuiOps: string
    desktop: string
      ## The desktop capture's recipe name.

let reaches = [
  Reach(tuiPane: paneEditor, gpuiOps: "", desktop: "editor"),
  Reach(tuiPane: paneCalltrace, gpuiOps: "click:tab:calltrace",
        desktop: "calltrace"),
  Reach(tuiPane: paneState, gpuiOps: "click:tab:state", desktop: "state"),
  Reach(tuiPane: paneEventLog, gpuiOps: "click:tab:eventLog",
        desktop: "eventLog"),
  Reach(tuiPane: paneEditor, gpuiOps: "", desktop: "palette"),
  Reach(tuiPane: paneEditor, gpuiOps: "", desktop: "writable")]

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let gpuiBin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let answersDir = repo / "src/tests/gui/tests/keymaps/diff13"

let pop = derive(declaredSituations())
let userText = pop.userText
let fileKeymap = parseUserKeymap(userText)

# ---------------------------------------------------------------------------
# The terminal
# ---------------------------------------------------------------------------

proc decodeBytes(rt: TuiRuntime; bytes: string): seq[string] =
  ## The canonical names the terminal's own framer and decoder make of
  ## `bytes` — what the runtime's input loop does with a read.
  var f = initInputFramer()
  for b in bytes:
    let (done, token) = f.feed(b)
    if done: result.add rt.keyOf(token)
  if f.holdsLoneEsc: result.add rt.keyOf("\e")

type TuiRun = object
  path: string
  answers: seq[tuple[name, answer: string]]

proc tuiRun(subject: string; base: BaseKeymap; user: bool; si: int;
            keys: seq[string]; protocol = kpKitty): TuiRun =
  ## The terminal runtime over a real session of the recording, under `base`
  ## (and the user's file), put in situation `si` by its own input, asked
  ## each key in its device form.
  var caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  caps.keyProtocol = protocol
  let rt = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
  rt.adoptCaps(caps)
  discard rt.enableLayoutBinding()
  let s = pop.situations[si]
  # The base's own chord for what opens the situation; a base with none
  # (Vim and Kakoune bind no key to `editor.toggle-read-only`) is reached
  # the way its user does — under CUA, then `:keymap <base>`.
  var opening = openingChords(s, base, pop.situations[0])
  let viaCua = s.opens.len > 0 and opening.len == 0
  if viaCua: opening = openingChords(s, bkCua, pop.situations[0])
  rt.selectBase(if viaCua: bkCua else: base, ksCommand)
  discard rt.applyUserKeymap(if user: fileKeymap else: UserKeymap())
  let session = openTuiSession(subject, viewportHeight = Rows - 8)
  defer: session.close()
  session.header(rt)
  session.learnExtent()
  session.refresh(rt)
  doAssert rt.focus.focusPaneKind(reaches[si].tuiPane)
  for chord in opening:
    var f = initInputFramer()
    for b in kittyBytes(chord):
      let (done, token) = f.feed(b)
      if done: session.applyOutcome(rt, rt.handleToken(token, 0))
  if viaCua: rt.chooseKeymap($base)
  result.path = $normalisedPath(rt.scopePath)
  for k in keys:
    let bytes = if protocol == kpLegacy: legacyBytes(k) else: kittyBytes(k)
    let names = rt.decodeBytes(bytes)
    let name = if names.len == 1: names[0] else: "<" & $names & ">"
    result.answers.add (name, describeResolution(rt.probeKey(name)))

# ---------------------------------------------------------------------------
# GPUI
# ---------------------------------------------------------------------------

func percent(s: string): string =
  for c in s:
    if c in {',', ':', '%'}: result.add "%" & toHex(ord(c), 2)
    else: result.add c

proc gpuiRun(subject: string; base: BaseKeymap; user: bool; si: int;
             keys: seq[string]): seq[string] =
  ## Every `probe` line the SHIPPED GPUI binary traced, under `base` (and the
  ## user's file), in situation `si`, each key delivered as its keystroke.
  if not fileExists(gpuiBin):
    raise newException(IOError, "prerequisite missing: " & gpuiBin &
                       " (just build-gpui)")
  let state = createTempDir("plat68-diff13-", "")
  defer: removeDir(state)
  var env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["XDG_CONFIG_HOME"] = state / "config"
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_KEYBINDINGS"] = state / "keybindings.json"
  if user: writeFile(state / "keybindings.json", userText)
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  var ops: seq[string] = @[]
  if reaches[si].gpuiOps.len > 0: ops.add reaches[si].gpuiOps
  for chord in openingChords(pop.situations[si], base, pop.situations[0]):
    let ks = gpuiKeystroke(chord)
    ops.add "key:" & (if ks.key == ":": "colon" else: ks.key) &
            (if ks.mods.len > 0: ":" & ks.mods.join("+") else: "")
  for k in keys:
    let ks = gpuiKeystroke(k)
    ops.add "probe:" & percent(ks.key) &
            (if ks.mods.len > 0: ":" & ks.mods.join("+") else: "")
  let errFile = state / "trace.err"
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 600 \"$0\" \"$@\" 2>" & quoteShell(errFile),
             gpuiBin, "--report-window-plan", "--width=1440", "--height=1400",
             "--keymap=" & $base, "--window-ops=" & ops.join(","), subject],
    env = env, options = {})
  discard p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let trace = if fileExists(errFile): readFile(errFile) else: ""
  if rc != 0:
    checkpoint(trace[max(0, trace.len - 3000) .. ^1])
    raise newException(IOError, "the GPUI window plan failed (rc " & $rc &
                       ") for " & $base & " in situation " & $si)
  for line in trace.splitLines:
    if line.startsWith("gesture probe "):
      result.add line["gesture probe ".len .. ^1]

func splitProbeLine(line: string): tuple[name, path, answer: string] =
  ## `<key> at <path> -> <resolution>`.
  let arrow = line.find(" -> ")
  let at = line.find(" at ")
  if arrow < 0 or at < 0 or at > arrow: return (line, "", "")
  (line[0 ..< at], line[at + 4 ..< arrow], line[arrow + 4 .. ^1])

func normalisedPathText(text: string): string =
  ## A producer's printed path with the editor element's file normalised.
  var parts = text.split(" / ")
  for p in parts.mitems:
    if p.startsWith("editor:editor:"): p = "editor:editor:" & SourceToken
  parts.join(" / ")

# ---------------------------------------------------------------------------
# The committed answers the desktop is held to
# ---------------------------------------------------------------------------

proc answersText(base: BaseKeymap): string =
  ## One base's half of the committed answers, ONE PROBE PER LINE (the
  ## repository refuses an added file over 500 KB, and a per-line file diffs
  ## by probe): the population's `keybindings.json`, the situations, then each
  ## probe the desktop can express with its `KeyboardEvent` fields and the
  ## rule's answer under the desktop's delivery.
  var situations = newJArray()
  for i, s in pop.situations:
    situations.add %*{"name": s.name, "desktop": reaches[i].desktop,
                      "path": $s.path}
  var lines = @["{", "  \"_\": " & $(%("DIFF-13's population for the " &
    "desktop under " & $base & ", derived by src/frontend/tui/tests/" &
    "test_plat68_diff13.nim (CT_DIFF13_WRITE=1 rewrites it); not edited by " &
    "hand.")) & ",",
    "  \"base\": " & $(%($base)) & ",",
    "  \"keybindings\": " & $(%userText) & ",",
    "  \"situations\": " & $situations & ",",
    "  \"probes\": ["]
  var rows: seq[string] = @[]
  for p in pop.probes:
    if p.base != base or not pop.expressible(p, fDesktop): continue
    let d = domKey(p.chord)
    rows.add "    " & $(%*{"situation": p.situation, "user": p.user,
                            "chord": p.chord, "key": d.key, "code": d.code,
                            "ctrlKey": d.ctrl, "shiftKey": d.shift,
                            "altKey": d.alt, "metaKey": d.meta,
                            "expected": p.expected[fDesktop]})
  lines.add rows.join(",\n")
  lines.add "  ]"
  lines.add "}"
  lines.join("\n") & "\n"

proc answersFileOf(base: BaseKeymap): string =
  answersDir / ("answers-" & $base & ".json")

# ---------------------------------------------------------------------------
# The suites
# ---------------------------------------------------------------------------

let calc = resolveFixture("calc")
var unreachableOnGpui = 0
  ## Keys of situations no key of the base opens on GPUI (reported).

proc probesOf(base: BaseKeymap; user: bool; si: int;
              f: DiffArm): seq[Probe] =
  for p in pop.probes:
    if p.base == base and p.user == user and p.situation == si and
       pop.expressible(p, f):
      result.add p

suite "PLAT-68 DIFF-13: the population is the tables'":

  test "every base contributes, every situation is reached, and the count is derived":
    var perBase: array[BaseKeymap, int]
    var perSituation = newSeq[int](pop.situations.len)
    for p in pop.probes:
      perBase[p.base] += p.rows
      perSituation[p.situation] += p.rows
    for b in BaseKeymap:
      checkpoint($b & ": " & $pop.rowTuplesByBase[b] & " row tuples")
      ck pop.rowTuplesByBase[b] > 0
    for i, n in perSituation:
      checkpoint(pop.situations[i].name & ": " & $n & " probe rows")
      ck n > 0
    # The count, derived again from the tables by a second walk: every row
    # of every base whose table a situation puts on its path.
    var walked = 0
    for b in BaseKeymap:
      for s in pop.situations:
        let live = tablesOn(s)
        for r in keymapOf(b).keymap.bindings:
          if tableOf(r) in live and r.chords.len > 0 and
             not r.scope.whenText.contains("keyProtocol == legacy"):
            inc walked
    ck pop.rowTuples == walked
    ck pop.legacy.len > 0
    ck pop.userRows >= 4
    echo "DIFF-13 population: ", pop.rowTuples, " row tuples (",
         "cua ", pop.rowTuplesByBase[bkCua], ", emacs ",
         pop.rowTuplesByBase[bkEmacs], ", vim ", pop.rowTuplesByBase[bkVim],
         ", kakoune ", pop.rowTuplesByBase[bkKakoune], "); ",
         pop.probes.len, " probes; ", pop.userRows, " user rows, ",
         pop.userTuples, " user tuples; ", pop.legacy.len, " legacy tuples"
    var why = initCountTable[string]()
    for x in pop.inexpressible: why.inc($x.frontEnd & ": " & x.why)
    for k, n in why: echo "  inexpressible ", n, " — ", k

  test "every key's device form decodes to its own name on all three decoders":
    var seen = initHashSet[string]()
    for p in pop.probes:
      if p.chord in seen: continue
      seen.incl p.chord
      if pop.expressible(p, fTerminal):
        var f = initInputFramer()
        var names: seq[string] = @[]
        for b in kittyBytes(p.chord):
          let (done, token) = f.feed(b)
          if done: names.add keyName(token)
        if f.holdsLoneEsc: names.add keyName("\e")
        if names != @[p.chord]: checkpoint("terminal: " & p.chord & " -> " & $names)
        ck names == @[p.chord]
      if pop.expressible(p, fGpui):
        let ks = gpuiKeystroke(p.chord)
        let name = canonicalKeyOfGpui(ks.key, ks.mods)
        if name != p.chord: checkpoint("GPUI: " & p.chord & " -> " & name)
        ck canonicalKeyOfGpui(ks.key, ks.mods) == p.chord
      if pop.expressible(p, fDesktop):
        let d = domKey(p.chord)
        let name = canonicalKeyOfDom(d.key, d.code, d.ctrl, d.shift, d.alt,
                                     d.meta)
        if name != p.chord: checkpoint("desktop: " & p.chord & " -> " & name)
        ck canonicalKeyOfDom(d.key, d.code, d.ctrl, d.shift, d.alt, d.meta) ==
           p.chord
    for p in pop.legacy:
      ck keyName(legacyBytes(p.chord)) == p.chord

  test "the desktop's committed answers are this population":
    for base in BaseKeymap:
      let derived = answersText(base)
      if getEnv("CT_DIFF13_WRITE") == "1":
        createDir(answersDir)
        writeFile(answersFileOf(base), derived)
      let committed = if fileExists(answersFileOf(base)):
                        readFile(answersFileOf(base)) else: ""
      if committed != derived:
        checkpoint(answersFileOf(base) & " is not the population derived " &
                   "now; CT_DIFF13_WRITE=1 rewrites it")
      ck committed == derived

suite "PLAT-68 DIFF-13: the terminal (its focus tree, its decoder)":

  for base in BaseKeymap:
    for user in [false, true]:
      test $base & (if user: " with the user's file" else: "") &
           ": every situation's path and every key's resolution":
        require calc.outcome == foRecorded
        for si, s in pop.situations:
          let probes = probesOf(base, user, si, fTerminal)
          var keys: seq[string] = @[]
          for p in probes: keys.add p.chord
          let run = tuiRun(calc.tracePath, base, user, si, keys)
          if run.path != $s.path:
            checkpoint(s.name & ": terminal path " & run.path &
                       "; declared " & $s.path)
          ck run.path == $s.path
          var tuiWrong = 0
          for i, p in probes:
            if run.answers[i].name != p.chord or
               run.answers[i].answer != p.expected[fTerminal]:
              inc tuiWrong
              if tuiWrong <= 5:
                checkpoint(s.name & ": " & p.chord & " decoded " &
                           run.answers[i].name & " -> " &
                           run.answers[i].answer & "; the rule: " &
                           p.expected[fTerminal])
          checkpoint(s.name & ": " & $probes.len & " keys, " & $tuiWrong &
                     " differ")
          ck tuiWrong == 0

  test "the legacy fallbacks, on a terminal without extended key reporting":
    require calc.outcome == foRecorded
    var groups = initOrderedTable[(BaseKeymap, int), seq[Probe]]()
    for p in pop.legacy: groups.mgetOrPut((p.base, p.situation), @[]).add p
    var legacyWrong = 0
    for (key, probes) in groups.pairs:
      var keys: seq[string] = @[]
      for p in probes: keys.add p.chord
      let run = tuiRun(calc.tracePath, key[0], false, key[1], keys, kpLegacy)
      for i, p in probes:
        if run.answers[i].name != p.chord or
           run.answers[i].answer != p.expected[fTerminal]:
          inc legacyWrong
          checkpoint($key[0] & " " & p.chord & " -> " & run.answers[i].answer &
                     "; the rule: " & p.expected[fTerminal])
    ck legacyWrong == 0

suite "PLAT-68 DIFF-13: GPUI (its element focus chain, its decoder, the shipped binary)":

  for base in BaseKeymap:
    for user in [false, true]:
      test $base & (if user: " with the user's file" else: "") &
           ": every situation's path and every key's resolution":
        require calc.outcome == foRecorded
        for si, s in pop.situations:
          let probes = probesOf(base, user, si, fGpui)
          if s.opens.len > 0 and
             openingChords(s, base, pop.situations[0]).len == 0:
            # No key of this base opens it, and the window cannot change its
            # base after it starts: COUNTED, not skipped silently.
            checkpoint(s.name & ": unreachable on GPUI under " & $base &
                       " (" & $probes.len & " keys inexpressible there)")
            unreachableOnGpui += probes.len
            continue
          var keys: seq[string] = @[]
          for p in probes: keys.add p.chord
          let lines = gpuiRun(calc.tracePath, base, user, si, keys)
          ck lines.len == probes.len
          var gpuiWrongPath, gpuiWrong, gpuiPathWithoutPane = 0
          for i in 0 ..< min(lines.len, probes.len):
            let (name, path, answer) = splitProbeLine(lines[i])
            # The pane level on its own, so a producer that drops it is told
            # apart from one that drops another level.
            if ($s.path).contains(" / pane:") and not path.contains(" / pane:"):
              inc gpuiPathWithoutPane
            if normalisedPathText(path) != $s.path:
              inc gpuiWrongPath
              if gpuiWrongPath <= 1:
                checkpoint(s.name & ": GPUI path " & path & "; declared " &
                           $s.path)
            if name != probes[i].chord or
               answer != probes[i].expected[fGpui]:
              inc gpuiWrong
              if gpuiWrong <= 5:
                checkpoint(s.name & ": " & probes[i].chord & " decoded " &
                           name & " -> " & answer & "; the rule: " &
                           probes[i].expected[fGpui])
          checkpoint(s.name & ": " & $probes.len & " keys, " & $gpuiWrong &
                     " differ, " & $gpuiWrongPath & " paths differ")
          ck gpuiPathWithoutPane == 0
          ck gpuiWrongPath == 0
          ck gpuiWrong == 0

suite "PLAT-68 DIFF-13: the situations are told apart (the gate is not vacuous)":

  test "one key answers differently across the situations":
    # `n` under CUA: a step in the read-only editor and in a list, a
    # character in the palette's field and in the writable editor — so the
    # agreement above is about the situation, not a constant.
    var nAnswers: seq[string] = @[]
    for si in 0 ..< pop.situations.len:
      for p in pop.probes:
        if p.base == bkCua and not p.user and p.situation == si and
           p.chord == "n":
          nAnswers.add p.expected[fTerminal]
    checkpoint($nAnswers)
    ck nAnswers.len == pop.situations.len
    ck nAnswers[0] == "operation debugger.step-over"     # read-only editor
    ck nAnswers[1] == "operation debugger.step-over"     # a list
    ck nAnswers[4] == "character n"                      # the palette's field
    ck nAnswers[5] == "character n"                      # the writable editor

  test "the user's file changes answers (the user half is not vacuous)":
    var changed = 0
    var plain = initTable[(BaseKeymap, int, string), string]()
    for p in pop.probes:
      if not p.user: plain[(p.base, p.situation, p.chord)] = p.expected[fTerminal]
    for p in pop.probes:
      if p.user and plain.getOrDefault((p.base, p.situation, p.chord), "") !=
         p.expected[fTerminal]:
        inc changed
    checkpoint($changed & " answers changed by the user's file")
    ck changed > 0

suite "PLAT-68: an overlay hands the focus back":

  test "closing the palette hands the focus back to the pane it covered":
    # The palette hangs at the window (`motions.scopePathOf`); the pane it
    # covered is held (`heldPane`) and has the focus again when it closes —
    # not the first pane of the ring.
    require calc.outcome == foRecorded
    let caps = resolveCapabilities(
      initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                      lang = "en_US.UTF-8"), initCapabilityFlags())
    let rt = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
    discard rt.enableLayoutBinding()
    let session = openTuiSession(calc.tracePath, viewportHeight = Rows - 8)
    defer: session.close()
    session.header(rt)
    session.learnExtent()
    session.refresh(rt)
    doAssert rt.focus.focusPaneKind(paneCalltrace)
    let before = $rt.scopePath
    session.applyOutcome(rt, rt.handleToken("\x10", 0))     # Ctrl+P
    ck rt.app.omnibar.isOpen
    session.applyOutcome(rt, rt.handleToken("\e", 0))       # Esc
    checkpoint(before & " -> " & $rt.scopePath)
    ck $rt.scopePath == before

suite "PLAT-68 DIFF-13: assertion count":
  test "the count is reported":
    echo "DIFF-13: ", unreachableOnGpui, " GPUI keys in situations no key " &
         "of their base opens (the writable editor under Vim and Kakoune)"
    check countedAssertions > 0
    echo "CHECKS: ", countedAssertions
