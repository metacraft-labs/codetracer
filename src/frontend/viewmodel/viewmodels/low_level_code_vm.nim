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
## ## ONE LISTING FOR EVERY FRONT-END (PLAT-60)
##
## The desktop's panel, the terminal's pane and the GPUI window's pane draw
## the same listing, so what a row SAYS and how the listing RELATES to the
## source are decided here, not in a view:
##
## - ``displayRows`` — the listing as rows: each run of instructions generated
##   from one source line preceded by that line, every cell's words, which
##   rows the debugger's line marks, the EXECUTION POINTER (the instruction
##   the debugger is at, ``executionIndex``), the rows CROSS-REFERENCED to the
##   source line the editor's cursor is on (``sourceCursor``), and the
##   listing's own cursor (``selected``).
## - the cross-reference both ways: a source line to the instructions
##   generated from it (``linkedIndices``), and the selected instruction back
##   to its source line (``crossRefSource``), which an editor highlights.
##   Through the anchors when a generated-code listing carries them, through
##   each instruction's own back-pointer otherwise.
## - the header's words (``addressText``, ``mappingNotice``, ``steppingText``,
##   ``emptyText``) and the row menu (``rowMenu`` / ``runRowMenu``).
## - stepping at instruction granularity: offered when the engine says it
##   steps by instruction (DAP ``supportsSteppingGranularity``,
##   ``instructionStepOffered``); the request is ``instructionStepRequest``.
##   No engine in this tree offers it yet, and the panes say so.
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
  SourceLineRef* = object
    ## One source line, as an editor names it. `line` 0 is "none"; `path` ""
    ## matches any file.
    path*: string
    line*: int

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
    sourceCursor*: Signal[SourceLineRef]
      ## PLAT-60. The source line the editor's cursor is on, as the host that
      ## owns the editor reports it (`setSourceCursor`): the rows generated
      ## from it are the cross-referenced ones (`linkedIndices`).
    selected*: Signal[int]
      ## PLAT-60. The listing's own cursor — the instruction a press, the
      ## keys or a menu chose — by index into `instructions`, -1 for none.
      ## Its source line is what an editor cross-references
      ## (`crossRefSource`).
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

const NoSelectedInstruction* = -1
  ## `selected` when the listing's cursor is on no instruction.

const NO_ACTIVE_OFFSET* = -1
  ## Sentinel matching the legacy ``NO_LINE`` / ``findHighlight = -1``
  ## "no row active" indicator.

proc sourceKey*(path: string; line: int): string =
  ## The key of one source line in `sourceText`.
  path & "\x1f" & $line

func sameSourcePath*(a, b: string): bool =
  ## Whether two spellings name one recorded file: equal, or one the other's
  ## tail at a path separator. The engine writes an instruction's source as
  ## the trace's path table holds it — relative to the recording's working
  ## directory for a Noir recording (`src/main.nr`) — while a move reports
  ## the same file by its full path, and so does the editor. Compared
  ## verbatim, the debugger's line marked no row of a Noir listing.
  if a.len == 0 or b.len == 0: return false
  if a == b: return true
  let (short, long) = if a.len < b.len: (a, b) else: (b, a)
  not short.startsWith("/") and long.endsWith(short) and
    long[long.len - short.len - 1] == '/'

proc isActiveInstruction*(instr: LowLevelInstruction; activeLine: int;
                          activePath: string; activeOffset: int): bool =
  ## Whether `instr` is one of the rows the debugger's position marks: one
  ## generated from the source line it is at, or the row a generated-code
  ## cursor anchored by offset.
  (activeLine > 0 and instr.highLevelLine == activeLine and
   (activePath.len == 0 or sameSourcePath(instr.highLevelPath, activePath))) or
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
  # The listing's cursor named a row of the listing being replaced.
  vm.selected.val = NoSelectedInstruction

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
# PLAT-60: the listing every front-end draws
#
# The desktop's panel (`views/isonim_low_level_code_view`), the terminal's
# pane (`tui/app/views/low_level_code_pane`) and the GPUI window's
# (`gpui/low_level_code_leaf`) read the rows, the words, the cross-reference
# and the menu below; none of them decides any of it.
# ---------------------------------------------------------------------------

const
  LowLevelCodeTitle* = "Low Level Code"
    ## The pane's name, as the desktop's layout tab and View menu say it.
  LowLevelEmptyText* = "No low-level code at this position."
    ## What the listing says when the engine answered no instruction and no
    ## error: a blank region would read as a pane that never loaded.
  NoSourceLineReason* = "no source line recorded for this instruction"
    ## Why an instruction cannot go to (or show) its source line.
  SteppingByInstructionText* = "steps by instruction"
  SteppingByLineText* = "steps by line"
    ## The header's statement of what a step does while the listing has the
    ## focus (`steppingText`).
  InstructionSteppingRefusal* = "this recording's engine steps by source " &
    "line: it offers no stepping by instruction"
    ## What a step pressed in the listing says when the engine offers no
    ## instruction granularity — the step still happens, by line.

type
  LowLevelRowKind* = enum
    lrkSource       ## a source line, before the instructions generated from it
    lrkInstruction  ## one instruction

  LowLevelRowView* = object
    ## Everything one row of the listing shows, in every front-end. Compared
    ## whole by the desktop's keyed list, so a row whose view is unchanged
    ## keeps its node.
    kind*: LowLevelRowKind
    key*: string
    active*: bool
      ## The debugger's line marks it (its source line, or an instruction
      ## generated from that line).
    linked*: bool
      ## Cross-referenced: a source row the selected instruction came from,
      ## or an instruction generated from the line the editor's cursor is on.
    # lrkSource
    path*: string
    line*: int
    text*: string
    # lrkInstruction
    index*: int
      ## The instruction's position in `LowLevelCodeVM.instructions`.
    executing*: bool
      ## The EXECUTION POINTER: the instruction the debugger is at
      ## (`executionIndex`).
    selected*: bool
      ## The listing's own cursor is on it.
    offsetText*, name*, args*, other*, crossRef*: string
    fidelity*: MappingFidelity
    fidelityText*, countText*: string

  LowLevelNoticeKind* = enum
    ## Why the listing is not kept in step with the source, for the header.
    lnkNone        ## it is (or there is nothing to keep in step)
    lnkDisabled    ## the user turned source syncing off
    lnkRefused     ## the producer's mapping was refused (`anchorsRejected`)
    lnkSuspended   ## a generated listing with no mapping at all

  LowLevelMenuAction* = enum
    ## The row menu's entries, in its order (`rowMenu`).
    llmGoToSourceLine    ## move the debugger to the instruction's line
    llmShowSourceLine    ## select it: the editor shows its line, no move
    llmCopyInstruction   ## the row's text to the clipboard
    llmCopySourceLocation  ## `path:line` to the clipboard

  LowLevelMenuEntry* = object
    label*: string
    action*: LowLevelMenuAction
    enabled*: bool
    reason*: string
      ## Why a disabled entry is disabled.

  LowLevelMenuOutcome* = object
    ## What a chosen entry did, for the host: its words for the status line,
    ## text for the clipboard, whether the debugger was asked to move.
    note*: string
    copied*: string
    moved*: bool
    jumpTo*: SourceLineRef
      ## Go to Source Line chosen with `send` false: the line a host that
      ## drives the engine itself (the native ones) moves the debugger to.

  InstructionStepRequest* = object
    ## A step at instruction granularity, as DAP spells it, or why not.
    offered*: bool
    command*: string
    args*: JsonNode
    note*: string

const LowLevelMenuLabels*: array[LowLevelMenuAction, string] = [
  "Go to Source Line", "Show Source Line", "Copy Instruction",
  "Copy Source Location"]

proc addressText*(address: int): string =
  ## The header's load address line (the desktop's no-source panel's words).
  "Originating address: 0x" & toHex(address)

proc sourceCrossRef*(instr: LowLevelInstruction): string =
  ## The row's `path:line`, "" when the instruction carries no source line.
  if instr.highLevelLine <= 0 or instr.highLevelPath.len == 0:
    ""
  else:
    instr.highLevelPath & ":" & $instr.highLevelLine

proc hasSourceLine*(instr: LowLevelInstruction): bool =
  instr.highLevelPath.len > 0 and instr.highLevelLine > 0

proc syncToggleLabel*(enabled: bool): string =
  if enabled: "sync on" else: "sync off"

proc noticeKind*(vm: LowLevelCodeVM): LowLevelNoticeKind =
  if not vm.syncSettings.val.enabled: lnkDisabled
  elif vm.anchorsRejected.val: lnkRefused
  elif not vm.hasAnchors.val and vm.instructions.val.len > 0 and
       vm.generatedAtStop.val.len > 0:
    # Only a GENERATED listing is kept in step by a mapping; the recording's
    # own code is kept in step by each instruction's source line.
    lnkSuspended
  else: lnkNone

proc mappingNotice*(vm: LowLevelCodeVM): string =
  ## Why the listing is not kept in step with the source, "" when it is.
  case vm.noticeKind
  of lnkDisabled: "source syncing is off"
  of lnkRefused: "the source mapping here could not be used, so these " &
    "panes are not kept in step"
  of lnkSuspended: "there is no source mapping here, so these panes are " &
    "not kept in step"
  of lnkNone: ""

proc instructionStepOffered*(vm: LowLevelCodeVM): bool =
  ## Whether the engine steps by instruction (DAP
  ## `supportsSteppingGranularity`, which the session's store records).
  not vm.store.isNil and vm.store.session.val.supportsSteppingGranularity

proc steppingText*(vm: LowLevelCodeVM): string =
  ## What a step does while the listing has the focus.
  if vm.instructionStepOffered: SteppingByInstructionText
  else: SteppingByLineText

proc emptyText*(vm: LowLevelCodeVM): string =
  ## The listing's words when it holds no instruction and the header shows no
  ## error: "" otherwise.
  if vm.instructions.val.len == 0 and vm.errorMessage.val.len == 0:
    LowLevelEmptyText
  else: ""

proc executionIndexIn*(instructions: seq[LowLevelInstruction]; ticks: uint64;
                       ownCode: bool; activeLine: int; activePath: string;
                       activeOffset: int): int =
  ## THE EXECUTION POINTER: the instruction the debugger is at.
  ##
  ## For the recording's own code (`ownCode`), each instruction's `offset` is
  ## the step it was reached at (`dap_handler.rs::load_asm_function`), and a
  ## step is what the debugger's tick counts on a materialized recording
  ## (`Location.rr_ticks = step_id`): the row whose offset is the tick is the
  ## current one. A generated-code listing's offsets are row indices, so only
  ## the anchored row (`activeOffset`) can be. Failing both, the first
  ## instruction of the line the debugger is at. -1 when none applies.
  if ownCode:
    for i, instr in instructions:
      if instr.offset >= 0 and uint64(instr.offset) == ticks:
        return i
  if activeOffset >= 0:
    for i, instr in instructions:
      if instr.offset == activeOffset:
        return i
  if activeLine > 0:
    for i, instr in instructions:
      if instr.highLevelLine == activeLine and
         (activePath.len == 0 or sameSourcePath(instr.highLevelPath,
                                                activePath)):
        return i
  -1

proc executionIndex*(vm: LowLevelCodeVM): int =
  let ticks = if vm.store.isNil: 0'u64 else: vm.store.debugger.val.rrTicks
  executionIndexIn(vm.instructions.val, ticks,
                   ownCode = vm.generatedAtStop.val.len == 0,
                   vm.activeLine.val, vm.activePath.val,
                   vm.activeOffset.val)

proc sameSourceLine(path: string; line: int; at: SourceLineRef): bool =
  at.line > 0 and line == at.line and
    (at.path.len == 0 or path.len == 0 or sameSourcePath(path, at.path))

proc linkedIndices*(vm: LowLevelCodeVM): seq[int] =
  ## SOURCE → INSTRUCTIONS: the instructions generated from the line the
  ## editor's cursor is on. Through the anchors when the listing carries a
  ## mapping (a generated-code listing), else through each instruction's own
  ## source line. Empty when the cursor is on no line any instruction came
  ## from — or when the user turned source syncing off.
  let at = vm.sourceCursor.val
  if at.line <= 0 or not vm.syncSettings.val.enabled:
    return
  let rows = vm.instructions.val
  if vm.anchors.val.len > 0:
    let decision = vm.syncFromSourceLine(at.path, at.line)
    if decision.outcome == soAligned:
      let (first, last) = vm.rowsFor(decision)
      for i in max(0, first) .. min(rows.high, last):
        result.add i
    return
  for i, instr in rows:
    if sameSourceLine(instr.highLevelPath, instr.highLevelLine, at):
      result.add i

proc sourceLineOf*(vm: LowLevelCodeVM; index: int): SourceLineRef =
  ## INSTRUCTION → SOURCE: the line instruction `index` was generated from,
  ## through the anchors when the listing carries them; `line` 0 when none.
  let rows = vm.instructions.val
  if index < 0 or index >= rows.len:
    return
  if vm.anchors.val.len > 0:
    let sources = vm.sourcesFor(vm.syncFromGeneratedRow(index))
    if sources.len > 0:
      return SourceLineRef(path: sources[0].path, line: sources[0].startLine)
    return
  if rows[index].hasSourceLine:
    SourceLineRef(path: rows[index].highLevelPath,
                  line: rows[index].highLevelLine)
  else: SourceLineRef()

proc crossRefSource*(vm: LowLevelCodeVM): SourceLineRef =
  ## The source line an editor highlights for the listing: the selected
  ## instruction's, `line` 0 when nothing is selected, the instruction has no
  ## source line, or source syncing is off.
  if not vm.syncSettings.val.enabled:
    return
  vm.sourceLineOf(vm.selected.val)

proc instructionText*(instr: LowLevelInstruction; noir: bool): string =
  ## A row as one line of text — what Copy Instruction copies.
  result = formatOffset(instr, noir) & "  " & displayName(instr)
  if instr.args.len > 0: result.add " " & instr.args
  if instr.other.len > 0: result.add " " & instr.other

proc displayRows*(vm: LowLevelCodeVM): seq[LowLevelRowView] =
  ## The listing as rows: each run of instructions generated from one source
  ## line is preceded by that line. Reads the signals it depends on, so a list
  ## built over it follows them.
  let instructions = vm.instructions.val
  let activeLine = vm.activeLine.val
  let activePath = vm.activePath.val
  let activeOffset = vm.activeOffset.val
  let noir = vm.noirProject.val
  let anchors = vm.anchors.val
  let sources = vm.sourceText.val
  let selected = vm.selected.val
  let executing = vm.executionIndex
  let linked = vm.linkedIndices
  let crossRef = vm.crossRefSource
  var offsetSeen = initTable[int, int]()
  var lineSeen = initTable[string, int]()
  var groupPath = ""
  var groupLine = 0
  for i, instr in instructions:
    let hasSource = instr.hasSourceLine
    if hasSource and (instr.highLevelPath != groupPath or
                      instr.highLevelLine != groupLine):
      groupPath = instr.highLevelPath
      groupLine = instr.highLevelLine
      let lineKey = sourceKey(groupPath, groupLine)
      let ordinal = lineSeen.getOrDefault(lineKey, 0)
      lineSeen[lineKey] = ordinal + 1
      result.add LowLevelRowView(
        kind: lrkSource,
        key: "src:" & lineKey & "#" & $ordinal,
        active: activeLine > 0 and groupLine == activeLine and
                (activePath.len == 0 or sameSourcePath(groupPath, activePath)),
        linked: sameSourceLine(groupPath, groupLine, crossRef),
        path: groupPath,
        line: groupLine,
        text: sources.getOrDefault(lineKey, ""),
        index: -1)
    elif not hasSource:
      groupPath = ""
      groupLine = 0
    let ordinal = offsetSeen.getOrDefault(instr.offset, 0)
    offsetSeen[instr.offset] = ordinal + 1
    # ROW INDEX, not offset, for the anchors: they are ranges of
    # generated-row indices (`Generated-Code-Listing.md` GCL-D6).
    let fidelity = vm.fidelityAtRow(i)
    var count = ExecutedCount(value: 0, provenance: cpNone)
    let at = anchorIndexAtRow(anchors, i)
    if at != NoAnchor:
      count = anchors[at].count
    result.add LowLevelRowView(
      kind: lrkInstruction,
      key: "op:" & $instr.offset & "#" & $ordinal,
      active: isActiveInstruction(instr, activeLine, activePath, activeOffset),
      linked: i in linked,
      index: i,
      executing: i == executing,
      selected: i == selected,
      offsetText: formatOffset(instr, noir),
      name: displayName(instr),
      args: instr.args,
      other: instr.other,
      crossRef: sourceCrossRef(instr),
      fidelity: fidelity,
      fidelityText: label(fidelity),
      # No count for `cpNone`: a rendered `0` would read as "never ran", a
      # measurement the pane did not make (GCL-D3).
      countText: countLabel(count))

proc displayIndexOf*(rows: seq[LowLevelRowView]; index: int): int =
  ## The display row that draws instruction `index`, -1 when none does.
  for k, r in rows:
    if r.kind == lrkInstruction and r.index == index:
      return k
  -1

proc setSourceCursor*(vm: LowLevelCodeVM; path: string; line: int) =
  ## The editor's cursor is on `path:line` (the host that owns the editor
  ## reports it). `line` 0 clears it.
  let at = SourceLineRef(path: path, line: max(0, line))
  if vm.sourceCursor.val != at:
    vm.sourceCursor.val = at

proc selectInstruction*(vm: LowLevelCodeVM; index: int) =
  ## Put the listing's cursor on instruction `index` (clamped); -1 clears it.
  let n = vm.instructions.val.len
  let i = if index < 0 or n == 0: NoSelectedInstruction
          else: min(index, n - 1)
  if vm.selected.val != i:
    vm.selected.val = i

proc moveSelection*(vm: LowLevelCodeVM; operation: string; page = 10): int =
  ## A `list.*` key on the listing: move its cursor and answer where it is
  ## (-1 when the listing is empty or the operation is not a move). With no
  ## cursor yet, a move starts from the execution pointer.
  let n = vm.instructions.val.len
  if n == 0:
    return NoSelectedInstruction
  var from0 = vm.selected.val
  if from0 < 0:
    from0 = max(0, vm.executionIndex)
    if operation in ["list.focus-next", "list.focus-previous"]:
      vm.selectInstruction(from0)
      return from0
  let target = case operation
    of "list.focus-next": from0 + 1
    of "list.focus-previous": from0 - 1
    of "list.focus-first": 0
    of "list.focus-last": n - 1
    of "list.focus-page-down": from0 + max(1, page)
    of "list.focus-page-up": from0 - max(1, page)
    else: return vm.selected.val
  vm.selectInstruction(clamp(target, 0, n - 1))
  vm.selected.val

proc activateSelected*(vm: LowLevelCodeVM): bool =
  ## Enter on the listing: go to the selected instruction's source line, as a
  ## press on its row does. Whether the debugger was asked to move.
  let rows = vm.instructions.val
  let i = vm.selected.val
  if i < 0 or i >= rows.len:
    return false
  vm.jumpToInstruction(rows[i])
  rows[i].hasSourceLine

proc rowMenu*(vm: LowLevelCodeVM; index: int): seq[LowLevelMenuEntry] =
  ## An instruction row's right-click menu, in its order, each entry disabled
  ## with its reason where it cannot act.
  let rows = vm.instructions.val
  if index < 0 or index >= rows.len:
    return
  let instr = rows[index]
  let source = vm.sourceLineOf(index)
  let hasLine = source.line > 0
  for action in LowLevelMenuAction:
    let enabled = case action
      of llmGoToSourceLine: instr.hasSourceLine
      of llmShowSourceLine, llmCopySourceLocation: hasLine
      of llmCopyInstruction: true
    result.add LowLevelMenuEntry(label: LowLevelMenuLabels[action],
      action: action, enabled: enabled,
      reason: (if enabled: "" else: NoSourceLineReason))

proc jumpTargetOf*(vm: LowLevelCodeVM; index: int): SourceLineRef =
  ## Where going to instruction `index` moves the debugger: its source line,
  ## the path VERBATIM as the engine wrote it (`jumpToInstruction` says why);
  ## `line` 0 when it has none.
  let rows = vm.instructions.val
  if index >= 0 and index < rows.len and rows[index].hasSourceLine:
    SourceLineRef(path: rows[index].highLevelPath,
                  line: rows[index].highLevelLine)
  else: SourceLineRef()

proc runRowMenu*(vm: LowLevelCodeVM; index: int;
                 action: LowLevelMenuAction;
                 send = true): LowLevelMenuOutcome =
  ## Do a row menu's entry for instruction `index`. With `send` false, Go to
  ## Source Line asks nothing of the engine and answers where to go
  ## (`jumpTo`), for a host that drives its engine itself.
  let rows = vm.instructions.val
  if index < 0 or index >= rows.len:
    return LowLevelMenuOutcome(note: "that instruction is no longer listed")
  let instr = rows[index]
  let source = vm.sourceLineOf(index)
  case action
  of llmGoToSourceLine:
    vm.selectInstruction(index)
    if not instr.hasSourceLine:
      vm.setErrorMessage(
        "no source line recorded for this instruction — nothing to jump to")
      result.note = NoSourceLineReason
    elif send:
      vm.jumpToInstruction(instr)
      result.moved = true
      result.note = "going to " & sourceCrossRef(instr)
    else:
      result.jumpTo = vm.jumpTargetOf(index)
      result.note = "going to " & sourceCrossRef(instr)
  of llmShowSourceLine:
    vm.selectInstruction(index)
    result.note = if source.line > 0:
                    "instruction " & formatOffset(instr, vm.noirProject.val) &
                      " came from " & source.path & ":" & $source.line
                  else: NoSourceLineReason
  of llmCopyInstruction:
    result.copied = instructionText(instr, vm.noirProject.val)
    result.note = "copied " & result.copied
  of llmCopySourceLocation:
    if source.line > 0:
      result.copied = source.path & ":" & $source.line
      result.note = "copied " & result.copied
    else:
      result.note = NoSourceLineReason

proc instructionStepRequest*(vm: LowLevelCodeVM;
                             operation: string): InstructionStepRequest =
  ## A step key pressed while the listing has the focus. When the engine
  ## steps by instruction, the DAP request that does it (the step's own
  ## command, `granularity: "instruction"`); otherwise not offered, with the
  ## words that say so — the host steps by line, as the desktop does.
  let command = case operation
    of "debugger.step-over": "next"
    of "debugger.step-into": "stepIn"
    of "debugger.reverse-step-over": "stepBack"
    of "debugger.reverse-step-into": "ct/reverseStepIn"
    else: ""
  if command.len == 0:
    return InstructionStepRequest(offered: false)
  if not vm.instructionStepOffered:
    return InstructionStepRequest(offered: false, command: command,
                                  note: InstructionSteppingRefusal)
  InstructionStepRequest(offered: true, command: command,
    args: %*{"threadId": 1, "granularity": "instruction"})

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
    let sourceCursor = createSignal(SourceLineRef())
    let selected = createSignal(NoSelectedInstruction)

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
      sourceCursor: sourceCursor,
      selected: selected,
      isEmpty: isEmpty,
      hasAnchors: hasAnchors,
      anchorsRejected: anchorsRejected,
      disposeProc: dispose,
    )
