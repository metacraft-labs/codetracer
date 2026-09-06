## test_incremental_search.nim — CTUI-10, Tier 1.
##
## ## What this suite is for
##
## CTUI-10: *"live match count updates per keystroke; `n`/`N` cycle forward and
## backward including wraparound."* §3.3.6 asks for the count in so many words:
## *"Prompt `/` for searching text across source code or event logs with
## real-time match count."*
##
## ## THE TEXT IS REAL AND THE COUNT HAS AN INDEPENDENT ORACLE
##
## The lines searched are `test-programs/noir_space_ship/src/shield.nr` — the
## program CTUI-1's fixture records, checked into this repository. A missing
## file FAILS by name; it is not a prerequisite anyone installs.
##
## The expected match count is computed with `std/strutils.count`, which is not
## the code under test and does not share a line of it. That matters because
## `search.findMatches` returns POSITIONS and a count derived from its own
## output would be the same walk twice. `count(s, sub)` is non-overlapping by
## default, which is exactly the rule `matchesInLine`'s header states and which
## the `aaaa` case below pins independently of the fixture.
##
## ## `n` AND `N` ARE ASSERTED AS A CYCLE, NOT AS TWO STEPS
##
## The whole ring is walked — `matches.len` presses of `n` must return the
## cursor to where it started, and exactly one of them must set `wrapped` — and
## then the same ring is walked backwards. Two presses would pass over a `next`
## that skipped an entry, because nothing would ever compare the tour's length
## to the match count.
##
## ## THE DIRECTION IS PART OF `n`
##
## After `?query`, `n` walks BACKWARD. That is Vim's rule, and it is
## `search.nim`'s reading of §4.2's single "Next / Prev Search Match" row.
## Asserted
## here in both directions over the same match set, so the two prompts differ in
## exactly one thing.
##
## ## Templates, not procs, for anything that calls `check`

import std/[algorithm, os, strutils, unittest]

import ../views/search

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 490

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureSource = "test-programs/noir_space_ship/src/shield.nr"

  Query = "shield"
    ## A word this program uses in identifiers, parameters and comments, so the
    ## match set has an interior and `n` has somewhere to go.
  RareQuery = "regeneration"
  AbsentQuery = "quaternion"

  ExpectedFixtureLines = 68
    ## What `splitLines` answers for `shield.nr` on 2026-09-06 — 67 lines of
    ## text plus the empty tail after its final newline. Asserted so a
    ## truncated read is red here rather than quietly searching less.

# ---------------------------------------------------------------------------

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir()
  for _ in 0 ..< 5:
    dir = dir.parentDir()
  dir

proc fixtureLines(): seq[string] =
  let path = repoRoot() / FixtureSource
  if not fileExists(path):
    raise newException(IOError,
      "the fixture program is missing: " & path & " does not exist. " &
      "`test-programs/noir_space_ship/` is checked into THIS repository — " &
      "its absence is a broken checkout, not a missing prerequisite, and " &
      "there is nothing to skip.")
  readFile(path).splitLines()

proc oracleCount(lines: openArray[string]; query: string;
                 caseSensitive: bool): int =
  ## The expected number of matches, computed with `std/strutils.count`.
  ## THE INDEPENDENT ORACLE — see this file's header.
  result = 0
  if query.len == 0:
    return
  for line in lines:
    if caseSensitive:
      result += line.count(query)
    else:
      result += line.toLowerAscii.count(query.toLowerAscii)

let lines = fixtureLines()

suite "CTUI-10: incremental search counts live and cycles both ways":

  test "the searched text is the recorded program's own source":
    checkpoint("fixture: " & repoRoot() / FixtureSource)
    ck fileExists(repoRoot() / FixtureSource)
    ck lines.len == ExpectedFixtureLines
    # The text really contains what the queries below look for, which is what
    # makes every "N matches" assertion a statement rather than a tautology.
    ck oracleCount(lines, Query, false) > 1
    ck oracleCount(lines, RareQuery, false) > 0
    ck oracleCount(lines, AbsentQuery, false) == 0

  test "the count is live, and it is the oracle's":
    var model = initSearchModel(sscSource, sdirForward)
    ck model.matchCountText() == EmptyQueryText
    ck model.matches.len == 0
    ck model.current == -1

    # ONE KEYSTROKE AT A TIME, with the count read after each.
    var typed = ""
    var counts: seq[int] = @[]
    var oracles: seq[int] = @[]
    var keystrokes = 0
    for ch in Query:
      inc keystrokes
      typed.add ch
      counts.add model.updateQuery(lines, typed)
      oracles.add oracleCount(lines, typed, false)
      ck model.query == typed
      ck model.matches.len == counts[^1]
    checkpoint("per-keystroke counts: " & $counts)
    checkpoint("oracle:               " & $oracles)
    ck keystrokes == Query.len
    ck counts.len == Query.len
    ck counts == oracles
    # THE SWEEP'S OWN SIZE against its parameter, not against a run.
    ck keystrokes == typed.len
    # …and it really narrowed: the first keystroke matches more than the last.
    ck counts[0] > counts[^1]
    ck counts[^1] > 0
    # Monotonically non-increasing, because every keystroke adds a constraint.
    var widened = 0
    for i in 1 ..< counts.len:
      if counts[i] > counts[i - 1]:
        inc widened
    ck widened == 0

    # DELETING A CHARACTER WIDENS IT AGAIN — which is the property a search
    # that only re-filtered its previous result set would get wrong, and the
    # reason `updateQuery` recomputes from the lines every time.
    var shrinking = typed
    var back: seq[int] = @[]
    for _ in 0 ..< Query.len - 1:
      shrinking.setLen(shrinking.len - 1)
      back.add model.updateQuery(lines, shrinking)
    checkpoint("counts while deleting: " & $back)
    ck back.len == Query.len - 1
    ck back == counts[0 ..< counts.len - 1].reversed()
    ck back[^1] == counts[0]

  test "every match is where the line says it is":
    let matches = findMatches(lines, Query, false)
    ck matches.len == oracleCount(lines, Query, false)
    var verified = 0
    var lastKey = (-1, -1)
    for m in matches:
      # THE POSITION IS REAL: the line the match names really contains the
      # query at the cell column it names.
      ck m.line >= 1
      ck m.line <= lines.len
      let text = lines[m.line - 1]
      let slice = cellSlice(text, m.column, m.column + m.length)
      if slice.toLowerAscii == Query.toLowerAscii:
        inc verified
      ck m.length == Query.len
      # DOCUMENT ORDER, strictly ascending by (line, column).
      ck m.line > lastKey[0] or (m.line == lastKey[0] and m.column > lastKey[1])
      lastKey = (m.line, m.column)
    checkpoint("verified positions: " & $verified & " of " & $matches.len)
    ck verified == matches.len
    ck matches.len > 1

    # CASE SENSITIVITY IS A FIELD, and it changes the answer on this text.
    let sensitive = findMatches(lines, "Shield", true)
    let insensitive = findMatches(lines, "Shield", false)
    checkpoint("`Shield` sensitive " & $sensitive.len & " insensitive " &
               $insensitive.len)
    ck sensitive.len == oracleCount(lines, "Shield", true)
    ck insensitive.len == oracleCount(lines, "Shield", false)
    ck insensitive.len > sensitive.len

    # NON-OVERLAPPING, pinned away from the fixture so the rule is asserted
    # rather than inherited: `aa` in `aaaa` is two, and `std/strutils.count`
    # agrees.
    let overlapping = findMatches(@["aaaa"], "aa", true)
    ck overlapping.len == 2
    ck overlapping.len == "aaaa".count("aa")
    ck overlapping[0].column == 0
    ck overlapping[1].column == 2
    # An empty query matches NOTHING rather than everything, which is what
    # keeps `[0/0]` off the screen before the first keystroke.
    ck findMatches(lines, "", false).len == 0

  test "`n` walks the whole ring forward and wraps exactly once":
    var model = initSearchModel(sscSource, sdirForward)
    let total = model.updateQuery(lines, Query)
    ck total > 2
    ck model.commit(1)
    ck model.current == 0
    ck not model.wrapped
    ck model.matchCountText() == "[1/" & $total & "]"

    var visited: seq[int] = @[]
    var wraps = 0
    var presses = 0
    for _ in 0 ..< total:
      inc presses
      let (moved, m) = model.nextMatch()
      ck moved
      visited.add model.current
      if model.wrapped:
        inc wraps
      # The match the model reports IS the one at the cursor.
      ck m == model.matches[model.current]
    checkpoint("forward tour: " & $visited & " with " & $wraps & " wrap(s)")
    ck presses == total
    ck visited.len == total
    # A FULL TOUR RETURNS TO THE START, and visits every index exactly once.
    ck model.current == 0
    var seen = newSeq[int](total)
    for idx in visited:
      inc seen[idx]
    var visitedOnce = 0
    for n in seen:
      if n == 1:
        inc visitedOnce
    ck visitedOnce == total
    # EXACTLY ONE WRAP in a single tour — more would mean the walk skipped the
    # end, none would mean it never reached it.
    ck wraps == 1
    ck model.wrapNotice() == WrappedForwardText

  test "`N` is the exact inverse of `n`":
    var model = initSearchModel(sscSource, sdirForward)
    let total = model.updateQuery(lines, Query)
    ck model.commit(1)
    let start = model.current

    var forward: seq[int] = @[]
    for _ in 0 ..< total:
      discard model.nextMatch()
      forward.add model.current
    ck model.current == start

    var backward: seq[int] = @[]
    for _ in 0 ..< total:
      discard model.prevMatch()
      backward.add model.current
    ck model.current == start
    checkpoint("forward  " & $forward)
    checkpoint("backward " & $backward)
    ck forward.len == total
    ck backward.len == total
    # The backward tour is the forward tour reversed, shifted by one — which is
    # what "exact inverse" means for a ring.
    var expected: seq[int] = @[]
    for i in countdown(total - 2, 0):
      expected.add forward[i]
    expected.add forward[^1]
    ck backward == expected
    # …and one `n` followed by one `N` is a no-op, from anywhere on the ring.
    var roundTrips = 0
    for _ in 0 ..< total:
      let before = model.current
      discard model.nextMatch()
      discard model.prevMatch()
      if model.current == before:
        inc roundTrips
      discard model.nextMatch()
    ck roundTrips == total

  test "`?` makes `n` walk backward, over the same match set":
    var forward = initSearchModel(sscSource, sdirForward)
    var backward = initSearchModel(sscSource, sdirBackward)
    let f = forward.updateQuery(lines, Query)
    let b = backward.updateQuery(lines, Query)
    # ONE MATCH SET: the order is a property of the text, the direction of the
    # walk. That is why `?` and `/` can share `findMatches`.
    ck f == b
    ck forward.matches == backward.matches

    ck forward.commit(1)
    ck backward.commit(lines.len)
    ck forward.current == 0
    ck backward.current == backward.matches.high
    ck not forward.wrapped
    ck not backward.wrapped

    discard forward.nextMatch()
    discard backward.nextMatch()
    checkpoint("after one `n`: forward " & $forward.current & " backward " &
               $backward.current)
    ck forward.current == 1
    ck backward.current == backward.matches.high - 1
    # …and `N` in the backward search moves the way `n` does in the forward one.
    discard backward.prevMatch()
    ck backward.current == backward.matches.high
    ck $sdirForward == "/"
    ck $sdirBackward == "?"

    # COMMIT WRAPS AND SAYS SO, in both directions.
    var late = initSearchModel(sscSource, sdirForward)
    discard late.updateQuery(lines, Query)
    ck late.commit(lines.len + 100)
    ck late.wrapped
    ck late.current == 0
    ck late.wrapNotice() == WrappedForwardText
    var early = initSearchModel(sscSource, sdirBackward)
    discard early.updateQuery(lines, Query)
    ck early.commit(0)
    ck early.wrapped
    ck early.current == early.matches.high
    ck early.wrapNotice() == WrappedBackwardText

  test "a query with no match is reported, and moves nothing":
    var model = initSearchModel(sscSource, sdirForward)
    ck model.updateQuery(lines, AbsentQuery) == 0
    ck model.matchCountText() == NoMatchesText
    ck not model.commit(1)
    ck model.current == -1
    let (moved, _) = model.nextMatch()
    ck not moved
    ck model.current == -1
    ck not model.wrapped
    ck model.wrapNotice() == ""
    ck model.currentMatch()[0] == false
    ck model.matchesOnLine(1).len == 0
    # THE POSITIVE TWIN through the same calls: a query that DOES match.
    ck model.updateQuery(lines, RareQuery) == oracleCount(lines, RareQuery,
                                                          false)
    ck model.commit(1)
    ck model.currentMatch()[0]
    ck model.matchCountText().startsWith("[1/")
    let (hasOne, one) = model.currentMatch()
    ck hasOne
    ck model.matchesOnLine(one.line).len >= 1

    # A SINGLE MATCH is a ring of one: `n` succeeds and stays, and it wraps.
    var single = initSearchModel(sscSource, sdirForward)
    let uniqueLine = "let quaternion_marker = 1;"
    ck single.updateQuery(@[uniqueLine], "quaternion") == 1
    ck single.commit(1)
    ck single.current == 0
    let (movedOne, _) = single.nextMatch()
    ck movedOne
    ck single.current == 0
    ck single.wrapped
    ck single.matchCountText() == "[1/1]"

  test "the status line shows the sigil, the query and the count":
    var model = initSearchModel(sscSource, sdirForward)
    let total = model.updateQuery(lines, Query)
    discard model.commit(1)
    let text = searchStatusText(model, 60)
    checkpoint("status: '" & text & "'")
    ck cellWidthOf(text) == 60
    ck text.startsWith("/" & Query)
    ck text.contains("[1/" & $total & "]")
    ck not text.contains(WrappedForwardText)
    # …and once it wraps, the notice is there.
    for _ in 0 ..< total:
      discard model.nextMatch()
    let wrappedText = searchStatusText(model, 90)
    checkpoint("status after a full tour: '" & wrappedText & "'")
    ck model.wrapped
    ck wrappedText.contains(WrappedForwardText)
    ck cellWidthOf(wrappedText) == 90
    # A zero-width line is empty rather than a crash.
    ck searchStatusText(model, 0) == ""
    # The backward sigil is the other one.
    var back = initSearchModel(sscSource, sdirBackward)
    discard back.updateQuery(lines, Query)
    ck searchStatusText(back, 40).startsWith("?" & Query)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
