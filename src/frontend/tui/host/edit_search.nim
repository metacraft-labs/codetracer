## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI.
## See `host/native_host.nim`'s header for the full rule.
##
## tui/host/edit_search.nim — **Find in Files in Edit mode searches the
## project.**
##
## Edit mode docks Find in Files (the desktop's footer panels), and
## Find-And-Incremental-Search.md §5.1 says what it reads there: *"In Edit
## mode it is the project's root."* A replay's search is its session's
## `SearchResultsVM` over the recording (`tui_session.findInFiles`); Edit mode
## has no session, so this source owns the window's own model, wired to the
## same shared runner (`native_host.wireFindInFiles`) over the project root
## (`find_in_files.findInFilesScope` with the root as the one source folder),
## and a result opens the working-tree file in the editor
## (`runtime.openWorkingFileAt`) as a Problems row does. The pane's value is
## built by the same function the replay's is (`tui_session.searchModelOf`).

import isonim/core/signals
import viewmodels/search_results_vm
from ../../viewmodel/host/find_in_files import FindInFilesScope,
  findInFilesScope, pump, running
from std/unicode import runeLen

import ../app/runtime
import ../app/tui_app
import ./tui_session

type
  EditSearchSource* = ref object
    vm*: SearchResultsVM
    root: string

proc refresh*(s: EditSearchSource; rt: TuiRuntime) =
  rt.app.search = searchModelOf(s.vm, rt.app.search)

proc newEditSearchSource*(rt: TuiRuntime; root: string): EditSearchSource =
  ## The window's Find in Files over `root`, and the app's three search
  ## routes (`:grep`, the next / previous result, the toggles) pointed at it.
  let s = EditSearchSource(vm: createSearchResultsVM(nil), root: root)
  result = s
  wireFindInFiles(s.vm, proc(): FindInFilesScope =
    findInFilesScope("", false, [s.root]))
  rt.app.findInFiles = proc(query: string): string =
    s.vm.search(query)
    s.refresh(rt)
    ""
  rt.app.toggleSearchOption = proc(operation: string): string =
    let (known, which) = searchOptionOf(operation)
    if not known:
      return "`" & operation & "` is no Find in Files option"
    s.vm.toggleOption(which)
    s.refresh(rt)
    SearchOptionTitles[which] &
      (if s.vm.options.val.isOn(which): " on" else: " off")
  rt.app.stepSearchResult = proc(delta: int): string =
    let rows = s.vm.results.val
    if rows.len == 0:
      return "there are no search results"
    let index = s.vm.stepResult(delta)
    if index < 0 or index >= rows.len:
      return "there is no such search result"
    s.vm.selectResult(index)
    let row = rows[index]
    let column = if row.matchStart > 0 and row.matchStart <= row.text.len:
                   row.text[0 ..< row.matchStart].runeLen
                 else: 0
    let why = rt.openWorkingFileAt(row.path, row.line, column + 1)
    s.refresh(rt)
    if why.len > 0:
      return why
    rt.app.notification = "opened " & row.path & ":" & $row.line
    ""
  s.refresh(rt)

proc tick*(s: EditSearchSource; rt: TuiRuntime): bool =
  ## Advance the search in flight (the loop's idle tick); whether the pane's
  ## value changed. Nothing to do while no search runs.
  if not nativeFindInFiles.running:
    return false
  discard nativeFindInFiles.pump()
  let before = rt.app.search
  s.refresh(rt)
  rt.app.search != before
