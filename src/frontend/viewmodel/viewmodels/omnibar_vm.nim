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
## ## The text it shows when empty, and its caret (PLAT-49)
##
## `OmnibarPlaceholder` is the one placeholder every front-end draws in the
## empty field — the desktop's palette input, the terminal's top-bar field and
## GPUI's — so the three cannot word it differently. The query is edited at a
## CARET (`cursor`, a byte offset), in INSERT or OVERWRITE mode (`overwrite`,
## toggled by the Insert key): the terminal shows the caret as a thin bar in
## insert mode and a block in overwrite mode, the way an editor does.
##
## ## A selected seed (PLAT-70 Part D)
##
## A field can open with part of its text SELECTED (`openSelected`): Find in
## Files' field — on the terminal and GPUI the omnibar's `:grep` line — opens
## seeded with the editor's selection, and the seed is selected so that typing
## replaces it (Find-And-Incremental-Search.md §5.2, VS Code's search view).
## The selection is the text between `anchor` and `cursor`; typing, `Delete`
## and `Backspace` replace or remove it, and a caret move ends it. Every
## front-end draws it on its selection ground.
##
## Plain Nim, C and JavaScript backends, no signals (a host installs
## `onChange` to repaint).

import std/[algorithm, sets, strutils]

import ../keymap/scope_path

type
  OmnibarMode* = enum
    omFile = "file"
    omSymbol = "symbol"
    omCommand = "command"
    omProgram = "program"
      ## Program text search (`:grep`), answered by the search service.
    omTick = "tick"
    omAgent = "agent"
    omRecording = "recording"
      ## PLAT-49 part B: a recording to open IN A NEW SESSION TAB — the
      ## session strip's "+" (the desktop's `.session-tab-add`, "New tab")
      ## opens the omnibar on `:open `; the entries are the recordings the
      ## host can see, and a typed path is one too.
    omAttach = "attach"
      ## PLAT-54 (DeepReview-GUI.md §2.2.7): a file or folder to ATTACH to the
      ## agent's next prompt — the native front-ends' answer to the desktop
      ## prompt's *Upload attachment* / *Files & folders*, whose system file
      ## dialog a terminal does not have. The entries are the files the
      ## omnibox finds and their folders; a typed path is one too.
    omAttachRecording = "attach-recording"
      ## PLAT-54: a recording to attach to the agent's next prompt (the
      ## desktop's *Recording / trace*): the recordings the host can see, and
      ## a typed path.
    omBuildTask = "build-task"
      ## Build-Output-Pane.md §3.11, §3.12: the BUILD TASK PICKER — `:build:`
      ## (what `Ctrl+Shift+B` opens). The entries are the project's tasks and
      ## the pane's commands (`build_tasks.buildTaskEntries`), which a host
      ## hands the omnibar with `setBuildTasks`.

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
    cursor*: int
      ## PLAT-49: the caret, as a byte offset into `query` (always on a
      ## character boundary). Typing inserts (or overwrites) there.
    overwrite*: bool
      ## PLAT-49: typing replaces the character under the caret instead of
      ## inserting before it. Toggled by `toggleOverwrite` (the Insert key).
    anchor*: int
      ## PLAT-70 Part D: the other end of the selected text, a byte offset
      ## into `query`, or -1 when no text is selected (see the header).
    limit*: int
    buildTasks*: seq[OmnibarEntry]
      ## The build task picker's entries (`omBuildTask`), kept apart from
      ## `index` because they are the project's, not the recording's, and
      ## are read again whenever the picker opens.
    revision*: int
    onChange*: proc() {.closure.}

const
  OmnibarDefaultLimit* = 20
    ## The desktop palette's own limit (`COMMAND_FUZZY_OPTIONS.limit`).
  CommandPrefix* = ":"
  OpenRecordingQuery* = ":open "
    ## PLAT-49 part B: what the session strip's "+" opens the omnibar on.
  AttachQuery* = ":attach "
    ## PLAT-54: what the Agent Activity prompt's *Upload attachment* and
    ## *Files & folders* open the omnibar on.
  AttachRecordingQuery* = ":attach-recording "
    ## PLAT-54: what its *Recording / trace* opens the omnibar on.
  BuildTaskPrefix* = ":build:"
    ## Build-Output-Pane.md §3.12: `:build: <task>` — the colon after the verb
    ## is what tells a task from `:build <command>`.
  TickPrefix* = "#"
  OmnibarPlaceholder* = "Navigate to file or run a :command"
    ## PLAT-49: what every front-end's empty omnibar field shows — the
    ## desktop's palette wording, now read from here by the desktop, the
    ## terminal and GPUI alike.

func paletteQueryOf*(operation: string): tuple[ok: bool, query: string] =
  ## PLAT-68: the query a palette-opening OPERATION opens the omnibar on —
  ## every front-end's (CUA-Keymap.md §3.8). The omnibar is this product's
  ## one palette: files and `:commands` from an empty field, symbols from
  ## `:sym `. `palette.go-to-line` has no omnibar mode and is not one of
  ## these.
  case operation
  of "palette.quick-open-file", "palette.open-commands": (true, "")
  of "palette.go-to-symbol", "palette.go-to-symbol-in-file":
    (true, CommandPrefix & "sym ")
  else: (false, "")

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
  for (prefix, mode) in [(AttachRecordingQuery.strip, omAttachRecording),
                         (AttachQuery.strip, omAttach)]:
    if lower.startsWith(prefix) and
       (query.len == prefix.len or query[prefix.len] == ' '):
      return (mode, query[prefix.len .. ^1].strip)
  if lower.startsWith(BuildTaskPrefix):
    return (omBuildTask, query[BuildTaskPrefix.len .. ^1].strip)
  if lower.startsWith(OpenRecordingQuery.strip) and
     (query.len == OpenRecordingQuery.strip.len or
      query[OpenRecordingQuery.strip.len] == ' '):
    return (omRecording, query[OpenRecordingQuery.strip.len .. ^1].strip)
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


func paletteFieldOf*(query: string): ScopeElement =
  ## The palette's field as a scope element: Find in Files' query field while
  ## the line is `:grep` (the terminal's and GPUI's field for the pane,
  ## Find-And-Incremental-Search.md §5.2, so its toggle keys hold there),
  ## else the palette's own field.
  if classifyOmnibarQuery(query).mode == omProgram:
    element(ekInput, SearchQueryInput)
  else:
    element(ekInput, PaletteQueryInput)

func desktopKindOf*(mode: OmnibarMode): OmnibarMode =
  ## The mode the DESKTOP acts in for a classified query: its palette has no
  ## tick search, so `#…` stays a file query there; its "+" opens a new tab
  ## on its welcome screen, so `:open …` stays a command there.
  if mode == omTick: omFile
  elif mode in {omRecording, omAttach, omAttachRecording}: omCommand
  # `:build: …` stays the picker: the desktop's palette lists the same
  # entries (`ui/command_interpreter`).
  else: mode

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
  of omBuildTask:
    # THE PICKER'S OWN ORDER with nothing typed (the default task first, so
    # `Ctrl+Shift+B` `Enter` runs it); ranked once something is.
    for e in index:
      if e.kind != omBuildTask:
        continue
      let s = fuzzyScore(needle, e.label)
      if s.ok:
        result.add OmnibarResult(entry: e, score: s.score, matched: s.matched)
    if needle.len > 0:
      result.sort(cmpResult)
    if limit > 0 and result.len > limit:
      result.setLen(limit)
    return
  of omRecording:
    # A TYPED PATH IS A RECORDING TOO, offered first: the host checks it is
    # one when it is opened (`native_host.openLocalTrace`).
    if needle.contains('/'):
      result.add OmnibarResult(entry: OmnibarEntry(
        kind: omRecording, label: "Open " & needle & " in a new tab",
        detail: "path", target: needle), score: high(int))
  of omAttach, omAttachRecording:
    # A TYPED PATH IS ATTACHED AS TYPED, offered first: the host checks it
    # exists when it is attached (`native_agent_host.attachContext`).
    if needle.contains('/'):
      result.add OmnibarResult(entry: OmnibarEntry(
        kind: mode, label: "Attach " & needle, detail: "path",
        target: needle), score: high(int))
  else:
    discard
  # What each mode finds: its own entries — except the attach modes, which
  # find the files (and their folders) or the recordings the index holds.
  let source = case mode
               of omAttach: omFile
               of omAttachRecording: omRecording
               else: mode
  var folders = initHashSet[string]()
  for e in index:
    if e.kind != source:
      continue
    if mode == omAttach:
      # Each indexed file's folder is a candidate too (*Files & folders*).
      let slash = e.target.rfind('/')
      if slash > 0:
        let dir = e.target[0 ..< slash]
        if not folders.containsOrIncl(dir):
          let fs = fuzzyScore(needle, dir & "/")
          if fs.ok:
            result.add OmnibarResult(entry: OmnibarEntry(
              kind: omAttach, label: dir & "/", detail: "folder",
              target: dir), score: fs.score, matched: fs.matched)
    let s = fuzzyScore(needle, e.label)
    if s.ok:
      var found = e
      found.kind = mode   # an attach mode's entry says what choosing it does
      result.add OmnibarResult(entry: found, score: s.score,
                               matched: s.matched)
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
  OmnibarVM(limit: limit, selected: -1, mode: omFile, anchor: -1)

proc rerank(vm: OmnibarVM) =
  let (mode, needle) = classifyOmnibarQuery(vm.query)
  vm.mode = mode
  vm.needle = needle
  vm.results =
    if mode == omBuildTask: rankOmnibar(vm.buildTasks, mode, needle, vm.limit)
    else: rankOmnibar(vm.index, mode, needle, vm.limit)
  vm.selected = if vm.results.len > 0: 0 else: -1

proc setIndex*(vm: OmnibarVM; index: seq[OmnibarEntry]) =
  ## Replace what can be found (the recording's files and functions, the
  ## menu's commands). Re-ranks the open query.
  vm.index = index
  vm.rerank()
  vm.changed()

proc setBuildTasks*(vm: OmnibarVM; entries: seq[OmnibarEntry]) =
  ## The build task picker's entries (`build_tasks.buildTaskEntries`).
  vm.buildTasks = entries
  vm.rerank()
  vm.changed()

proc open*(vm: OmnibarVM; query = "") =
  ## Show the omnibar; `query` pre-fills a mode (`":sym "` for Find Symbol).
  ## The caret goes to the end, in insert mode.
  vm.isOpen = true
  vm.query = query
  vm.cursor = query.len
  vm.anchor = -1
  vm.overwrite = false
  vm.rerank()
  vm.changed()

proc openSelected*(vm: OmnibarVM; prefix, seed: string) =
  ## PLAT-70 Part D: open on `prefix & seed` with `seed` SELECTED, the caret
  ## at its end — the first character typed replaces the seed and keeps the
  ## prefix (`:grep ` for Find in Files' field, §5.2). An empty seed selects
  ## nothing.
  vm.open(prefix & seed)
  if seed.len > 0:
    vm.anchor = prefix.len
    vm.changed()

proc close*(vm: OmnibarVM) =
  vm.isOpen = false
  vm.query = ""
  vm.cursor = 0
  vm.anchor = -1
  vm.overwrite = false
  vm.needle = ""
  vm.mode = omFile
  vm.results = @[]
  vm.selected = -1
  vm.changed()

proc setQuery*(vm: OmnibarVM; query: string) =
  ## Replace the query; the caret goes to its end, nothing selected.
  vm.query = query
  vm.cursor = query.len
  vm.anchor = -1
  vm.rerank()
  vm.changed()

func nextBoundary(s: string; i: int): int =
  ## The byte offset of the character after the one starting at `i`.
  result = min(s.len, i + 1)
  while result < s.len and (ord(s[result]) and 0xC0) == 0x80:
    inc result

func prevBoundary(s: string; i: int): int =
  ## The byte offset of the character before `i`.
  result = max(0, i - 1)
  while result > 0 and (ord(s[result]) and 0xC0) == 0x80:
    dec result

func selectedSpan*(vm: OmnibarVM): tuple[a, b: int] =
  ## PLAT-70 Part D: the selected text as byte offsets `[a, b)` into `query`,
  ## `(-1, -1)` when nothing is selected.
  if vm.anchor < 0 or vm.anchor == vm.cursor:
    return (-1, -1)
  let a = max(0, min(min(vm.anchor, vm.cursor), vm.query.len))
  let b = max(0, min(max(vm.anchor, vm.cursor), vm.query.len))
  if a < b: (a, b) else: (-1, -1)

func selectedText*(vm: OmnibarVM): string =
  let (a, b) = vm.selectedSpan
  if a < 0: "" else: vm.query[a ..< b]

proc removeSelected(vm: OmnibarVM): bool =
  ## The selected text taken out, the caret where it began; whether there
  ## was any.
  let (a, b) = vm.selectedSpan
  vm.anchor = -1
  if a < 0:
    return false
  vm.query = vm.query[0 ..< a] & vm.query[b .. ^1]
  vm.cursor = a
  true

proc typeText*(vm: OmnibarVM; text: string) =
  ## Insert `text` at the caret — or, in overwrite mode, put it in place of
  ## the character under the caret (at the end there is none, so it appends).
  ## Selected text is replaced by it (PLAT-70 Part D).
  if vm.removeSelected():
    let at = vm.cursor
    vm.query = vm.query[0 ..< at] & text & vm.query[at .. ^1]
    vm.cursor = at + text.len
    vm.rerank()
    vm.changed()
    return
  let at = max(0, min(vm.cursor, vm.query.len))
  let stop = if vm.overwrite and at < vm.query.len: nextBoundary(vm.query, at)
             else: at
  vm.query = vm.query[0 ..< at] & text & vm.query[stop .. ^1]
  vm.cursor = at + text.len
  vm.rerank()
  vm.changed()

proc backspace*(vm: OmnibarVM) =
  ## Delete the character before the caret, or the selected text.
  if vm.removeSelected():
    vm.rerank()
    vm.changed()
    return
  let at = max(0, min(vm.cursor, vm.query.len))
  if at == 0:
    return
  let cut = prevBoundary(vm.query, at)
  vm.query = vm.query[0 ..< cut] & vm.query[at .. ^1]
  vm.cursor = cut
  vm.rerank()
  vm.changed()

proc deleteForward*(vm: OmnibarVM) =
  ## `Delete`: remove the character under the caret, or the selected text.
  if vm.removeSelected():
    vm.rerank()
    vm.changed()
    return
  let at = max(0, min(vm.cursor, vm.query.len))
  if at >= vm.query.len:
    return
  vm.query = vm.query[0 ..< at] & vm.query[nextBoundary(vm.query, at) .. ^1]
  vm.rerank()
  vm.changed()

proc moveCursor*(vm: OmnibarVM; delta: int) =
  ## `Left` / `Right`: one character at a time, clamped to the query. With
  ## text selected, the caret goes to the selection's start (`Left`) or end
  ## (`Right`) and the selection ends, as in every text field.
  let (a, b) = vm.selectedSpan
  if a >= 0 and delta != 0:
    vm.anchor = -1
    vm.cursor = if delta < 0: a else: b
    vm.changed()
    return
  vm.anchor = -1
  var at = max(0, min(vm.cursor, vm.query.len))
  for _ in 0 ..< abs(delta):
    at = if delta > 0: nextBoundary(vm.query, at) else: prevBoundary(vm.query, at)
  if at != vm.cursor:
    vm.cursor = at
    vm.changed()

proc cursorHome*(vm: OmnibarVM) =
  if vm.anchor >= 0:
    vm.anchor = -1
    vm.changed()
  if vm.cursor != 0:
    vm.cursor = 0
    vm.changed()

proc cursorEnd*(vm: OmnibarVM) =
  if vm.anchor >= 0:
    vm.anchor = -1
    vm.changed()
  if vm.cursor != vm.query.len:
    vm.cursor = vm.query.len
    vm.changed()

proc toggleOverwrite*(vm: OmnibarVM) =
  ## `Insert`: switch between inserting and overwriting.
  vm.overwrite = not vm.overwrite
  vm.changed()

func charsBefore(s: string; offset: int): int =
  var i = 0
  while i < min(offset, s.len):
    i = nextBoundary(s, i)
    inc result

func cursorChars*(vm: OmnibarVM): int =
  ## The caret as a CHARACTER index (what a renderer counts cells by).
  charsBefore(vm.query, vm.cursor)

func selectedChars*(vm: OmnibarVM): tuple[a, b: int] =
  ## PLAT-70 Part D: the selected text as CHARACTER indices `[a, b)`, what a
  ## renderer counts cells by; `(-1, -1)` when nothing is selected.
  let (a, b) = vm.selectedSpan
  if a < 0: (-1, -1) else: (charsBefore(vm.query, a), charsBefore(vm.query, b))

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
