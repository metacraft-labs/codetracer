## viewmodels/search_results_vm.nim
##
## SearchResultsVM — the Find in Files pane's ViewModel, on every front-end.
##
## PLAT-57 (Find-And-Incremental-Search.md §5): the desktop's panel, the
## terminal's pane and GPUI's leaf draw THIS model, and the one search runner
## (``host/find_in_files``) fills it. It owns the query, the pane's options
## (case, whole word, regular expression), the rows of the latest search, their grouping by file
## (``groups``), the selected row, and the latest run id that keeps a late
## batch of a cancelled search out (``acceptBatch``).
##
## A search starts at ``search`` — the pane's field, the omnibar's ``:grep``
## and a recent-search click all call it — which resets the state
## (``beginSearch``) and hands the host the run (``onSearch``). The host
## answers with batches (``acceptBatch``). A row opens through
## ``onJumpToResult`` and never moves the recording position (Editor-Pane.md:
## Find-in-Files row clicks deliberately do not).
##
## THERE IS NO CLIENT-SIDE RESULT FILTER, and there never was one that
## worked: the ``Filter results...`` input of the pre-redesign panel logged
## ``TODO find`` and narrowed nothing; it was retired with its machinery. What
## narrows a search is a new search.
##
## ``active`` is kept as the assertable stand-in for the retired
## ``search-results-active`` root modifier; no CSS reads it.

import std/tables

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]
import ../viewport
export viewport

export types.TextMatchOptions

type
  RecentSearch* = object
    ## A past search kept in the "recent searches" empty-state list.
    query*: string
    hitCount*: int

  SearchResultGroup* = object
    ## One file's rows, in the order they arrived, each with its index in
    ## ``results`` (what a click, the selection and ``F4`` name).
    path*: string
    rows*: seq[tuple[index: int, row: SearchResultLine]]

  SearchResultsVM* = ref object of ViewModel
    ## Reactive state for the Find in Files panel — the ONE model the
    ## desktop's panel, the terminal's pane and GPUI's leaf draw.
    ##
    ## Mutable signals:
    ##   query           — the active workspace search query string.
    ##   options         — the pane's toggles (case, whole word, regular
    ##                     expression).
    ##   results         — every match row of the latest search.
    ##   active          — true once a search has run.
    ##   loading         — true from a search's start to its first batch.
    ##   searching       — true from a search's start to its last batch.
    ##   note            — why the latest search found nothing to read.
    ##   selected        — the selected row's index in ``results``, or -1.
    ##   recentSearches  — past searches shown in the empty state.
    ##
    ## Derived memos:
    ##   resultCount    — convenience: ``results.val.len``.
    ##   fileCount      — distinct file paths in ``results``.
    ##   groups         — ``results`` grouped by file, files in arrival order.
    ##
    ## ``runId`` is the latest search's id; a batch carrying another one is
    ## dropped (``acceptBatch``), so rows of two searches never mix.
    ##
    ## Callbacks installed by the host:
    ##   onSearch       — run the search ``runId`` for ``query`` with
    ##                    ``options`` (the shared runner, in the host's
    ##                    process: Electron's main process, or the native
    ##                    front-end's own loop).
    ##   onJumpToResult — open ``row``'s file at its line, the match
    ##                    selected (never moving the recording position).
    store*: ReplayDataStore

    # -- Mutable state --
    query*: Signal[string]
    options*: Signal[TextMatchOptions]
    results*: Signal[seq[SearchResultLine]]
    active*: Signal[bool]
    loading*: Signal[bool]
    searching*: Signal[bool]
    note*: Signal[string]
    selected*: Signal[int]
    recentSearches*: Signal[seq[RecentSearch]]
    viewport*: Signal[Viewport]
      ## What the view was given (`setViewport`). The results are not
      ## fetched by window — the host's runner streams every match into
      ## memory — so the viewport decides only which rows a windowed view
      ## renders (`visibleResults`).
    runId*: int

    # -- Derived state --
    resultCount*: Memo[int]
    fileCount*: Memo[int]
    groups*: Memo[seq[SearchResultGroup]]
    visibleResults*: Memo[seq[SearchResultLine]]
      ## The results the viewport shows; every result while unmeasured.

    # -- Callbacks installed by the host --
    onSearch*: proc(runId: int; query: string; options: TextMatchOptions)
    onJumpToResult*: proc(row: SearchResultLine)

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setViewport*(vm: SearchResultsVM; v: Viewport) =
  ## The size and scroll position the view was given (Viewport-Driven-Loading
  ## V1): which rows a windowed view renders.
  vm.viewport.val = v

proc setQuery*(vm: SearchResultsVM; query: string) =
  ## Set the active workspace search query (without searching).
  vm.query.val = query

proc setResults*(vm: SearchResultsVM; results: seq[SearchResultLine]) =
  ## Replace the result list wholesale. Setting any non-empty list also
  ## flips ``active`` to true so the panel shows the rows.
  vm.results.val = results
  vm.selected.val = -1
  if results.len > 0:
    vm.active.val = true
    vm.loading.val = false

proc appendResults*(vm: SearchResultsVM; results: seq[SearchResultLine]) =
  ## Append a batch of result rows. An empty batch still clears the
  ## loading shimmer, so the empty state shows when nothing matched.
  vm.loading.val = false
  if results.len == 0:
    return
  var entries = vm.results.val
  for r in results:
    entries.add(r)
  vm.results.val = entries
  vm.active.val = true

proc clearResults*(vm: SearchResultsVM) =
  ## Reset the result list and the active flag.  The view re-displays
  ## the empty-state overlay (recent searches list).
  vm.results.val = @[]
  vm.selected.val = -1
  vm.active.val = false

proc setActive*(vm: SearchResultsVM; on: bool) =
  vm.active.val = on

proc setLoading*(vm: SearchResultsVM; on: bool) =
  ## Show or hide the loading shimmer.
  vm.loading.val = on

proc addRecentSearch*(vm: SearchResultsVM; query: string; hitCount: int) =
  ## Prepend a completed search to the recent-searches list.  Keeps at
  ## most 10 entries; duplicate queries are promoted to the front.
  var filtered: seq[RecentSearch]
  for e in vm.recentSearches.val:
    if e.query != query:
      filtered.add(e)
  filtered.insert(RecentSearch(query: query, hitCount: hitCount), 0)
  if filtered.len > 10:
    filtered.setLen(10)
  vm.recentSearches.val = filtered

proc beginSearch*(vm: SearchResultsVM; query: string): int =
  ## A new search's state: the previous one (if it found anything) kept in
  ## the recent list, the rows cleared, the shimmer on — and a new run id,
  ## which every batch of the new search carries and every batch of an
  ## older one does not.
  let prevQuery = vm.query.val
  let prevCount = vm.results.val.len
  if prevQuery.len > 0 and prevCount > 0:
    vm.addRecentSearch(prevQuery, prevCount)
  inc vm.runId
  vm.clearResults()
  vm.query.val = query
  vm.note.val = ""
  vm.loading.val = query.len > 0
  vm.searching.val = query.len > 0
  vm.active.val = query.len > 0
  vm.runId

proc search*(vm: SearchResultsVM; query: string) =
  ## Run a search for ``query`` with the pane's options: the state of a new
  ## search, then the host's runner (``onSearch``). The one entry point the
  ## pane's field, the omnibar's ``:grep`` and a recent search all take.
  let id = vm.beginSearch(query)
  if query.len > 0 and not vm.onSearch.isNil:
    vm.onSearch(id, query, vm.options.val)

type
  SearchOption* = enum
    ## The pane's three toggles, each named as every front-end names it: the
    ## desktop's control class, the terminal's and GPUI's hit target, the
    ## keymap's operation (`search.toggle-<name>`).
    soCase = "case"     ## Match Case (`Aa`, `Alt+C`)
    soWord = "word"     ## Match Whole Word (`ab`, `Alt+W`)
    soRegex = "regex"   ## Use Regular Expression (`.*`, `Alt+R`)

const
  SearchOptionLabels*: array[SearchOption, string] = ["Aa", "ab", ".*"]
    ## What each toggle shows — VS Code's glyphs, the desktop's.
  SearchOptionTitles*: array[SearchOption, string] =
    ["Match Case", "Match Whole Word", "Use Regular Expression"]
  SearchOptionOperations*: array[SearchOption, string] =
    ["search.toggle-case", "search.toggle-whole-word", "search.toggle-regex"]
    ## The keymap's operation for each toggle — `Alt+C` / `Alt+W` / `Alt+R`
    ## in the pane's field (CUA-Keymap.md §3.7).

func searchOptionOf*(operation: string): tuple[ok: bool, option: SearchOption] =
  ## The toggle a `search.toggle-*` operation flips.
  for o in SearchOption:
    if SearchOptionOperations[o] == operation:
      return (true, o)
  (false, soCase)

func isOn*(options: TextMatchOptions; which: SearchOption): bool =
  case which
  of soCase: options.caseSensitive
  of soWord: options.wholeWord
  of soRegex: options.regex

proc toggleOption*(vm: SearchResultsVM; which: SearchOption) =
  ## Flip one of the pane's toggles; a search that ran runs again with it,
  ## as VS Code's search view does — the rows always answer the options
  ## shown.
  var o = vm.options.val
  case which
  of soCase: o.caseSensitive = not o.caseSensitive
  of soWord: o.wholeWord = not o.wholeWord
  of soRegex: o.regex = not o.regex
  vm.options.val = o
  if vm.query.val.len > 0:
    vm.search(vm.query.val)

proc acceptBatch*(vm: SearchResultsVM; runId: int;
                  rows: seq[SearchResultLine]; done: bool;
                  note = ""): bool =
  ## A batch of the runner's rows. Dropped — answering false — when it
  ## belongs to a search other than the latest, so the rows of a cancelled
  ## search can never reach the pane, however late they arrive.
  if runId != vm.runId:
    return false
  vm.appendResults(rows)
  if done:
    vm.searching.val = false
    vm.loading.val = false
    if note.len > 0:
      vm.note.val = note
  true

proc selectResult*(vm: SearchResultsVM; index: int) =
  ## Select row ``index`` of ``results`` (-1 for none).
  let n = vm.results.val.len
  vm.selected.val = if index >= 0 and index < n: index else: -1

proc openResult*(vm: SearchResultsVM; index: int): bool =
  ## Select row ``index`` and open it — the host's to do
  ## (``onJumpToResult``). False when there is no such row.
  ##
  ## There is deliberately **no backend fallback**: the retired
  ## ``jumpToResult`` once dispatched ``ct/jump-location``, which
  ## `backend/dap_dialect.md` §7 records as reaching no engine handler, so the
  ## click did nothing while its view tests stayed green. Opening a file is
  ## the host's job, and a VM without a host does not have one to do.
  let rows = vm.results.val
  if index < 0 or index >= rows.len:
    return false
  vm.selected.val = index
  if not vm.onJumpToResult.isNil:
    vm.onJumpToResult(rows[index])
  true

proc stepResult*(vm: SearchResultsVM; delta: int): int =
  ## The row ``delta`` away from the selected one, wrapping at the ends —
  ## the next (``1``) or previous (``-1``) result. With nothing selected the
  ## first step forward is the first row and backward the last. -1 when
  ## there are no rows.
  let n = vm.results.val.len
  if n == 0:
    return -1
  let at = vm.selected.val
  if at < 0:
    return (if delta >= 0: 0 else: n - 1)
  ((at + delta) mod n + n) mod n

# ---------------------------------------------------------------------------
# What every front-end draws — one spelling of each
# ---------------------------------------------------------------------------

proc shortResultPath*(path: string): string =
  ## A file group's caption: the last two components of the path, so a deep
  ## tree does not push the count off the row (the full path is the group's
  ## tooltip on the desktop).
  var parts: seq[string] = @[]
  var cur = ""
  for c in path:
    if c in {'/', '\\'}:
      if cur.len > 0: parts.add cur
      cur = ""
    else:
      cur.add c
  if cur.len > 0: parts.add cur
  if parts.len >= 2: parts[^2] & "/" & parts[^1]
  elif parts.len == 1: parts[0]
  else: path

proc countLabel*(n: int; singular, plural: string): string =
  ## ``"<n> <noun>"`` with the noun agreeing in number ("1 match", not
  ## "1 matches").
  $n & " " & (if n == 1: singular else: plural)

proc matchCountLabel*(n: int): string =
  ## A file group's count badge ("3 matches").
  countLabel(n, "match", "matches")

proc resultCountLabel*(n: int): string =
  ## A recent search's count ("3 results").
  countLabel(n, "result", "results")

proc summaryText*(vm: SearchResultsVM): string =
  ## One line saying where the search is: running, what it found, or why it
  ## could read nothing.
  let n = vm.results.val.len
  if vm.note.val.len > 0:
    vm.note.val
  elif vm.query.val.len == 0:
    ""
  elif vm.searching.val:
    "Searching… " & resultCountLabel(n)
  elif n == 0:
    "No results for \"" & vm.query.val & "\""
  else:
    resultCountLabel(n) & " in " & countLabel(vm.groups.val.len, "file", "files")

const NativeSearchPrompt* =
  "Type :grep <text> in the omnibox to search the recording's sources"
  ## The empty pane's prompt where the query is typed into the omnibox's
  ## `:grep` (the terminal and GPUI); the desktop's field has its own.

proc emptyText*(vm: SearchResultsVM; prompt: string): string =
  ## What the pane's body says with no rows: why the latest search read
  ## nothing, that it matched nothing, or ``prompt`` — how to start one on
  ## this front-end.
  if vm.note.val.len > 0: vm.note.val
  elif vm.query.val.len > 0 and not vm.searching.val:
    "No results for \"" & vm.query.val & "\""
  else: prompt

proc rowParts*(row: SearchResultLine):
    tuple[matched: bool; before, hit, after: string] =
  ## A row's text split around the match the RUNNER found (``matchStart`` /
  ## ``matchLength``), its leading indentation dropped — never a second
  ## search of the text by a view, which could disagree with the runner on
  ## case or word boundaries. Without a match position the whole text is
  ## ``before``.
  var lead = 0
  while lead < row.text.len and row.text[lead] in {' ', '\t'}:
    inc lead
  let a = row.matchStart
  let b = row.matchStart + row.matchLength
  if row.matchLength <= 0 or a < lead or b > row.text.len:
    return (false, row.text[min(lead, row.text.len) .. ^1], "", "")
  (true, row.text[lead ..< a], row.text[a ..< b], row.text[b .. ^1])

type
  SearchDisplayRowKind* = enum
    sdFile    ## a file group's header
    sdMatch   ## one matching line

  SearchDisplayRow* = object
    ## The pane's list as rows, for the native front-ends that draw one row
    ## per line (the terminal, GPUI): a header per file, then its matches.
    kind*: SearchDisplayRowKind
    path*: string
    caption*: string
      ## sdFile: `shortResultPath`.
    count*: string
      ## sdFile: `matchCountLabel`.
    index*: int
      ## sdMatch: the row's index in `results`.
    line*: int
    before*, hit*, after*: string
      ## sdMatch: `rowParts`.

proc displayRows*(vm: SearchResultsVM): seq[SearchDisplayRow] =
  ## `groups` flattened: each file's header, then its matching lines.
  for g in vm.groups.val:
    result.add SearchDisplayRow(kind: sdFile, path: g.path,
                                caption: shortResultPath(g.path),
                                count: matchCountLabel(g.rows.len))
    for (index, row) in g.rows:
      let p = rowParts(row)
      result.add SearchDisplayRow(kind: sdMatch, path: row.path, index: index,
                                  line: row.line, before: p.before,
                                  hit: p.hit, after: p.after)

proc displayRowOf*(rows: openArray[SearchDisplayRow]; index: int): int =
  ## The display row of result `index`, -1 when it is not listed.
  for i, r in rows:
    if r.kind == sdMatch and r.index == index:
      return i
  -1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc groupResults*(rows: seq[SearchResultLine]): seq[SearchResultGroup] =
  ## Rows grouped by ``path``, files in the order each first appears.
  var at = initTable[string, int]()
  for i, r in rows:
    let key = if r.path.len == 0: "<unknown>" else: r.path
    if not at.hasKey(key):
      at[key] = result.len
      result.add SearchResultGroup(path: key)
    result[at[key]].rows.add (i, r)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createSearchResultsVM*(store: ReplayDataStore): SearchResultsVM =
  ## Create a SearchResultsVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.
  withViewModel proc(dispose: proc()): SearchResultsVM =
    let query = createSignal("")
    let options = createSignal(TextMatchOptions())
    let results = createSignal(newSeq[SearchResultLine]())
    let active = createSignal(false)
    let loading = createSignal(false)
    let searching = createSignal(false)
    let note = createSignal("")
    let selected = createSignal(-1)
    let recentSearches = createSignal(newSeq[RecentSearch]())
    let viewport = createSignal(Viewport())

    let resultCount = createMemo[int] proc(): int =
      results.val.len

    let groups = createMemo[seq[SearchResultGroup]] proc(): seq[SearchResultGroup] =
      groupResults(results.val)

    let fileCount = createMemo[int] proc(): int =
      groups.val.len

    let visibleResults = createMemo[seq[SearchResultLine]] proc(): seq[SearchResultLine] =
      let v = viewport.val
      let all = results.val
      if not v.measured:
        return all
      let lo = clamp(v.firstRow, 0, all.len)
      let hi = clamp(v.firstRow + v.rows, 0, all.len)
      all[lo ..< hi]

    SearchResultsVM(
      store: store,
      query: query,
      options: options,
      results: results,
      active: active,
      loading: loading,
      searching: searching,
      note: note,
      selected: selected,
      recentSearches: recentSearches,
      viewport: viewport,
      visibleResults: visibleResults,
      resultCount: resultCount,
      fileCount: fileCount,
      groups: groups,
      disposeProc: dispose,
    )
