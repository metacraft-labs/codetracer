## viewmodels/scratchpad_vm.nim
##
## ScratchpadVM — ViewModel for the Scratchpad panel.
##
## The Scratchpad panel renders a vertical list of pinned values that
## the user has sent from other panels (state, calltrace, flow, value
## hover popups …).  The legacy ``ScratchpadComponent`` (see
## ``frontend/ui/scratchpad.nim``) implemented the panel via a Karax
## ``method render`` that delegated each row's body to the rich
## ``ValueComponent`` sub-tree (expandable trees, charts, inline /
## verbose toggles).  Section §1.70 (mission goal #3) replaces the
## Karax render with an IsoNim view; the rich ``ValueComponent``
## rendering remains a follow-up captured in the view module.
##
## Reactive surface:
## - ``entries``              — pinned ``ScratchpadValueEntry`` rows
##                              in display order (insertion order).
## - ``localsByExpression``   — lookup table that ``addFromExpression``
##                              uses to mirror the legacy
##                              ``InternalAddToScratchpadFromExpression``
##                              flow without dragging the JS-only
##                              ``Variable`` ref-object into the
##                              viewmodel layer.  The legacy bridge
##                              populates it on every
##                              ``CtLoadLocalsResponse``.
##
## Derived:
## - ``isEmpty``  — convenience for the empty-state placeholder.
## - ``rowCount`` — total entry count (used by tests).
##
## Actions:
## - ``addValue``           — append a captured ``ScratchpadValueEntry``
##                            (mirrors the legacy ``registerValue``
##                            flow triggered by
##                            ``InternalAddToScratchpad``).
## - ``removeValue``        — drop the row at ``index`` (mirrors the
##                            legacy ``removeValue`` flow triggered by
##                            the per-row close button).  Out-of-range
##                            indices are silent no-ops.
## - ``clearValues``        — wipe every entry (used during a session
##                            switch / unit tests).
## - ``setLocals``          — bulk-replace the locals lookup table
##                            (mirrors the legacy ``registerLocals``
##                            flow triggered by ``CtLoadLocalsResponse``).
## - ``addFromExpression``  — find a known local by expression and
##                            append it (mirrors the legacy
##                            ``InternalAddToScratchpadFromExpression``
##                            flow that was wired to the watch / hover
##                            "Add to scratchpad" entry-points).  An
##                            unknown expression is a silent no-op so
##                            the legacy ``echo "Variable not found."``
##                            path no longer reaches the console.
##
## ``string`` is used everywhere so the same value works on both
## native (``test-vm-native``) and JS (``test-vm-js``) backends without
## ``cstring`` / ``langstring`` conversion noise.

import std/sets
import std/tables

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]
import origin_chain_types

type
  ScratchpadVM* = ref object of ViewModel
    ## Reactive state for the Scratchpad panel.
    store*: ReplayDataStore

    # -- Mutable state --
    entries*: Signal[seq[ScratchpadValueEntry]]
    localsByExpression*: Signal[Table[string, ScratchpadValueEntry]]
    expandedPaths*: Signal[HashSet[string]]

    # Value Origin Tracking (M4) — sibling variant of
    # `ScratchpadValueEntry` per spec §8.1 "Scratchpad data model
    # (new entry kind)". Renders the chain as a folded card with
    # side-by-side chain-diff support.
    chainEntries*: Signal[seq[ScratchpadChainEntry]]

    # -- Derived state --
    isEmpty*: Memo[bool]
    rowCount*: Memo[int]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc addValue*(vm: ScratchpadVM; entry: ScratchpadValueEntry) =
  ## Append a captured value entry to the scratchpad list.  Mirrors
  ## the legacy ``ScratchpadComponent.registerValue`` flow triggered
  ## by ``InternalAddToScratchpad``.  Insertion order is preserved
  ## (the legacy DataTables-free panel rendered rows in the order they
  ## arrived).
  var existing = vm.entries.val
  existing.add(entry)
  vm.entries.val = existing

proc removeValue*(vm: ScratchpadVM; index: int) =
  ## Drop the row at ``index``.  Out-of-range indices are silent
  ## no-ops so the IsoNim view's per-row click handler can dispatch
  ## without re-validating the index.
  let existing = vm.entries.val
  if index < 0 or index >= existing.len:
    return
  var updated = newSeqOfCap[ScratchpadValueEntry](existing.len - 1)
  for i, e in existing:
    if i != index:
      updated.add(e)
  vm.entries.val = updated

proc clearValues*(vm: ScratchpadVM) =
  ## Drop every captured row.  Used during a session switch / fresh
  ## debugging run.
  vm.entries.val = @[]
  vm.expandedPaths.val = initHashSet[string]()

proc setLocals*(vm: ScratchpadVM;
                entries: openArray[ScratchpadValueEntry]) =
  ## Replace the locals lookup table.  ``addFromExpression`` resolves
  ## an expression name through this table.  Mirrors the legacy
  ## ``ScratchpadComponent.registerLocals`` flow triggered by
  ## ``CtLoadLocalsResponse``.  Each entry is keyed by its
  ## ``expression`` field; later entries override earlier ones with the
  ## same key (matching the linear-search semantics in the legacy
  ## ``InternalAddToScratchpadFromExpression`` handler).
  var lookup = initTable[string, ScratchpadValueEntry]()
  for e in entries:
    lookup[e.expression] = e
  vm.localsByExpression.val = lookup

proc addChain*(vm: ScratchpadVM; chain: OriginChain) =
  ## Append a captured chain entry to the scratchpad list (M4
  ## deliverable §3.5 + spec §8.1). The legacy
  ## `ScratchpadComponent.registerValue` flow remains unchanged for
  ## value pins; chains travel through this dedicated proc so the
  ## view can render them as folded cards with chain-diff support.
  var existing = vm.chainEntries.val
  existing.add(ScratchpadChainEntry(chain: chain))
  vm.chainEntries.val = existing

proc removeChain*(vm: ScratchpadVM; index: int) =
  let existing = vm.chainEntries.val
  if index < 0 or index >= existing.len:
    return
  var updated = newSeqOfCap[ScratchpadChainEntry](existing.len - 1)
  for i, e in existing:
    if i != index:
      updated.add(e)
  vm.chainEntries.val = updated

proc clearChains*(vm: ScratchpadVM) =
  vm.chainEntries.val = @[]

proc toggleExpand*(vm: ScratchpadVM; path: string) =
  var paths = vm.expandedPaths.val
  if path in paths:
    paths.excl(path)
  else:
    paths.incl(path)
  vm.expandedPaths.val = paths

proc addFromExpression*(vm: ScratchpadVM; expression: string) =
  ## Look up ``expression`` in the locals table and append the
  ## corresponding entry to the scratchpad.  Mirrors the legacy
  ## ``InternalAddToScratchpadFromExpression`` flow.  An unknown
  ## expression is a silent no-op (the legacy code logged
  ## ``"Variable not found."`` to the console; the new flow
  ## intentionally drops the noise).
  let lookup = vm.localsByExpression.val
  if not lookup.hasKey(expression):
    return
  vm.addValue(lookup[expression])

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createScratchpadVM*(store: ReplayDataStore): ScratchpadVM =
  ## Create a ScratchpadVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.  Sets every signal to its empty/inert default
  ## so the view renders the empty-state placeholder on first paint.
  withViewModel proc(dispose: proc()): ScratchpadVM =
    let entries = createSignal(newSeq[ScratchpadValueEntry]())
    let localsByExpression =
      createSignal(initTable[string, ScratchpadValueEntry]())
    let expandedPaths = createSignal(initHashSet[string]())
    let chainEntries = createSignal(newSeq[ScratchpadChainEntry]())

    let isEmpty = createMemo[bool] proc(): bool =
      entries.val.len == 0 and chainEntries.val.len == 0

    let rowCount = createMemo[int] proc(): int =
      entries.val.len + chainEntries.val.len

    ScratchpadVM(
      store: store,
      entries: entries,
      localsByExpression: localsByExpression,
      expandedPaths: expandedPaths,
      chainEntries: chainEntries,
      isEmpty: isEmpty,
      rowCount: rowCount,
      disposeProc: dispose,
    )
