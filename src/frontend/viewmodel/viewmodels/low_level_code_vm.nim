## viewmodels/low_level_code_vm.nim
##
## LowLevelCodeVM — ViewModel for the Low Level Code panel.
##
## The Low Level Code panel renders the asm / IR listing for the
## currently-debugged function.  It is a thin shell around the
## EditorViewComponent in production (Monaco renders the actual asm
## buffer), but the legacy ``LowLevelCodeComponent`` (see
## ``frontend/ui/low_level_code.nim``) still owns the data plumbing
## that issues ``CtLoadAsmFunction``, accepts the
## ``CtLoadAsmFunctionResponse`` payload, formats each instruction
## (``formatLine`` — offset / name / args / other column layout) and
## sets up Monaco view-zones cross-referencing the high-level source
## line each instruction was generated from.
##
## This VM mirrors that data model platform-neutrally so:
## - the IsoNim view (``views/isonim_low_level_code_view.nim``) can
##   render a parity-faithful container shell + a fallback
##   instruction list usable from headless tests, and
## - mission goal #2's headless ViewModel tests can exercise the same
##   load / active-row / jump-to-instruction flow without depending on
##   Karax / Monaco.
##
## Reactive surface:
## - ``instructions``    — current asm instruction list (sorted by
##                         offset, mirroring the legacy backend reply
##                         which already arrives in offset order).
## - ``activeOffset``    — the offset of the row that should carry the
##                         ``active-instruction`` highlight class.
##                         Negative (default ``-1``) means "no row
##                         active" — matches the legacy ``NO_LINE`` /
##                         ``findHighlight = -1`` sentinel.
## - ``address``         — the function's load address.  Rendered as
##                         the panel's "Originating address" hex
##                         string when non-zero (mirrors the legacy
##                         ``Instructions.address`` field which the
##                         no-source panel also exposes).
## - ``errorMessage``    — backend-reported load error, replaces the
##                         listing when non-empty.
## - ``noirProject``     — flips the offset rendering to
##                         ``StepId(<offset>)`` for Noir traces
##                         (legacy ``isNoirProject`` branch in
##                         ``formatLine``).
##
## Derived:
## - ``isEmpty``         — convenience for the empty-state.
##
## Actions:
## - ``setInstructions``     — replace the row list wholesale.
## - ``setActiveOffset``     — refresh the active-row reference.
## - ``setAddress``          — set the function's load address.
## - ``setErrorMessage``     — set the load error message.
## - ``setNoirProject``      — toggle the Noir offset rendering.
## - ``loadAsmFor``          — emit a ``ct/load-asm-function`` request
##                             (mirrors the legacy ``loadAsm`` proc).
## - ``jumpToInstruction``   — move the debugger to the source line the
##                             clicked instruction was generated from,
##                             by emitting ``ct/source-line-jump``.
##                             Used by the IsoNim row click handler.
##
##                             This used to emit ``ct/asm-instruction-jump``,
##                             a command with no entry in
##                             ``EVENT_KIND_TO_DAP_MAPPING``, no entry in
##                             ``VALID_DAP_COMMANDS`` and no arm in
##                             ``dap_server.rs``.  The production
##                             ``sendProc`` (``ui_js.nim``) resolves the
##                             command string through
##                             ``dapCommandToEventKind`` *before* it
##                             reaches any transport, and that proc
##                             raises ``ValueError`` for an unmapped
##                             string — so every row click in this pane
##                             threw synchronously, out of the click
##                             handler, on both desktop and web.  The
##                             pane is reachable (``Alt+1`` →
##                             ``openLowLevelCode``) and its rows really
##                             populate (via ``ct/load-asm-function``),
##                             so this was a live crash on an ordinary
##                             gesture.
##
##                             ``ct/source-line-jump`` is what the legacy
##                             Karax editor dispatched for exactly this
##                             gesture (``ui/editor.nim`` ``editorLineJump``
##                             → ``sourceLineJump(path, instructions[i]
##                             .highLevelLine, ...)``), and unlike
##                             ``ct/local-step-jump`` it both moves the
##                             session *and* answers the request
##                             (``dap_handler.rs::source_line_jump`` ends
##                             in ``respond_dap``).

import std/json

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]
import ./generated_code_anchors

export generated_code_anchors

type
  LowLevelCodeVM* = ref object of ViewModel
    ## Reactive state for the Low Level Code panel.
    store*: ReplayDataStore

    # -- Mutable state --
    instructions*: Signal[seq[LowLevelInstruction]]
    activeOffset*: Signal[int]
    address*: Signal[int]
    errorMessage*: Signal[string]
    noirProject*: Signal[bool]

    # -- Anchoring (NS4, Generated-Code-Listing.md §3.1/§4) --
    anchors*: Signal[seq[MappingAnchor]]
      ## The installed mapping. EMPTY until a producer's anchors survive
      ## `validate`; see `setAnchors`.
    anchorDefects*: Signal[seq[AnchorDefect]]
      ## Why the last `setAnchors` was refused, empty when it was accepted.
      ## Kept as state rather than logged, because §4's requirement is that a
      ## suspension be VISIBLE — a pane that silently shows no mapping is
      ## indistinguishable from one whose producer is broken.
    syncSettings*: Signal[SyncSettings]

    # -- Derived state --
    isEmpty*: Memo[bool]
    hasAnchors*: Memo[bool]
    anchorsRejected*: Memo[bool]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

const NO_ACTIVE_OFFSET* = -1
  ## Sentinel matching the legacy ``NO_LINE`` / ``findHighlight = -1``
  ## "no row active" indicator.

proc isActiveRow*(instr: LowLevelInstruction; activeOffset: int): bool =
  ## True when ``instr`` should carry the ``active-instruction`` class.
  ## Mirrors the legacy ``editor.tabInfo.highlightLine`` lookup which
  ## walked ``instructionsMapping`` to find the row whose offset / line
  ## matches the live debugger position.  The VM caches the active
  ## offset directly so view re-renders do not require re-walking the
  ## mapping.
  activeOffset >= 0 and instr.offset == activeOffset

proc formatOffset*(instr: LowLevelInstruction; noir: bool): string =
  ## Mirrors the legacy ``formatLine`` offset column:
  ## ``StepId({offset})`` for Noir traces, plain ``{offset}`` otherwise.
  ## Exposed so headless tests can assert the column text without
  ## depending on the view layer.
  if instr.offset == -1:
    "<no step id>"
  elif noir:
    "StepId(" & $instr.offset & ")"
  else:
    $instr.offset

proc displayName*(instr: LowLevelInstruction): string =
  ## Mirrors the legacy ``formatLine`` ``name`` column.  The legacy
  ## code emitted ``<no instructions>`` for an empty name; we reproduce
  ## that exactly so a regression in the backend reply produces a
  ## visible placeholder rather than silently empty markup.
  if instr.name.len == 0:
    "<no instructions>"
  else:
    instr.name

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setInstructions*(vm: LowLevelCodeVM; instructions: seq[LowLevelInstruction]) =
  ## Replace the row list wholesale.  Used by the legacy
  ## ``onLoadAsmFunctionResponse`` handler when a fresh asm-load reply
  ## arrives.  The list is preserved in arrival order — the legacy
  ## backend already sends instructions sorted by offset, and the
  ## panel relies on that ordering for Monaco view-zone alignment.
  vm.instructions.val = instructions

proc setActiveOffset*(vm: LowLevelCodeVM; offset: int) =
  ## Refresh the active-row reference.  ``offset < 0`` means "no row
  ## active".  Mirrors the legacy ``editor.tabInfo.highlightLine``
  ## reset-on-load behaviour: callers pass ``NO_ACTIVE_OFFSET`` while
  ## a fresh request is in flight.
  vm.activeOffset.val = offset

proc setAddress*(vm: LowLevelCodeVM; address: int) =
  ## Set the function's load address.  Used by the IsoNim view to
  ## render the optional "Originating address: 0x..." line (mirrors
  ## the same line in the no_source panel).
  vm.address.val = address

proc setErrorMessage*(vm: LowLevelCodeVM; message: string) =
  ## Set / clear the backend-reported load error message.  Empty
  ## string clears the error overlay so the regular listing is shown.
  vm.errorMessage.val = message

proc setNoirProject*(vm: LowLevelCodeVM; noir: bool) =
  ## Toggle the Noir offset-display branch (``StepId(...)`` instead of
  ## a plain integer).  Mirrors the legacy ``isNoirProject`` check in
  ## ``low_level_code.nim::formatLine``.
  vm.noirProject.val = noir

proc clearInstructions*(vm: LowLevelCodeVM) =
  ## Reset the row list and the active-offset / error signals.  Called
  ## when starting a fresh asm-load so the previous run's rows do not
  ## bleed into the next.
  ##
  ## THE ANCHORS GO WITH THE ROWS.  Anchors are ranges of generated-row
  ## INDICES, so a mapping outliving the listing it was produced for still
  ## covers rows 0..n of whatever replaces it, and every synchronisation
  ## decision it makes would be confidently wrong rather than suspended —
  ## `Generated-Code-Listing.md` §4's exact failure.  The recorded defects go
  ## too: they describe the previous artefact's producer, and leaving them set
  ## would make the next artefact look rejected.
  vm.instructions.val = @[]
  vm.activeOffset.val = NO_ACTIVE_OFFSET
  vm.errorMessage.val = ""
  vm.anchors.val = @[]
  vm.anchorDefects.val = @[]

proc loadAsmFor*(vm: LowLevelCodeVM; path: string; functionName: string;
                 key: string = ""; forceReload: bool = false) =
  ## Emit a ``ct/load-asm-function`` request for the given function.
  ## Mirrors the legacy ``LowLevelCodeComponent.loadAsm`` proc which
  ## emitted ``CtLoadAsmFunction`` over the mediator.  Routing the
  ## request through the backend lets headless tests verify the
  ## end-to-end flow without depending on Karax / the mediator.
  ##
  ## Resets the row list and the active-offset / error signals before
  ## the response arrives — same pre-load reset the legacy ``clear``
  ## proc performed.
  vm.clearInstructions()
  let args = %*{
    "path": path,
    "name": functionName,
    "key": key,
    "forceReload": forceReload,
  }
  discard vm.store.backend.send("ct/load-asm-function", args)

proc jumpToInstruction*(vm: LowLevelCodeVM; instr: LowLevelInstruction) =
  ## Move the debugger to the source line ``instr`` was generated from.
  ##
  ## Emits ``ct/source-line-jump`` with the ``SourceLocation`` shape
  ## ``dap_server.rs`` deserialises for that arm
  ## (``{"path": string, "line": usize}``) — the same request the legacy
  ## Karax editor sent for this gesture.  ``line`` is ``usize`` on the
  ## Rust side, so a row without a usable back-pointer must not be put
  ## on the wire: the engine would answer ``unknown location`` at best
  ## and fail to deserialise at worst.
  ##
  ## ``highLevelPath`` is forwarded VERBATIM and must stay that way.
  ## ``dap_handler.rs::load_asm_function`` fills it from
  ## ``self.reader.path(step.path_id)`` — the trace's raw path table —
  ## and ``get_closest_step_id`` matches against that same table.  Note
  ## that ``ct/complete-move`` reports the *same file* with a ``./``
  ## prefix; normalising this path towards the reported form would break
  ## the lookup (``unknown location: ./foo.rs:18``).
  ##
  ## That last sentence has an expiry date.  ``Handler::load_path_id``
  ## (``dap_handler.rs``) now resolves through ``fuzzy_path_id_for``, which
  ## accepts both spellings — so once an engine carrying that change ships,
  ## the reported form works too and this caveat can go.  Forwarding
  ## verbatim stays correct either way, which is why it is still the rule
  ## here.
  ##
  ## A row can legitimately lack a back-pointer (asm generated from a
  ## function with no debug info).  That case reports through
  ## ``errorMessage`` rather than returning silently, so a click that
  ## cannot move the session says so in the pane instead of looking
  ## like a click that was never registered.
  if instr.highLevelPath.len == 0 or instr.highLevelLine <= 0:
    vm.setErrorMessage(
      "no source line recorded for this instruction — nothing to jump to")
    return
  vm.setErrorMessage("")
  let args = %*{
    "path": instr.highLevelPath,
    "line": instr.highLevelLine,
  }
  discard vm.store.backend.send("ct/source-line-jump", args)

# ---------------------------------------------------------------------------
# Anchoring
#
# The pane's half of `generated_code_anchors`. The model decides what a mapping
# may claim; this decides what the panel DOES with a mapping that claims it —
# and the answer for a defective one is: refuse it, and say why.
# ---------------------------------------------------------------------------

proc setAnchors*(vm: LowLevelCodeVM; anchors: seq[MappingAnchor];
                 support: ArtefactSupport): bool {.discardable.} =
  ## Install a producer's anchors, or REFUSE them.
  ##
  ## Returns true when they were installed. A defective set is not installed
  ## partially and not installed at all: `validate` catches claims that are
  ## wrong by construction, and a pane showing the valid half of a mapping it
  ## knows to be broken is making the same confident-wrong-answer error §4
  ## warns about, only over fewer rows.
  ##
  ## The refusal is RECORDED, not just returned. `anchorDefects` drives the
  ## pane's own "the mapping for this artefact was rejected" state; a caller
  ## that ignores the bool still cannot end up with a silently empty listing
  ## that looks like an artefact with no debug info.
  let defects = validate(anchors, support)
  if defects.len > 0:
    vm.anchors.val = @[]
    vm.anchorDefects.val = defects
    return false
  vm.anchors.val = anchors
  vm.anchorDefects.val = @[]
  true

proc clearAnchors*(vm: LowLevelCodeVM) =
  ## Drop the mapping and any recorded refusal. Called when a fresh artefact
  ## is loaded, so a previous function's anchors cannot be synchronised
  ## against the current listing — rows would still be covered and the
  ## decisions would be confidently wrong.
  vm.anchors.val = @[]
  vm.anchorDefects.val = @[]

proc setSyncEnabled*(vm: LowLevelCodeVM; enabled: bool) =
  ## §3's toggle. Defaults on; turning it off yields `soDisabled` rather than
  ## `soSuspended`, because "you turned it off" and "the mapping ran out here"
  ## are different things for the pane to show.
  vm.syncSettings.val = SyncSettings(enabled: enabled)

proc syncFromGeneratedRow*(vm: LowLevelCodeVM; row: int): SyncDecision =
  ## Generated row -> source, against the installed anchors.
  syncFromGenerated(vm.anchors.val, row, vm.syncSettings.val)

proc syncFromSourceLine*(vm: LowLevelCodeVM; path: string;
                         line: int): SyncDecision =
  ## Source line -> generated, the same rule in the other direction.
  syncFromSource(vm.anchors.val, path, line, vm.syncSettings.val)

proc sourcesFor*(vm: LowLevelCodeVM; decision: SyncDecision): seq[SourceRegion] =
  ## Every contributing source for an aligned decision — a seq for all rungs,
  ## so a caller wanting "the" source has to notice it may get more than one.
  counterpartSources(vm.anchors.val, decision)

proc rowsFor*(vm: LowLevelCodeVM; decision: SyncDecision): (int, int) =
  ## The inclusive generated row range to reveal for an aligned decision.
  counterpartRows(vm.anchors.val, decision)

proc fidelityAtRow*(vm: LowLevelCodeVM; row: int): MappingFidelity =
  ## The rung covering a generated row, for the pane's per-row fidelity badge.
  ## A row no anchor covers is `mfUnmapped` — the same answer as an anchored
  ## row with no debug info, and correctly so: in both cases nothing is known
  ## about this row's source.
  for a in vm.anchors.val:
    if row >= a.generatedFirst and row <= a.generatedLast:
      return a.fidelity
  mfUnmapped

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createLowLevelCodeVM*(store: ReplayDataStore): LowLevelCodeVM =
  ## Create a LowLevelCodeVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.  Sets every signal to its empty/inert default
  ## so the view renders the empty placeholder on first paint.
  withViewModel proc(dispose: proc()): LowLevelCodeVM =
    let instructions = createSignal(newSeq[LowLevelInstruction]())
    let activeOffset = createSignal(NO_ACTIVE_OFFSET)
    let address = createSignal(0)
    let errorMessage = createSignal("")
    let noirProject = createSignal(false)
    let anchors = createSignal(newSeq[MappingAnchor]())
    let anchorDefects = createSignal(newSeq[AnchorDefect]())
    let syncSettings = createSignal(DefaultSyncSettings)

    let isEmpty = createMemo[bool] proc(): bool =
      instructions.val.len == 0

    let hasAnchors = createMemo[bool] proc(): bool =
      anchors.val.len > 0

    # DISTINCT from `not hasAnchors`, and that is the point: an artefact with
    # no debug info and a producer whose mapping was REFUSED both leave the
    # anchor list empty, and the pane must not show them the same way.
    let anchorsRejected = createMemo[bool] proc(): bool =
      anchorDefects.val.len > 0

    LowLevelCodeVM(
      store: store,
      instructions: instructions,
      activeOffset: activeOffset,
      address: address,
      errorMessage: errorMessage,
      noirProject: noirProject,
      anchors: anchors,
      anchorDefects: anchorDefects,
      syncSettings: syncSettings,
      isEmpty: isEmpty,
      hasAnchors: hasAnchors,
      anchorsRejected: anchorsRejected,
      disposeProc: dispose,
    )
