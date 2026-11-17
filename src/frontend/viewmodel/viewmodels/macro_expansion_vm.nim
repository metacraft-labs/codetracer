## viewmodels/macro_expansion_vm.nim — Toggle Macro Expansion, shared by every
## front-end that draws it (Editor-Hosted-Front-Ends §E15).
##
## ## What it holds
##
## The macro calls whose expansion is open in a session, each as a value
## (`MacroExpansion`): the call (`callPath:callLine`), the expansion's range in
## the compiler's generated `expanded.nim` (`expandedPath`, `firstLine ..
## lastLine`), its depth, and its lines once they arrive. Several can be open,
## one per call line, as the desktop's view zones are.
##
## ## The one request
##
## `toggle(path, line)` opens the expansion of the call at `path:line` with
## `ct/update-expansion {path, line, update: {kind: MacroUpdateExpand,
## times: 1}}` (`db-backend` `dap_handler.update_expansion`), and closes an
## open one with `MacroUpdateCollapse`. The replay keeps an expansion LEVEL per
## call and shows a stop inside the call's expansion at that level
## (`apply_macro_expansion_level`): collapsed, the stop is the call's line;
## expanded, it is the expanded line. Sending the collapse is what keeps "open
## here" and "stepping walks the expansion there" the same fact.
##
## ## Where the stop is
##
## A stop inside an open expansion is the store's `stop` with `isExpanded`
## (`applyStopLocation`), whose debugger position is the call
## (`applyCompleteMove`); `executionRow` is its row in the expansion. A stop
## inside an expansion this ViewModel does not hold — the replay was restarted
## behind it, or another client expanded the call — opens it from the stop's
## own fields (`adoptStop`), so a stop is never inside something no pane shows.
##
## No mocks are needed to test it: `test_macro_expansion_vm` drives it over a
## real replay of `test-programs/nim_macro_steps`.

import std/[algorithm, json, strutils]

import isonim/core/[signals, computation, owner, async_compat, batch]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]
from ./source_vm import SourceLineRequest
from ../sdk/source_provider import SourceProvider, SourceFetch,
  newDapSourceProvider, fetch, hasText

type
  MacroExpansion* = object
    ## One open expansion.
    callPath*: string
    callLine*: int
      ## The macro call: the line Toggle Macro Expansion was run on.
    expandedPath*: string
      ## The compiler's generated file (`…/nimcache/expanded.nim`).
    firstLine*, lastLine*: int
      ## The expansion's lines in `expandedPath`.
    depth*: int
      ## How many expansions it is inside (1 for a call in the user's file).
    lines*: seq[string]
      ## Its text, `firstLine .. lastLine`; empty until it arrives.
    textError*: string
      ## Why the text could not be read, "" otherwise.

  MacroExpansionVM* = ref object of ViewModel
    store*: ReplayDataStore
    expansions*: Signal[seq[MacroExpansion]]
      ## The open expansions, by call (path, then line).
    message*: Signal[string]
      ## What the last toggle did or why it could not: the words a front-end
      ## shows on its status line.
    sources: SourceProvider
      ## Where the expansion's text comes from; a DAP provider over the
      ## store's backend unless something installed another.

const
  ToggleMacroExpansionOperation* = "editor.toggle-macro-expansion"
  MacroExpansionPaneTitle* = "Macro Expansion"
  NoExpansionOpenText* =
    "Toggle Macro Expansion on a macro call shows its expansion here."

func expansionRequestArgs*(path: string; line: int;
                           collapse = false): JsonNode =
  ## The `ct/update-expansion` arguments (`UpdateExpansionArgs` in
  ## `db-backend/src/macro_sourcemap.rs`): one level more, or one less.
  %*{"path": path, "line": line,
     "update": {"kind": (if collapse: "MacroUpdateCollapse"
                         else: "MacroUpdateExpand"),
                "times": 1}}

func expansionOf*(body: JsonNode; path: string; line: int):
    tuple[ok: bool; expansion: MacroExpansion] =
  ## The expansion a `ct/update-expansion` answer opens for the call at
  ## `path:line`, or `ok` false when the line expands nothing (the replay
  ## answers a `Location` without `isExpanded`). The answer's `highLevelPath`
  ## is the expanded file; its first parent is the call.
  if body.isNil or body.kind != JObject or
     not body.getOrDefault("isExpanded").getBool(false):
    return
  let expanded = body.getOrDefault("highLevelPath").getStr("")
  let first = body.getOrDefault("expansionFirstLine").getInt(0)
  let last = body.getOrDefault("expansionLastLine").getInt(0)
  if expanded.len == 0 or first <= 0 or last < first:
    return
  result.ok = true
  result.expansion = MacroExpansion(
    callPath: path, callLine: line, expandedPath: expanded,
    firstLine: first, lastLine: last,
    depth: max(1, body.getOrDefault("expansionDepth").getInt(1)))

proc indexOf(vm: MacroExpansionVM; path: string; line: int): int =
  for i, e in vm.expansions.val:
    if e.callPath == path and e.callLine == line:
      return i
  -1

proc isOpen*(vm: MacroExpansionVM; path: string; line: int): bool =
  vm.indexOf(path, line) >= 0

func sortedByCall(list: seq[MacroExpansion]): seq[MacroExpansion] =
  result = list
  result.sort(proc(a, b: MacroExpansion): int =
    result = cmp(a.callPath, b.callPath)
    if result == 0: result = cmp(a.callLine, b.callLine))

proc replaceAt(vm: MacroExpansionVM; path: string; line: int;
               change: proc(e: var MacroExpansion)) =
  ## A FRESH list: on the JS backend a mutated signal value compares equal to
  ## itself and notifies nobody.
  var list = vm.expansions.val
  for e in list.mitems:
    if e.callPath == path and e.callLine == line:
      change(e)
  vm.expansions.val = list

proc loadText(vm: MacroExpansionVM; e: MacroExpansion) =
  ## Ask for the expansion's lines; an answer for an expansion closed since is
  ## dropped.
  if vm.sources.isNil:
    if vm.store.isNil or vm.store.backend.isNil:
      return
    vm.sources = newDapSourceProvider(vm.store.backend)
  let theVm = vm
  let request = SourceLineRequest(path: e.expandedPath, firstLine: e.firstLine,
                                  lastLine: e.lastLine)
  vm.sources.fetch(request, proc(answer: SourceFetch) =
    if not theVm.isOpen(e.callPath, e.callLine):
      return
    if not answer.hasText:
      theVm.replaceAt(e.callPath, e.callLine, proc(x: var MacroExpansion) =
        x.textError = "the expansion's text (" & e.expandedPath &
                      ") could not be read")
      return
    var lines: seq[string] = @[]
    for i, text in answer.lines:
      let n = answer.firstLine + i
      if n >= e.firstLine and n <= e.lastLine:
        lines.add text
    theVm.replaceAt(e.callPath, e.callLine, proc(x: var MacroExpansion) =
      x.lines = lines
      x.textError = ""))

proc open(vm: MacroExpansionVM; e: MacroExpansion) =
  if vm.isOpen(e.callPath, e.callLine):
    return
  vm.expansions.val = sortedByCall(vm.expansions.val & @[e])
  vm.loadText(e)

proc setSourceProvider*(vm: MacroExpansionVM; sources: SourceProvider) =
  ## Where the expansion's text is read from (the host's provider when it has
  ## one that reads the recording's own files).
  vm.sources = sources

func baseName(path: string): string =
  let slash = path.rfind('/')
  if slash >= 0: path[slash + 1 .. ^1] else: path

func callLabel(path: string; line: int): string =
  baseName(path) & ":" & $line

proc toggle*(vm: MacroExpansionVM; path: string; line: int;
             answered: proc(ok: bool; detail: string) = nil) =
  ## Open the expansion of the macro call at `path:line`, or close it when it
  ## is open. `answered` is told what happened once the replay has answered
  ## (at once for a close): `ok` false with the reason when there is nothing
  ## to expand there.
  proc tell(ok: bool; detail: string) =
    vm.message.val = detail
    if not answered.isNil:
      answered(ok, detail)
  if path.len == 0 or line <= 0:
    tell(false, "Toggle Macro Expansion: there is no source line to expand")
    return
  if vm.store.isNil or vm.store.backend.isNil:
    tell(false, "Toggle Macro Expansion: this session has no replay")
    return
  let at = vm.indexOf(path, line)
  if at >= 0:
    var list = vm.expansions.val
    list.delete(at)
    vm.expansions.val = list
    # The replay's level follows, so its stops are back on the call's line;
    # the answer has nothing more to say.
    discard vm.store.backend.send("ct/update-expansion",
                                  expansionRequestArgs(path, line, collapse = true))
    tell(true, "the expansion of " & callLabel(path, line) & " closed")
    return
  let theVm = vm
  onComplete(vm.store.backend.send("ct/update-expansion",
                                   expansionRequestArgs(path, line)),
    proc(response: JsonNode) =
      var answer: tuple[ok: bool; expansion: MacroExpansion]
      if responseSucceeded(response):
        answer = expansionOf(responseBody(response), path, line)
      if answer.ok:
        theVm.open(answer.expansion)
        tell(true, "the expansion of " & callLabel(path, line) & " beside the source")
      else:
        tell(false, "No macro expansion at " & callLabel(path, line)),
    proc(message: string) =
      tell(false, "Toggle Macro Expansion: the replay did not answer: " & message))

proc executionRow*(vm: MacroExpansionVM; e: MacroExpansion): int =
  ## The 1-based row of `e` the debugger is at, 0 when the stop is not in it.
  let stop = vm.store.stop.val
  if stop.isExpanded and stop.path == e.expandedPath and
     stop.expansionCallPath == e.callPath and
     stop.expansionCallLine == e.callLine and
     stop.line >= e.firstLine and stop.line <= e.lastLine:
    stop.line - e.firstLine + 1
  else:
    0

type
  MacroExpansionRowKind* = enum
    merHeading   ## an expansion's call and range; a press toggles it
    merLine      ## one line of an expansion
    merNotice    ## its text has not arrived, or could not be read

  MacroExpansionRow* = object
    ## One row of the Macro Expansion pane, as every front-end words it.
    kind*: MacroExpansionRowKind
    text*: string
    number*: int
      ## merLine: the row in its expansion, from 1 (the desktop's expansion
      ## editor numbers its lines so); 0 otherwise.
    executing*: bool
      ## merLine: the debugger is here.
    callPath*: string
    callLine*: int
      ## The expansion the row belongs to.

func headingOf*(e: MacroExpansion): string =
  ## `main.nim:17 · expanded.nim 1–4`: the call, then where its expansion is.
  callLabel(e.callPath, e.callLine) & " · " & baseName(e.expandedPath) & " " &
    $e.firstLine & "–" & $e.lastLine

proc displayRows*(vm: MacroExpansionVM): seq[MacroExpansionRow] =
  ## Every open expansion: its heading, then its lines, the debugger's marked.
  for e in vm.expansions.val:
    result.add MacroExpansionRow(kind: merHeading, text: headingOf(e),
                                 callPath: e.callPath, callLine: e.callLine)
    if e.textError.len > 0:
      result.add MacroExpansionRow(kind: merNotice, text: e.textError,
                                   callPath: e.callPath, callLine: e.callLine)
    elif e.lines.len == 0:
      result.add MacroExpansionRow(kind: merNotice, text: "loading…",
                                   callPath: e.callPath, callLine: e.callLine)
    else:
      let at = vm.executionRow(e)
      for i, text in e.lines:
        result.add MacroExpansionRow(kind: merLine, text: text, number: i + 1,
                                     executing: i + 1 == at,
                                     callPath: e.callPath, callLine: e.callLine)

proc adoptStop*(vm: MacroExpansionVM; stop: StopLocation) =
  ## A stop inside an expansion no one opened here opens it: it is where the
  ## debugger is, and the replay reports it expanded only when its call is.
  if not stop.isExpanded or stop.expansionCallLine <= 0 or
     stop.expansionFirstLine <= 0 or stop.expansionLastLine < stop.expansionFirstLine:
    return
  if vm.isOpen(stop.expansionCallPath, stop.expansionCallLine):
    return
  vm.open(MacroExpansion(
    callPath: stop.expansionCallPath, callLine: stop.expansionCallLine,
    expandedPath: stop.path, firstLine: stop.expansionFirstLine,
    lastLine: stop.expansionLastLine, depth: 1))

proc clear*(vm: MacroExpansionVM) =
  ## A new recording behind the store: nothing it showed is open in it.
  vm.expansions.val = @[]
  vm.message.val = ""

proc createMacroExpansionVM*(store: ReplayDataStore): MacroExpansionVM =
  ## A MacroExpansionVM inside a reactive root owned by `withViewModel`,
  ## disposed by `vm.dispose()`.
  withViewModel proc(dispose: proc()): MacroExpansionVM =
    var vm = MacroExpansionVM(
      store: store,
      expansions: createSignal(newSeq[MacroExpansion]()),
      message: createSignal(""),
      disposeProc: dispose)
    let vmRef = proc(): MacroExpansionVM = vm
    if not store.isNil:
      var seenGeneration = store.sessionGeneration.val
      createEffect proc() =
        let generation = store.sessionGeneration.val
        if generation != seenGeneration:
          seenGeneration = generation
          untrack(proc() = vmRef().clear())
      createEffect proc() =
        let stop = store.stop.val
        untrack(proc() = vmRef().adoptStop(stop))
    vm
