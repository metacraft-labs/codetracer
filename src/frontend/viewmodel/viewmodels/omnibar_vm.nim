## viewmodels/omnibar_vm.nim — PLAT-48 deliverable 2. THE OMNIBAR AS LOGICAL
## STATE: its query, the mode the query puts it in, the ranked results, the
## selection, open or closed. One model; the desktop, the terminal and GPUI
## each draw it their own way.
##
## ## The modes are the desktop's, decided in ONE place
##
## The desktop's omnibar is its command palette (`ui/command.nim`), and what a
## query MEANS is decided by `ui/command_interpreter.parseQuery` from its
## prefix: `:grep …` searches the program text, `:sym …` symbols, `/ai …`
## talks to the agent, any other `:` is a command, and anything else is a file
## name. `classifyOmnibarQuery` is that decision as a pure function, and the
## desktop's `parseQuery` now calls it — so a query cannot mean one thing on
## the desktop and another in the terminal.
##
## One mode is added: `#<tick>` jumps to a tick. The terminal and GPUI offer
## it; the desktop's palette has no tick mode and still treats `#…` as a file
## name, which is stated here rather than discovered (see
## `desktopKindOf`).
##
## ## One ranking
##
## Results are ranked by `fuzzyScore` below, a subsequence matcher with
## word-start and adjacency bonuses, over the INDEX a front-end supplies
## (`setIndex`: the recording's files, its functions, the menu's commands).
## The terminal and GPUI hand it the same index for the same recording, so
## the same query gives the same list in both, in the same order — which is
## what the real-stack tests assert.
##
## Plain Nim, C and JavaScript backends, no signals (a host installs
## `onChange` to repaint).

import std/[algorithm, strutils]

type
  OmnibarMode* = enum
    omFile = "file"
    omSymbol = "symbol"
    omCommand = "command"
    omProgram = "program"
      ## Program text search (`:grep`), answered by the search service.
    omTick = "tick"
    omAgent = "agent"

  OmnibarEntry* = object
    ## One thing the omnibar can find.
    kind*: OmnibarMode
    label*: string
      ## What is matched and shown.
    detail*: string
      ## The second column: a directory, a location, a command's key.
    target*: string
      ## What choosing it does, in the front-end's own terms: a path, a
      ## `path:line`, a menu action id, a tick.

  OmnibarResult* = object
    entry*: OmnibarEntry
    score*: int
    matched*: seq[int]
      ## Byte offsets in `entry.label` the query matched, for highlighting.

  OmnibarVM* = ref object
    isOpen*: bool
    query*: string
    mode*: OmnibarMode
    needle*: string
      ## The query without its mode prefix: what is matched.
    index*: seq[OmnibarEntry]
    results*: seq[OmnibarResult]
    selected*: int
      ## Index into `results`, or -1 when there are none.
    limit*: int
    revision*: int
    onChange*: proc() {.closure.}

const
  OmnibarDefaultLimit* = 20
    ## The desktop palette's own limit (`COMMAND_FUZZY_OPTIONS.limit`).
  CommandPrefix* = ":"
  TickPrefix* = "#"

func classifyOmnibarQuery*(query: string): tuple[mode: OmnibarMode,
                                                  needle: string] =
  ## The mode a query puts the omnibar in, and the text that is matched.
  ## The desktop's `parseQuery` rule, in its order: `:grep` and `:sym` before
  ## the generic `:`, `/ai` for the agent, a lone `:` is still a file query
  ## (the desktop needs `query.len > 1` before it treats `:` as a command).
  let lower = query.toLowerAscii
  if lower.startsWith(CommandPrefix & "grep") and query.len > 1:
    return (omProgram, query[5 .. ^1].strip)
  if lower.startsWith(CommandPrefix & "sym") and query.len > 1:
    return (omSymbol, query[4 .. ^1].strip)
  if query.startsWith("/ai"):
    return (omAgent, query[3 .. ^1].strip)
  if query.startsWith(CommandPrefix) and query.len > 1:
    return (omCommand, query[1 .. ^1].strip)
  if query.startsWith(TickPrefix) and query.len > 1:
    var digits = true
    for ch in query[1 .. ^1].strip:
      if ch notin {'0' .. '9', ','}:
        digits = false
    if digits:
      return (omTick, query[1 .. ^1].strip.replace(",", ""))
  (omFile, query.strip)

func desktopKindOf*(mode: OmnibarMode): OmnibarMode =
  ## The mode the DESKTOP acts in for a classified query: its palette has no
  ## tick search, so `#…` stays a file query there.
  if mode == omTick: omFile else: mode

# ---------------------------------------------------------------------------
# The ranking
# ---------------------------------------------------------------------------

func isWordStart(s: string; i: int): bool =
  i == 0 or s[i - 1] in {'/', '_', '-', '.', ' ', ':', '\\'} or
    (s[i].isUpperAscii and not s[i - 1].isUpperAscii)

func fuzzyScore*(needle, label: string): tuple[ok: bool, score: int,
                                               matched: seq[int]] =
  ## Whether every character of `needle` occurs in `label` in order
  ## (case-insensitive), and how well: +1 per matched character, +8 when it
  ## starts a word, +5 when it follows the previous match directly, −1 per
  ## skipped character before the first match. Greedy left to right, with the
  ## word-start preference: a character is taken at the next word start that
  ## still leaves the rest matchable, else at its next occurrence.
  if needle.len == 0:
    return (true, 0, @[])
  let n = needle.toLowerAscii
  let l = label.toLowerAscii
  # Feasibility first, and the latest position each needle char may take.
  var latest = newSeq[int](n.len)
  var j = l.len - 1
  for k in countdown(n.high, 0):
    while j >= 0 and l[j] != n[k]:
      dec j
    if j < 0:
      return (false, 0, @[])
    latest[k] = j
    dec j
  var pos = 0
  var prev = -2
  for k in 0 ..< n.len:
    var chosen = -1
    var i = pos
    while i <= latest[k]:
      if l[i] == n[k]:
        if chosen < 0:
          chosen = i
        if isWordStart(label, i) or i == prev + 1:
          chosen = i
          break
      inc i
    result.matched.add chosen
    result.score += 1
    if isWordStart(label, chosen): result.score += 8
    if chosen == prev + 1: result.score += 5
    if k == 0: result.score -= chosen
    prev = chosen
    pos = chosen + 1
  result.ok = true

func cmpResult(a, b: OmnibarResult): int =
  ## Descending score, then the shorter label, then alphabetical — so the
  ## order is total and every front-end sorts the same way.
  if a.score != b.score:
    return cmp(b.score, a.score)
  if a.entry.label.len != b.entry.label.len:
    return cmp(a.entry.label.len, b.entry.label.len)
  cmp(a.entry.label, b.entry.label)

func rankOmnibar*(index: openArray[OmnibarEntry]; mode: OmnibarMode;
                  needle: string; limit = OmnibarDefaultLimit):
    seq[OmnibarResult] =
  ## The ranked results for one query. A tick query answers one entry, the
  ## tick itself; program and agent queries are answered by services, not by
  ## this index, and rank nothing here.
  case mode
  of omTick:
    if needle.len > 0:
      result.add OmnibarResult(entry: OmnibarEntry(
        kind: omTick, label: "Go to tick " & needle, detail: "",
        target: needle), score: 0)
    return
  of omProgram, omAgent:
    return
  else:
    discard
  for e in index:
    if e.kind != mode:
      continue
    let s = fuzzyScore(needle, e.label)
    if s.ok:
      result.add OmnibarResult(entry: e, score: s.score, matched: s.matched)
  result.sort(cmpResult)
  if limit > 0 and result.len > limit:
    result.setLen(limit)

# ---------------------------------------------------------------------------
# The model
# ---------------------------------------------------------------------------

proc changed(vm: OmnibarVM) =
  inc vm.revision
  if not vm.onChange.isNil:
    vm.onChange()

proc newOmnibarVM*(limit = OmnibarDefaultLimit): OmnibarVM =
  OmnibarVM(limit: limit, selected: -1, mode: omFile)

proc rerank(vm: OmnibarVM) =
  let (mode, needle) = classifyOmnibarQuery(vm.query)
  vm.mode = mode
  vm.needle = needle
  vm.results = rankOmnibar(vm.index, mode, needle, vm.limit)
  vm.selected = if vm.results.len > 0: 0 else: -1

proc setIndex*(vm: OmnibarVM; index: seq[OmnibarEntry]) =
  ## Replace what can be found (the recording's files and functions, the
  ## menu's commands). Re-ranks the open query.
  vm.index = index
  vm.rerank()
  vm.changed()

proc open*(vm: OmnibarVM; query = "") =
  ## Show the omnibar; `query` pre-fills a mode (`":sym "` for Find Symbol).
  vm.isOpen = true
  vm.query = query
  vm.rerank()
  vm.changed()

proc close*(vm: OmnibarVM) =
  vm.isOpen = false
  vm.query = ""
  vm.needle = ""
  vm.mode = omFile
  vm.results = @[]
  vm.selected = -1
  vm.changed()

proc setQuery*(vm: OmnibarVM; query: string) =
  vm.query = query
  vm.rerank()
  vm.changed()

proc typeText*(vm: OmnibarVM; text: string) =
  vm.setQuery(vm.query & text)

proc backspace*(vm: OmnibarVM) =
  if vm.query.len == 0:
    return
  # Drop one UTF-8 character.
  var cut = vm.query.len - 1
  while cut > 0 and (ord(vm.query[cut]) and 0xC0) == 0x80:
    dec cut
  vm.setQuery(vm.query[0 ..< cut])

proc moveSelection*(vm: OmnibarVM; delta: int) =
  ## `Down` / `Up`: the next / previous result, clamped.
  if vm.results.len == 0:
    vm.selected = -1
  else:
    vm.selected = max(0, min(vm.results.high,
                             (if vm.selected < 0: 0 else: vm.selected + delta)))
  vm.changed()

proc select*(vm: OmnibarVM; index: int) =
  if index >= 0 and index < vm.results.len:
    vm.selected = index
    vm.changed()

proc selectedResult*(vm: OmnibarVM): OmnibarResult =
  if vm.selected < 0 or vm.selected >= vm.results.len:
    return OmnibarResult(entry: OmnibarEntry(kind: vm.mode))
  vm.results[vm.selected]

proc accept*(vm: OmnibarVM): tuple[ok: bool, entry: OmnibarEntry] =
  ## `Enter`: the chosen entry, and the omnibar closes. `ok` is false when
  ## nothing was selected (the omnibar stays open, so the user can see why).
  if vm.selected < 0 or vm.selected >= vm.results.len:
    return (false, OmnibarEntry(kind: vm.mode))
  result = (true, vm.results[vm.selected].entry)
  vm.close()

proc resultLabels*(vm: OmnibarVM): seq[string] =
  for r in vm.results:
    result.add r.entry.label
