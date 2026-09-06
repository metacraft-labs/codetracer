## test_real_high_latency.nim — CTUI-14, Tier 2. A hundred steps over a slow
## link end on the same screen a hundred steps over a fast one do.
##
## ## THE ASSERTION IS EQUALITY, AND "IT LOOKED FINE" IS NOT ONE
##
## CTUI-14: *"asserting no screen corruption and that the final screen equals
## the no-latency screen for the same key sequence. Equality against the
## zero-latency run is the assertion."* Everything below is arranged so that
## sentence is literally what is checked:
##
##   * **"the same key sequence" is a FILE.** Both runs are driven by
##     `--replay-keys`, over one journal written once, so the two sequences are
##     not merely intended to be the same — they are the same bytes read twice.
##     That is what CTUI-14's `host/key_journal.nim` is for, and this is the
##     suite that could not have been written honestly without it.
##   * **"the final screen" is RECONSTRUCTED FROM THE BYTE STREAM**, not read
##     off the live terminal. `--replay-keys` exits when the journal runs out,
##     and the exit leaves the alternate screen — at which point libvterm's
##     screen reverts to the primary one and the debugger's last frame is gone.
##     So each run's transcript is truncated at its alt-screen LEAVE and fed to
##     a fresh `nim_libvterm` screen: the same parser the live path uses, on the
##     bytes the binary actually wrote.
##   * **Equality is cell by cell, not text by text.** A comparison of
##     `contents()` alone would pass on two screens that differ only in colour,
##     and a diffed frame's whole risk is a stale style left behind by a run
##     that started encoding from the wrong place.
##
## ## AN EQUALITY IS A DIFFERENTIAL CHECK, so there are ABSOLUTE ones beside it
##
## `docs/tui-testing.md` states the limit and it applies here word for word: a
## comparison of two renderings of the same program is blind by construction to
## any defect the two share. Both runs drive the same diffing emitter, so a
## stale style or a column drift that happened identically in both would compare
## equal. Two things answer that:
##
##   * **In this file**, the final screen is asserted ABSOLUTELY as well —
##     §3.1's four pane titles, a glyph count, and `indexed:244`, which is what
##     `app/theme/degradation.ansi256Style(srChromeMuted)` publishes for the
##     rule every pane is drawn with. A diffed stream that lost its styles
##     reddens those whether or not the two runs agree.
##   * **Elsewhere in this lane**,
##     `tests/real_terminal/test_real_capability_negotiation.nim` asserts the
##     whole colour ladder absolutely against the live binary — and since
##     CTUI-14 that binary emits through `ssh_tuning`, so those assertions are
##     now assertions about the diffed path too.
##
## ## WHAT "A HIGH-LATENCY LINK" IS HERE, and why it is the reader and not the
## ## writer
##
## The link this front-end is tuned for is SSH, and what is slow about SSH is
## the round trip: the far end accepts bytes more slowly than the application
## produces them. A pty models that exactly — the harness simply stops reading,
## the master's buffer fills, and the child's `write(2)` blocks in
## `ssh_tuning.writeAll`'s retry loop. Nothing is faked and no clock is
## substituted; the child really does wait.
##
## That is also what makes the two runs take DIFFERENT PATHS through the
## emitter rather than merely different amounts of time. While a paint is
## blocked, the replay journal's next tokens are still pending, so
## `WriteCoalescer.hold` answers true and frames are merged. The slow run
## therefore emits FEWER, LARGER updates — and still has to arrive at the same
## screen, which is the property worth asserting.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[monotimes, options, os, strutils, times, unicode, unittest]

import nim_libvterm
import term_assert

import ../../app/cli
import ../../host/key_journal
import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 38

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  Cols = 120
  Rows = 40
  Steps = 100
    ## CTUI-14's own number.
  StallMs = 25
    ## How long the harness refuses to read, per stalled burst.
  StallEvery = 2
    ## One stall every this many read bursts, so the link is intermittently
    ## slow rather than uniformly throttled — which is what a real link is, and
    ## which is the shape that actually fills a pty buffer rather than merely
    ## slowing every read by the same amount.
  MinInjectedMs = 500
    ## THE FLOOR ON THE INJECTION ITSELF. The assertion that the slow run was
    ## slow is made on how long the HARNESS refused to read, not on how long
    ## the run took: measured on this host at load 57, one hundred steps took
    ## 53.4 s with no latency and 49.6 s with it, because the wall clock of a
    ## replay is dominated by the engine and by whatever else the machine is
    ## doing. A wall-clock comparison there would be a coin toss reported as a
    ## regression.

var tracePath = ""
var journalPath = ""


type
  RunResult = object
    exitCode: int
    bytes: int
    elapsedMs: int64
    injectedMs: int
      ## How long this run's harness deliberately refused to read. `0` for the
      ## zero-latency arm, by construction.
    stalls: int
    plain: string
    cells: seq[Cell]

var fast: RunResult
var slow: RunResult
  ## RUN ONCE AND SHARED, because one hundred replayed steps against a real
  ## engine is a minute of work on a loaded host and three cases wanting the
  ## same run is not a reason to pay for it three times.

proc reconstruct(transcript: string; cols, rows: int): (string, seq[Cell]) =
  ## The screen the child had painted at the moment it left the alternate
  ## screen, parsed by the same terminal state machine the live path uses.
  ##
  ## TRUNCATED AT THE LEAVE, because `CSI ? 1049 l` is what reverts libvterm to
  ## the primary screen — the debugger's last frame is not lost, it is
  ## *replaced*, and a naive replay of the whole transcript would compare two
  ## empty shells and call them equal.
  let cut = transcript.rfind(AltScreenLeaveSequence)
  let upTo = if cut >= 0: transcript[0 ..< cut] else: transcript
  var screen = newScreen(rows, cols)
  screen.feed(upTo)
  var cells: seq[Cell] = @[]
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      cells.add screen.cellAt(r, c)
  (screen.contents(), cells)

proc runReplay(stall: bool): RunResult =
  ## One `--replay-keys` session, with or without an artificially slow reader.
  ##
  ## The two arms differ in EXACTLY ONE THING — whether the harness pauses
  ## between reads — so anything that differs in the result is downstream of
  ## the link's speed and of nothing else.
  var sess = tuiSession(@["--replay-keys=" & journalPath, tracePath],
                        cols = Cols, rows = Rows)
  let started = getMonoTime()
  var bursts = 0
  var stalls = 0
  while sess.isAlive:
    discard sess.drainOutput(30)
    inc bursts
    if stall and bursts mod StallEvery == 0:
      # NOT READING IS THE INJECTION. The pty master's buffer fills and the
      # child blocks inside `write(2)`; there is no simulated delay anywhere.
      sleep(StallMs)
      inc stalls
  let status = sess.waitExit(initDuration(seconds = 60))
  let elapsedMs = (getMonoTime() - started).inMilliseconds
  let transcript = sess.transcriptBytes()
  let (plain, cells) = reconstruct(transcript, Cols, Rows)
  result = RunResult(
    exitCode: (if status.isSome: status.get() else: -1),
    bytes: transcript.len, elapsedMs: elapsedMs,
    injectedMs: stalls * StallMs, stalls: stalls, plain: plain, cells: cells)
  sess.close()

proc describeColor(c: Color): string =
  ## A colour as a string, WITHOUT touching a branch the discriminator does not
  ## select. `Color` is an object variant and `idx` is not accessible when
  ## `kind == ckDefault`; reading it raises `FieldDefect` — which is how the
  ## first version of this file turned a diagnosis into a crash.
  case c.kind
  of ckDefault: "default"
  of ckIndexed: "indexed:" & $c.idx
  of ckRgb: "#" & toHex(c.r.int, 2) & toHex(c.g.int, 2) & toHex(c.b.int, 2)

proc firstDifference(a, b: RunResult; cols: int): string =
  ## The first cell at which two screens disagree, named with both runes and
  ## both style sets.
  ##
  ## "The screens differ" is not a diagnosis, and `testing/dual_snap`'s
  ## cross-tier comparison never emits one; neither does this.
  if a.cells.len != b.cells.len:
    return "cell counts differ: " & $a.cells.len & " vs " & $b.cells.len
  for i in 0 ..< a.cells.len:
    if a.cells[i] != b.cells[i]:
      let row = i div cols
      let col = i mod cols
      return "row " & $row & " col " & $col & ": no-latency rune " &
             $int32(a.cells[i].rune) & " style " & $a.cells[i].attrs &
             " fg " & describeColor(a.cells[i].fg) &
             " vs latency rune " & $int32(b.cells[i].rune) & " style " &
             $b.cells[i].attrs & " fg " & describeColor(b.cells[i].fg)
  ""

suite "CTUI-14 Tier 2: a hundred steps over a link with injected delay":

  test "the binary, the fixture and the key journal this lane needs":
    if not fileExists(tuiBinary()):
      checkpoint("missing " & tuiBinary() & " — run `just build-tui`")
    ck fileExists(tuiBinary())
    let resolved = resolveFixture(FixtureName)
    if resolved.outcome != foRecorded:
      checkpoint("the `" & FixtureName & "` fixture is unavailable: " &
                 resolved.detail &
                 " — `just test-tui` records and caches it, or set $CT_BIN")
    ck resolved.outcome == foRecorded
    tracePath = resolved.tracePath
    ck dirExists(tracePath)

    # THE KEY SEQUENCE, WRITTEN ONCE. Both runs read this file, so "the same
    # key sequence" is a fact about the input rather than an intention about
    # the test.
    journalPath = lifecycle_support.repoRoot() / "test-logs" /
                  "ctui14-latency.keys"
    createDir(journalPath.parentDir)
    var lines = ""
    for _ in 0 ..< Steps:
      lines.add encodeToken("n") & "\n"
    writeFile(journalPath, lines)
    checkpoint("journal: " & journalPath)
    # …and it really parses back to the sequence it was written from, through
    # the SHIPPED reader rather than through a copy of it.
    let (tokens, problems) = parseJournal(readFile(journalPath))
    checkpoint("journal parses to " & $tokens.len & " token(s), " &
               $problems.len & " problem(s)")
    ck problems.len == 0
    ck tokens.len == Steps
    var stepTokens = 0
    for token in tokens:
      if token == "n":
        inc stepTokens
    ck stepTokens == Steps

  test "the final screen after 100 steps is the SAME over a slow link":
    # THE ZERO-LATENCY RUN, which is the oracle every claim below is against.
    fast = runReplay(stall = false)
    checkpoint("no latency: exit " & $fast.exitCode & ", " & $fast.bytes &
               " bytes in " & $fast.elapsedMs & " ms")
    ck fast.exitCode == ExitOk
    ck fast.injectedMs == 0
    # THE NON-VACUITY FLOOR, and it is the important one in this file: two
    # blank screens are equal. The reconstructed screen has to be the DEBUGGER.
    ck fast.plain.contains("SOURCE")
    ck fast.plain.contains("CALL STACK")
    ck fast.plain.contains("VARIABLES")
    ck fast.plain.contains("TIMELINE")
    ck fast.cells.len == Cols * Rows
    var fastGlyphs = 0
    for cell in fast.cells:
      if cell.rune != Rune(0) and cell.rune != Rune(' '):
        inc fastGlyphs
    checkpoint("non-blank cells on the no-latency screen: " & $fastGlyphs)
    ck fastGlyphs > 200

    # THE SLOW RUN, over the same journal.
    slow = runReplay(stall = true)
    checkpoint("with latency: exit " & $slow.exitCode & ", " & $slow.bytes &
               " bytes in " & $slow.elapsedMs & " ms, " & $slow.stalls &
               " stall(s) totalling " & $slow.injectedMs & " ms of refused" &
               " reads")
    ck slow.exitCode == ExitOk
    ck slow.cells.len == Cols * Rows

    # THE LINK REALLY WAS SLOW, asserted on the INJECTION rather than on the
    # wall clock. See `MinInjectedMs`: a replay's elapsed time is dominated by
    # the engine and by the host, and comparing two of them measures the
    # machine.
    ck slow.stalls > 0
    ck slow.injectedMs >= MinInjectedMs
    ck fast.stalls == 0

    # …AND THE SCREENS ARE EQUAL. Text first, because a text difference is the
    # one a reader can act on, and then cell by cell, because a stale style is
    # invisible in the text and is exactly what a diffed emitter risks.
    let textDiffers = fast.plain != slow.plain
    if textDiffers:
      checkpoint("NO-LATENCY TEXT:\n" & fast.plain)
      checkpoint("LATENCY TEXT:\n" & slow.plain)
    ck not textDiffers
    let cellDiff = firstDifference(fast, slow, Cols)
    if cellDiff.len > 0:
      checkpoint("FIRST DIFFERING CELL: " & cellDiff)
    ck cellDiff.len == 0
    checkpoint("bytes: " & $fast.bytes & " with no latency, " & $slow.bytes &
               " with it")

  test "the slow screen is right, and not merely the same as the fast one":
    # THE ABSOLUTE ARM. An equality between two runs of one program cannot see
    # a defect they share, so the final screen is also asserted against what it
    # is SUPPOSED to be — §3.1's furniture, and the published colour of the
    # rule every pane is drawn with.
    ck slow.cells.len == Cols * Rows
    ck slow.plain.contains("SOURCE")
    ck slow.plain.contains("VARIABLES")
    var glyphs = 0
    var mutedRule = 0
    var coloured = 0
    for cell in slow.cells:
      if cell.rune != Rune(0) and cell.rune != Rune(' '):
        inc glyphs
      if cell.fg.kind != ckDefault or cell.bg.kind != ckDefault:
        inc coloured
      if cell.fg.kind == ckIndexed and cell.fg.idx == 244'u8:
        inc mutedRule
    checkpoint("slow screen: " & $glyphs & " glyphs, " & $coloured &
               " coloured cells, " & $mutedRule & " at indexed:244")
    ck glyphs > 200
    ck coloured > 0
    # `indexed:244` is `degradation.ansi256Style(srChromeMuted)`'s published
    # value, and every pane rule is painted in it. A diffed stream that lost or
    # smeared its SGR transitions loses this while the two runs still agree.
    ck mutedRule > 0

  test "MUTATION ARM: the comparison can tell two screens apart":
    # A comparison that cannot be made to fail is indistinguishable from one
    # that is not reading its inputs. The SAME `firstDifference` and the same
    # cell projection are run over a screen with ONE cell changed.
    ck fast.cells.len == Cols * Rows

    var mutated = fast
    # Pick a cell that is actually painted, so the mutation changes something a
    # terminal would have shown.
    var target = -1
    for i in 0 ..< mutated.cells.len:
      if mutated.cells[i].rune != Rune(0) and mutated.cells[i].rune != Rune(' '):
        target = i
        break
    checkpoint("mutating cell " & $target)
    ck target >= 0
    mutated.cells[target].rune = Rune('X')
    let diff = firstDifference(fast, mutated, Cols)
    checkpoint("mutated comparison says: " & diff)
    ck diff.len > 0
    ck diff.contains("row " & $(target div Cols))
    ck diff.contains("col " & $(target mod Cols))
    # …and the UNMUTATED pair still compares equal, so the line above is about
    # the mutation.
    ck firstDifference(fast, fast, Cols).len == 0

    # THE TEXT COMPARISON HAS THE SAME ARM: a screen with one glyph changed is
    # not equal to the original.
    var mutatedText = fast.plain
    let at = mutatedText.find("SOURCE")
    ck at >= 0
    mutatedText[at] = 'X'
    ck mutatedText != fast.plain
    # …and a plain-text comparison ALONE would have missed a style-only
    # difference, which is why the cell comparison exists beside it.
    var styleOnly = fast
    styleOnly.cells[target].attrs = styleOnly.cells[target].attrs + {caBold}
    ck styleOnly.plain == fast.plain
    ck firstDifference(fast, styleOnly, Cols).len > 0

    # THE ARM THAT WOULD HAVE CAUGHT A COMPARISON READING NOTHING: two screens
    # of different sizes are reported as different rather than as equal.
    var truncated = fast
    truncated.cells.setLen(fast.cells.len - 1)
    ck firstDifference(fast, truncated, Cols).contains("cell counts differ")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
