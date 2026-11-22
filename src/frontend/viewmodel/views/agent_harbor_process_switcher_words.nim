## views/agent_harbor_process_switcher_words.nim
##
## The words, operations and rules the three hosts share for a
## multi-process recording's session tab and its process switcher (the
## web's `isonim_agent_harbor_process_switcher_view`, GPUI's
## `gpui/agent_harbor/ah_process_switcher`, the terminal's
## `tui/agent_harbor/ah_tui_process_switcher`), over `ProcessSwitcherVM`
## (`viewmodel/process_switcher_vm.nim`).
##
## codetracer-pm `design/agent-harbor-front-end/p2c-omnibox-and-control-center-study.md`
## §2.6, D25, D76-D83: the tab carries the recording's name and, inside it,
## the recording switcher's numbered buttons for its processes; a button's
## tooltip names the process, its pid and binary; a correlation marker that
## leads to another process rings that button until the reader follows it.
##
## Operations (Input-Routing-And-Keymaps.md §4, §5.1; every press and key is
## routed, the views hold no handler of their own):
## - `process-switcher.next` / `.previous`: the next or previous process,
##   wrapping, on `Ctrl+Alt+PageDown` / `Ctrl+Alt+PageUp` under every base
##   (a window-level row: `Ctrl+PageDown` moves between session tabs, Alt
##   moves inside the tab; D82);
## - `process-switcher.select(n)`: process `n`, on the digit keys `1`-`9`
##   while the switcher has the focus, and a press on a button;
##
## Following a correlation marker is the marker's own jump
## (Correlation-Markers.md §5.3: the Event Log's counterpart button, not
## built in any host yet); it calls `ProcessSwitcherVM.followCorrelation`,
## and no key or press of the switcher's is its own (D82).

import std/strutils

import ../process_switcher_vm
import ../keymap/[base_keymaps, editing_keymap, context_keys]

export process_switcher_vm

const
  ProcessSwitcherSurface* = "agent-harbor-process-switcher"
  ProcessNextOperation* = "process-switcher.next"
  ProcessPreviousOperation* = "process-switcher.previous"
  ProcessSelectOperation* = "process-switcher.select"
  ProcessSwitcherOperations* = [ProcessNextOperation, ProcessPreviousOperation,
                                ProcessSelectOperation]
  ProcessesWord* = "processes"

proc processChord*(operation: string; base = bkCua): string =
  ## The key the base keymap binds to `operation`, as it spells it; "" when
  ## the base binds none. The words name the bound key through this, so they
  ## can never name a key that does something else (as `gazePauseChord`).
  for b in keymapOf(base).keymap.bindings:
    if b.operation == operation and b.argument.len == 0:
      return b.spelling
  ""

proc processCountText*(n: int): string =
  ## `3 processes`, `1 process`.
  $n & " " & (if n == 1: "process" else: ProcessesWord)

proc tabTooltipOf*(vm: ProcessSwitcherVM; nextChord, previousChord: string): string =
  ## The tab's tooltip: the recording, how many processes, which is shown,
  ## and the keys that move between them (when bound).
  let entries = vm.entries.val
  result = vm.title & " \xC2\xB7 " & processCountText(entries.len)
  let n = vm.activeNumber
  if n > 0:
    result.add " \xC2\xB7 showing " & $n & " (" & entries[n - 1].processLabel & ")"
  if vm.shown and nextChord.len > 0 and previousChord.len > 0:
    result.add " \xC2\xB7 " & nextChord & " / " & previousChord & " to move between them"

proc tabFacts*(vm: ProcessSwitcherVM; maxShown = high(int)): seq[(string, string)] =
  ## The facts the tab carries in every host (`data-ah-*`): how many
  ## processes, the active one's number, the ringed one's number (0 for
  ## none) and whether it sits behind `+N`, and the buttons drawn before
  ## `+N` (`process-slots`).
  @[("processes", $vm.entries.val.len), ("process-active", $vm.activeNumber),
    ("process-ringed", $vm.ringedNumber),
    ("process-ringed-hidden", $vm.ringedHidden(maxShown)),
    ("process-switcher", $vm.shown), ("process-slots", $maxShown)]

proc selectArgument*(argument: string): int =
  ## A `process-switcher.select(n)` argument as the number (0 when it is
  ## not a positive integer).
  try:
    result = parseInt(argument.strip)
    if result < 1: result = 0
  except ValueError:
    result = 0

proc runProcessSwitcherOperation*(vm: ProcessSwitcherVM; operation: string;
                                  argument = ""): bool =
  ## Runs a key's operation on the switcher; false for one that is not the
  ## switcher's, or one that changed nothing.
  if vm.isNil: return false
  case operation
  of ProcessNextOperation: vm.next()
  of ProcessPreviousOperation: vm.previous()
  of ProcessSelectOperation: vm.selectNumber(selectArgument(argument))
  else: false

proc runProcessSwitcherPress*(vm: ProcessSwitcherVM; operation, target: string): bool =
  ## Runs a press's operation: a press on a button selects its process
  ## (`target`: the process's recording id).
  if vm.isNil: return false
  case operation
  of ProcessSelectOperation: vm.select(target)
  else: false
