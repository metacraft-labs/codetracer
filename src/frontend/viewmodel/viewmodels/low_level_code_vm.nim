## viewmodels/low_level_code_vm.nim
##
## LowLevelCodeVM — ViewModel for the Low Level Code panel.
##
## The pane shows the assembly / IR listing of the function the debugger is
## in, grouped under the source lines it was generated from
## (Shared-DOM-Front-Ends D7.2). It is loaded per stop by the session's stop
## loader (`sdk/stop_loader`, `spLowLevelCode`) while the pane is shown
## (`shown`, set by the host that mounts it): the request is
## `ct/load-asm-function` for the store's `asmFunction` — the C-level location
## for a Nim recording — and the answer lands here (`applyAsmAnswer`). The
## source text of each group is fetched through the DAP `source` request
## (`sdk/source_provider.newDapSourceProvider`), so it works over every
## transport, and a view sets it as TEXT: a line of the recorded program's
## own source is markup by construction for HTML, JSX or template files.
##
## Reactive surface:
## - ``instructions``    — the listing, in the engine's order.
## - ``activeLine`` / ``activePath`` — where the debugger is in the
##                         listing's source: rows generated from that line are
##                         the active ones (``isActiveInstruction``).
## - ``activeOffset``    — a row marked by offset instead, for a generated-code
##                         listing anchored to a cursor (`showGeneratedListing`).
## - ``address``         — the function's load address, shown when non-zero.
## - ``errorMessage``    — a load error or notice, shown above the listing.
## - ``noirProject``     — offsets render as ``StepId(<offset>)``.
## - ``sourceText``      — the text of each group's source line, by
##                         ``sourceKey(path, line)``.
## - ``shown``           — whether a front-end is showing the pane; the stop
##                         loader asks only then.
##
## Actions: ``applyAsmAnswer``, ``loadAsmFor``, ``jumpToInstruction``,
## ``showGeneratedListing``, the setters, and the anchoring (`setAnchors`
## and the sync queries) of `Generated-Code-Listing.md`.
##
## ``jumpToInstruction`` emits ``ct/source-line-jump`` — what the desktop's
## editor dispatched for this gesture, and an engine command that both moves
## the session and answers (``dap_handler.rs::source_line_jump``). It used to
## emit ``ct/asm-instruction-jump``, which no transport maps, and threw on
## every row click.

import std/[json, strutils, tables]

import isonim/core/[signals, computation, owner, async_compat]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]
from ../store/stop_timeline import stopIdentityOf
import ./generated_code_anchors
from ./source_vm import SourceLineRequest
from ../sdk/source_provider import SourceProvider, SourceFetch,
  newDapSourceProvider, fetch, hasText

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
    activeLine*: Signal[int]
      ## The source line the debugger is at, in the listing's source
      ## (`AsmFunctionLocation.line`); 0 when none.
    activePath*: Signal[string]
      ## The file `activeLine` is in; "" matches any.
    sourceText*: Signal[Table[string, string]]
      ## The text of each group's source line, by `sourceKey(path, line)`.
    shown*: Signal[bool]
      ## Whether a front-end shows the pane: the stop loader asks only then.
    generatedAtStop*: Signal[string]
      ## The stop (`stopIdentityOf`) at which a generated-code listing was
      ## painted (`showGeneratedListing`), "" when the pane shows the
      ## recording's own code. The stop loader asks nothing at that stop and
      ## drops an answer that lands after it, so opening the pane for the
      ## listing does not replace it; the next move loads the recording's
      ## code again.
    sources: SourceProvider
      ## Where source text comes from; a DAP provider over the store's
      ## backend unless something installed another (the suites do).

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

proc sourceKey*(path: string; line: int): string =
  ## The key of one source line in `sourceText`.
  path & "\x1f" & $line

proc isActiveInstruction*(instr: LowLevelInstruction; activeLine: int;
                          activePath: string; activeOffset: int): bool =
  ## Whether `instr` is one of the rows the debugger's position marks: one
  ## generated from the source line it is at, or the row a generated-code
  ## cursor anchored by offset.
  (activeLine > 0 and instr.highLevelLine == activeLine and
   (activePath.len == 0 or instr.highLevelPath == activePath)) or
    (activeOffset >= 0 and instr.offset == activeOffset)

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
  ## Replace the row list wholesale, in the order given: the engine answers
  ## in offset order, and the groups follow it.
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
  ## a plain integer).
  vm.noirProject.val = noir

proc setShown*(vm: LowLevelCodeVM; shown: bool) =
  ## A front-end shows the pane (or stops). The host that mounts the view
  ## sets it; the stop loader loads the listing only while it is set.
  if vm.shown.val != shown:
    vm.shown.val = shown

proc setActiveLine*(vm: LowLevelCodeVM; path: string; line: int) =
  ## Where the debugger is in the listing's source.
  vm.activePath.val = path
  vm.activeLine.val = line

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
  vm.sourceText.val = initTable[string, string]()
  vm.generatedAtStop.val = ""

func instructionOf*(node: JsonNode): LowLevelInstruction =
  ## One `Instruction` of the engine's answer (`src/db-backend/src/task.rs`).
  LowLevelInstruction(
    name: node{"name"}.getStr(""),
    args: node{"args"}.getStr(""),
    other: node{"other"}.getStr(""),
    offset: node{"offset"}.getInt(-1),
    highLevelPath: node{"highLevelPath"}.getStr(""),
    highLevelLine: node{"highLevelLine"}.getInt(0))

func instructionListOf*(body: JsonNode): LowLevelInstructionList =
  ## The body of a `ct/load-asm-function` answer (`Instructions`: `address`,
  ## `instructions`, `error`).
  if body.isNil or body.kind != JObject:
    return
  result.address = body{"address"}.getInt(0)
  result.error = body{"error"}.getStr("")
  for n in body{"instructions"}.getElems:
    result.instructions.add instructionOf(n)

proc loadSourceText*(vm: LowLevelCodeVM) =
  ## Fetch the text of every source line the listing's groups name: one
  ## request per file, over the lines it uses. A file the provider cannot
  ## serve leaves its lines without text; the groups still show path and
  ## line.
  var ranges = initOrderedTable[string, (int, int)]()
  for instr in vm.instructions.val:
    if instr.highLevelPath.len == 0 or instr.highLevelLine <= 0:
      continue
    let r = ranges.getOrDefault(instr.highLevelPath,
                                (instr.highLevelLine, instr.highLevelLine))
    ranges[instr.highLevelPath] = (min(r[0], instr.highLevelLine),
                                   max(r[1], instr.highLevelLine))
  if ranges.len == 0:
    return
  if vm.sources.isNil:
    if vm.store.isNil or vm.store.backend.isNil:
      return
    vm.sources = newDapSourceProvider(vm.store.backend)
  let listing = vm.instructions.val
  let theVm = vm
  for path, r in ranges:
    let request = SourceLineRequest(path: path, firstLine: r[0], lastLine: r[1])
    vm.sources.fetch(request, proc(answer: SourceFetch) =
      # The listing may have been replaced while the text was asked for.
      if theVm.instructions.val != listing or not answer.hasText:
        return
      # A fresh table: on the JS backend a mutated signal value compares
      # equal to itself and notifies nobody.
      var table = initTable[string, string]()
      for k, v in theVm.sourceText.val: table[k] = v
      for i, line in answer.lines:
        table[sourceKey(answer.request.path, answer.firstLine + i)] = line
      theVm.sourceText.val = table)

proc applyAsmAnswer*(vm: LowLevelCodeVM; body: JsonNode;
                     fn: AsmFunctionLocation) =
  ## Show the engine's answer for `fn`: the listing, its address, an error the
  ## engine reported, which rows the debugger's line marks, and the groups'
  ## source text.
  let list = instructionListOf(body)
  vm.clearInstructions()
  vm.instructions.val = list.instructions
  vm.address.val = list.address
  vm.errorMessage.val = list.error
  vm.noirProject.val = fn.path.endsWith(".nr")
  vm.setActiveLine(fn.path, fn.line)
  vm.loadSourceText()

proc asmFunctionArgs*(fn: AsmFunctionLocation): JsonNode =
  ## The `ct/load-asm-function` arguments (`FunctionLocation`, which refuses
  ## unknown fields).
  %*{"path": fn.path, "name": fn.name, "key": fn.key,
     "forceReload": fn.forceReload}

proc loadAsmFor*(vm: LowLevelCodeVM; path: string; functionName: string;
                 key: string = ""; forceReload: bool = false;
                 line: int = 0) =
  ## Ask for the listing of one function and show it — for a host that names
  ## the function itself. The session's stop loader does this per stop for
  ## the function the debugger is in.
  vm.clearInstructions()
  let fn = AsmFunctionLocation(path: path, name: functionName, key: key,
                               line: line, forceReload: forceReload)
  let theVm = vm
  onComplete(vm.store.backend.send("ct/load-asm-function", asmFunctionArgs(fn)),
    proc(response: JsonNode) =
      if responseSucceeded(response):
        theVm.applyAsmAnswer(responseBody(response), fn)
      else:
        theVm.setErrorMessage(
          "the low-level code of " & fn.name & " could not be loaded: " &
          response{"message"}.getStr("the engine refused the request")),
    proc(message: string) =
      theVm.setErrorMessage(
        "the low-level code of " & fn.name & " could not be loaded: " &
        message))

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

proc showGeneratedListing*(vm: LowLevelCodeVM;
                           rows: seq[LowLevelInstruction];
                           anchors: seq[MappingAnchor];
                           support: ArtefactSupport;
                           sourcePath: string; sourceLine: int;
                           notice: string): bool {.discardable.} =
  ## Paint a generated-code listing into this pane, anchored to a cursor
  ## (`Generated-Code-Listing.md` §7; the pane stands in for the spec's
  ## editor tab, which is recorded there as a divergence).
  ##
  ## Returns whether the ANCHORS were installed. False is an answer, not an
  ## error: `setAnchors` refuses a set `validate` rejects, wholesale. The rows
  ## are painted either way — a listing whose mapping was refused is still the
  ## compiler's own output, and §5's rule is that it says so rather than
  ## disappearing.
  vm.setInstructions(rows)
  vm.setErrorMessage(notice)
  vm.setNoirProject(true)
  vm.setActiveLine("", 0)
  vm.sourceText.val = initTable[string, string]()
  if not vm.store.isNil:
    vm.generatedAtStop.val = stopIdentityOf(vm.store.debugger.val)
  vm.setActiveOffset(NO_ACTIVE_OFFSET)
  vm.clearAnchors()
  if anchors.len == 0:
    return false
  if not vm.setAnchors(anchors, support):
    return false
  # The cursor is what the pane now shows: without it the pane holds a
  # correct mapping and points at nothing.
  let decision = vm.syncFromSourceLine(sourcePath, sourceLine)
  if decision.outcome == soAligned:
    let (first, _) = vm.rowsFor(decision)
    if first >= 0 and first < rows.len:
      vm.setActiveOffset(rows[first].offset)
  true

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
    let activeLine = createSignal(0)
    let activePath = createSignal("")
    let sourceText = createSignal(initTable[string, string]())
    let shown = createSignal(false)
    let generatedAtStop = createSignal("")
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
      activeLine: activeLine,
      activePath: activePath,
      sourceText: sourceText,
      shown: shown,
      generatedAtStop: generatedAtStop,
      anchors: anchors,
      anchorDefects: anchorDefects,
      syncSettings: syncSettings,
      isEmpty: isEmpty,
      hasAnchors: hasAnchors,
      anchorsRejected: anchorsRejected,
      disposeProc: dispose,
    )
