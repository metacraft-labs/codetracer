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
## - ``jumpToInstruction``   — emit a ``ct/asm-instruction-jump``
##                             request carrying the row's ``offset`` /
##                             ``highLevelPath`` / ``highLevelLine``.
##                             Used by the IsoNim row click handler so
##                             headless tests can verify the wire
##                             shape.

import std/json

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

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

    # -- Derived state --
    isEmpty*: Memo[bool]

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
  vm.instructions.val = @[]
  vm.activeOffset.val = NO_ACTIVE_OFFSET
  vm.errorMessage.val = ""

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
  ## Dispatch a ``ct/asm-instruction-jump`` request for the given row.
  ## Used by the IsoNim row click handler.  Carries the row's
  ## ``offset`` plus the instruction's ``highLevelPath`` /
  ## ``highLevelLine`` so the live debugger can either jump to the
  ## corresponding source line (the legacy editor used Monaco's click
  ## handler to call ``self.sourceLineJump``) or step to the matching
  ## asm offset.
  let args = %*{
    "offset": instr.offset,
    "highLevelPath": instr.highLevelPath,
    "highLevelLine": instr.highLevelLine,
  }
  discard vm.store.backend.send("ct/asm-instruction-jump", args)

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

    let isEmpty = createMemo[bool] proc(): bool =
      instructions.val.len == 0

    LowLevelCodeVM(
      store: store,
      instructions: instructions,
      activeOffset: activeOffset,
      address: address,
      errorMessage: errorMessage,
      noirProject: noirProject,
      isEmpty: isEmpty,
      disposeProc: dispose,
    )
