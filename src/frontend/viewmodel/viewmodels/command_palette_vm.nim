## viewmodels/command_palette_vm.nim
##
## CommandPaletteVM — ViewModel for the Command Palette overlay.
##
## The Command Palette is the Ctrl+P-style overlay (see
## ``frontend/ui/command.nim``) that lets the user search files,
## program text / symbols, and run commands.  The legacy
## ``CommandPaletteComponent`` used a Karax ``method render`` to draw
## a fixed input field plus a dropdown of ``CommandPanelResult`` rows.
## Section §1.72 (mission goal #3) replaces the Karax render with an
## IsoNim view; the rich per-kind row shapes (program-search HTML
## fragment, symbol-kind suffix, file-path tail truncation, agent-
## mode passthrough) remain a follow-up.
##
## Reactive surface:
## - ``isActive``           — true while the overlay is visible.
##                            Mirrors the legacy ``active`` flag.
## - ``inputValue``         — current text in the input field.
##                            Mirrors ``inputField.value`` reads.
## - ``inputPlaceholder``   — autocomplete hint rendered behind the
##                            input.  Mirrors the legacy
##                            ``inputPlaceholder`` field — the
##                            ``onInput`` / ``changePlaceholder``
##                            mutators populate it.
## - ``mode``               — top-level mode (normal / agent).  The
##                            legacy view rendered the
##                            AgentActivityComponent in agent mode;
##                            the IsoNim view exposes the mode signal
##                            so a future migration of the agent
##                            surface can subscribe to it.
## - ``query``              — current parsed query string (the legacy
##                            view stored a ``SearchQuery`` ref).  The
##                            VM keeps just the rendered query text so
##                            both backends compile identically.
## - ``results``            — flat ``seq[CommandPaletteResultEntry]``.
##                            Mirrors the legacy ``results`` seq.
## - ``selectedIndex``      — index of the highlighted row.  Mirrors
##                            the legacy ``selected`` field; clamped
##                            into ``[0, results.len)`` by ``setSelected``
##                            so the view never paints a stray
##                            ``command-selected`` modifier on an
##                            out-of-range row.
## - ``activeCommandName``  — name of the active "parent" command
##                            (e.g. mid-typing ``:open ...``).  Mirrors
##                            the legacy ``activeCommandName`` field.
##
## Derived:
## - ``hasResults``         — true when ``results`` is non-empty.
## - ``resultCount``        — len of the results seq.
##
## Actions:
## - ``open`` / ``close``   — show / hide the overlay.  ``close`` also
##                            clears the input and selection so a
##                            re-open starts from a blank slate.
## - ``setQuery``           — push the parsed query string + reset the
##                            selection to 0.
## - ``setResults``         — bulk-replace the results seq + clamp the
##                            selection to fit.
## - ``setSelected``        — explicit selection setter; clamped to
##                            ``[0, results.len)`` (or 0 when results
##                            is empty so the view's ``selectedIndex``
##                            comparison is always well-defined).
## - ``setMode``            — switch between normal / agent mode.
##                            Mirrors the legacy ``inAgentMode`` flip.
## - ``clear``              — drop input/query/results/selection but
##                            leave ``isActive`` untouched (called
##                            from the legacy ``clear`` helper).
##
## ``string`` / ``bool`` / ``int`` / ``seq`` shapes are used everywhere
## so the same value works on both ``test-vm-native`` and
## ``test-vm-js`` without ``cstring`` / ``langstring`` conversion noise.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]

type
  CommandPaletteVM* = ref object of ViewModel
    ## Reactive state for the Command Palette overlay.
    store*: ReplayDataStore

    # -- Mutable state --
    isActive*: Signal[bool]
    inputValue*: Signal[string]
    inputPlaceholder*: Signal[string]
    mode*: Signal[CommandPaletteMode]
    query*: Signal[string]
    results*: Signal[seq[CommandPaletteResultEntry]]
    selectedIndex*: Signal[int]
    activeCommandName*: Signal[string]

    # -- Derived state --
    hasResults*: Memo[bool]
    resultCount*: Memo[int]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc clampSelection(index, count: int): int =
  ## Clamp ``index`` into ``[0, count)``.  When ``count`` is zero the
  ## clamp returns 0 so callers always have a well-defined value to
  ## paint against (the view skips the ``command-selected`` class
  ## anyway because ``hasResults`` is false).
  if count <= 0:
    return 0
  if index < 0:
    return 0
  if index >= count:
    return count - 1
  index

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc open*(vm: CommandPaletteVM) =
  ## Show the overlay.  Idempotent — re-opening an already-open
  ## palette is a no-op.  The legacy ``showResults`` helper sets
  ## ``active = true`` on every keystroke; the IsoNim variant skips
  ## the redundant signal write so the reactive subscribers don't
  ## re-fire pointlessly.
  if vm.isActive.val:
    return
  vm.isActive.val = true

proc close*(vm: CommandPaletteVM) =
  ## Hide the overlay and reset every transient piece of state.
  ## Mirrors the legacy ``close`` + ``clear`` helpers in
  ## ``ui/command.nim``.  The mode is reset to ``cpmNormal`` so a
  ## stuck ``cpmAgent`` flag can't survive a close/re-open cycle.
  vm.isActive.val = false
  vm.inputValue.val = ""
  vm.inputPlaceholder.val = ""
  vm.query.val = ""
  vm.results.val = @[]
  vm.selectedIndex.val = 0
  vm.mode.val = cpmNormal
  vm.activeCommandName.val = ""

proc clear*(vm: CommandPaletteVM) =
  ## Drop the input/query/results without hiding the overlay.  Used
  ## by the legacy ``clear`` helper which is invoked while the
  ## overlay is still displayed (e.g. between keystrokes that produce
  ## no matches).  ``isActive`` is intentionally left untouched.
  vm.inputValue.val = ""
  vm.inputPlaceholder.val = ""
  vm.query.val = ""
  vm.results.val = @[]
  vm.selectedIndex.val = 0

proc setQuery*(vm: CommandPaletteVM; queryText: string) =
  ## Push the new query text and reset the selection to the first
  ## row.  Matches the legacy ``onInput`` pattern where every new
  ## keystroke moves focus back to the top of the dropdown.
  vm.query.val = queryText
  vm.inputValue.val = queryText
  vm.selectedIndex.val = 0

proc setResults*(vm: CommandPaletteVM;
                 entries: openArray[CommandPaletteResultEntry]) =
  ## Bulk-replace the results.  Re-clamps the selection so a stale
  ## index from the previous result set cannot point off the end of
  ## the new one.
  vm.results.val = @entries
  vm.selectedIndex.val = clampSelection(vm.selectedIndex.val, entries.len)

proc setSelected*(vm: CommandPaletteVM; index: int) =
  ## Explicit setter for the highlighted row.  Clamped via
  ## ``clampSelection``.  Convenience wrapper for keyboard arrow
  ## handlers (the legacy ``commandSelectNext`` / ``commandSelectPrevious``
  ## helpers).
  vm.selectedIndex.val = clampSelection(index, vm.results.val.len)

proc setMode*(vm: CommandPaletteVM; mode: CommandPaletteMode) =
  ## Switch between normal and agent mode.  Mirrors the legacy
  ## ``inAgentMode`` flip — the view subscribes to this signal and
  ## reveals / hides the agent passthrough surface.
  vm.mode.val = mode

proc setInputPlaceholder*(vm: CommandPaletteVM; placeholder: string) =
  ## Update the autocomplete hint.  Separated from ``setQuery`` so
  ## the legacy ``changePlaceholder`` helper can refresh just the
  ## hint without re-clamping the selection.
  vm.inputPlaceholder.val = placeholder

proc setActiveCommandName*(vm: CommandPaletteVM; name: string) =
  ## Push the active "parent" command name.  Mirrors the legacy
  ## ``activeCommandName`` assignment in
  ## ``commandResultView`` callers.
  vm.activeCommandName.val = name

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createCommandPaletteVM*(store: ReplayDataStore): CommandPaletteVM =
  ## Create a CommandPaletteVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.  Sets every signal to its closed/empty default
  ## so the view paints the hidden overlay on first render.
  withViewModel proc(dispose: proc()): CommandPaletteVM =
    let isActive = createSignal(false)
    let inputValue = createSignal("")
    let inputPlaceholder = createSignal("")
    let mode = createSignal(cpmNormal)
    let query = createSignal("")
    let results = createSignal(newSeq[CommandPaletteResultEntry]())
    let selectedIndex = createSignal(0)
    let activeCommandName = createSignal("")

    let hasResults = createMemo[bool] proc(): bool =
      results.val.len > 0

    let resultCount = createMemo[int] proc(): int =
      results.val.len

    CommandPaletteVM(
      store: store,
      isActive: isActive,
      inputValue: inputValue,
      inputPlaceholder: inputPlaceholder,
      mode: mode,
      query: query,
      results: results,
      selectedIndex: selectedIndex,
      activeCommandName: activeCommandName,
      hasResults: hasResults,
      resultCount: resultCount,
      disposeProc: dispose,
    )
