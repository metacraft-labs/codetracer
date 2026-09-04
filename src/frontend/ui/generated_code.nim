## Show Generated Code — the operation's production half.
##
## `GUI/Debugging-Features/Generated-Code-Listing.md` §1, §7, §8, §10
## (GCL-D19's fourth bullet: "an on-demand open path MUST exist — removing the
## pane from the default layout without adding the open path would remove the
## feature").
##
## ## WHAT THIS MODULE IS FOR, STATED AS THE DEFECT IT CLOSES
##
## `generated_code_anchors` (the model), `noir_anchor_producer` (the Noir
## producer, green against a committed `nargo compile` artefact) and
## `low_level_code_vm`'s `setAnchors` / `syncFromSource` / `syncFromGenerated`
## were all correct, all tested, and REACHED ONLY FROM THEIR OWN SUITES.
## `ci/test/frontend-reachability-guard.py` reported every one of them, in a
## backlog of twelve hundred where nobody would read it.
##
## That is the campaign's canonical defect shape, and its user-visible face is
## always the same one: a feature that looks present and does nothing. This
## module is the caller, and `ci/test/generated-code-operation-guard.py` is the
## enforcing check that this file — or one like it — keeps existing.
##
## ## THE ON-DEMAND BOUNDARY IS IN THIS FILE, AND IT IS A SPECIFIC LINE
##
## `noteCompileArtefact` is told about every successful compile and does the
## cheapest possible thing: it PUTS THE TEXT IN A VARIABLE. It does not parse
## the artefact, does not resolve call stacks, does not build anchors and does
## not touch the VM.
##
## `showGeneratedCode` — reached only from a user's gesture — is what runs
## `readArtefactJson`, `produceAnchors` and `reportFromAcirListing`. So the
## expensive work happens once per invocation and never once per compile, and
## `GeneratedCodeVM.noteCursorMoved` re-anchors without re-running any of it.
##
## This is the difference between "we only compute it when needed" (a habit,
## which nothing checks) and a boundary a reader can point at.
##
## ## WHY THE HOOKS ARE NAMED PROCS AND NOT CLOSURES AT THE INSTALL SITE
##
## `ui/constraints.noteEditorSourceChanged` records the reason and it applies
## unchanged: an anonymous `proc` inside a 400-line install block in `ui_js` is
## how the previous version of that wiring managed to not exist for as long as
## it did. A named proc is a thing a reader — and a name-based reachability
## guard — can see.

import
  ui_imports,
  ../[ types ]

from ../../common/noir_constraints import
  ConstraintReport, reportFromAcirListing

from ../viewmodel/viewmodels/generated_code_operation import
  GeneratedCodeTarget, TargetCommand, commandsForPath, targetById

from ../viewmodel/viewmodels/edit_mode_toolbar import
  CommandProposal, ProposalConfidence, pcCanonical

from ../viewmodel/viewmodels/generated_code_anchors import
  MappingAnchor, ArtefactSupport, rebaseSources

from ../viewmodel/viewmodels/noir_build_producer import rendererPathFor

from ../viewmodel/store/types as vmtypes import LowLevelInstruction
from low_level_code import showGeneratedListing

const NO_HIGH_LEVEL_LINE = -1
  ## `LowLevelInstruction.highLevelLine` is the LEGACY per-row back-pointer the
  ## asm loader fills, and `isonim_low_level_code_view.sourceCrossRef` suppresses
  ## the row's source span when it is not positive. It is left unset on purpose:
  ## this listing's source correspondence is the ANCHOR SET, which is a range of
  ## rows per source region, and writing a single line onto each row would be a
  ## second, coarser mapping beside the real one — disagreeing with it wherever
  ## an anchor covers more than one row, which is most of them.

from ../viewmodel/viewmodels/noir_anchor_producer import
  readArtefactJson, produceAnchors, aroOk

from ../viewmodel/viewmodels/generated_code_vm import
  GeneratedCodeVM, GeneratedListing, GeneratedRow, createGeneratedCodeVM,
  openListing, noteBuildStarted, noteBuildFailed,
  noteCursorMoved, noteActiveTabChanged, noteSourceEdited

var generatedCodeVMInstance*: GeneratedCodeVM

type
  CompileArtefact = object
    ## The LAST successful compile's raw outputs, held as text. Nothing here
    ## has been parsed, and that is the point — see the module header.
    listing: string
      ## `VfsResponse.acir_listing`, the compiler's own printed opcodes.
    artefactJson: string
      ## The compile artefact, carrying `file_map` and `debug_symbols`.
    projectRoot: string
      ## The RENDERER's spelling of the project root — `/hello_noir`. Kept
      ## beside `packageDir`, which is the COMPILER's — `hello_noir`. The pair
      ## is what `rendererPathFor` needs, and without it every anchor would
      ## carry a path no editor tab is keyed by.
    packageDir: string
    provenance: string
    present: bool

var lastArtefact: CompileArtefact

proc initGeneratedCodeVM*() =
  ## Created lazily and kept. Like `initConstraintsVM`, it needs no store: a
  ## generated-code listing comes from a compile artefact and from nowhere
  ## else, so a `ReplayDataStore` parameter would be a promise this operation
  ## does not keep.
  if generatedCodeVMInstance != nil:
    return
  generatedCodeVMInstance = createGeneratedCodeVM()
  clog "GeneratedCodeVM: instance created"

proc noteCompileArtefact*(listing: string; artefactJson: string;
                          projectRoot: string; packageDir: string;
                          provenance: string) =
  ## A COMPILE SUCCEEDED. Installed into
  ## `web_noir_build.noirGeneratedCodeSink` by `ui_js`.
  ##
  ## THE CHEAP HALF, DELIBERATELY. Two string assignments and a flag. It does
  ## not parse, does not anchor, and does not open anything: §1 is that the
  ## operation is "invoked, never permanently displayed", and a sink that built
  ## a listing on every compile would have made the surface permanent in
  ## everything but its visibility.
  ##
  ## It also does not disturb a listing already on screen. GCL-D22 is about a
  ## late reply from ANOTHER producer overwriting a live build; the same
  ## reasoning applies to a compile the user did not ask a listing for, and the
  ## remedy is the same — the surface keeps what it is showing, and the new
  ## artefact is what the NEXT invocation reads.
  lastArtefact = CompileArtefact(
    listing: listing, artefactJson: artefactJson, projectRoot: projectRoot,
    packageDir: packageDir, provenance: provenance, present: true)

proc rowsOf(report: ConstraintReport): seq[GeneratedRow] =
  ## Flatten the report's per-function rows into the listing's row space.
  ##
  ## GCL-D6 IS WHY THE INDEX IS RE-DERIVED HERE. `ConstraintOpcode.index` is
  ## the opcode's position IN ITS FUNCTION, and `acir_locations` is keyed by
  ## the opcode index of the circuit. For a single-function circuit the two
  ## agree; for a listing that also carries Brillig blocks they do not, and
  ## using the per-function index would offset every anchor by the length of
  ## everything printed before it — "a mapping wrong by a constant, which is
  ## the most plausible-looking failure available and would survive casual
  ## inspection".
  ##
  ## So the row index is the position in THIS seq, and `row index ≡ opcode
  ## index` is restored as an invariant of the flattened listing.
  var i = 0
  for fn in report.functions:
    for op in fn.rows:
      var text = op.name
      if op.args.len > 0:
        text.add " " & op.args
      result.add GeneratedRow(index: i, text: text, annotation: "")
      inc i

proc buildListing(t: GeneratedCodeTarget; sourcePath: string):
    (GeneratedListing, string) =
  ## THE EXPENSIVE HALF, reached only from `showGeneratedCode`. Returns the
  ## listing and, when it could not be built, the reason — never a silently
  ## empty listing, which §8's state table forbids collapsing with the others.
  if not lastArtefact.present:
    return (GeneratedListing(), "no artefact has been produced yet — build " &
      "this project to see what it compiles to")

  let report = reportFromAcirListing(lastArtefact.listing,
    lastArtefact.packageDir, lastArtefact.provenance)
  let rows = rowsOf(report)

  var anchors: seq[MappingAnchor] = @[]
  var support = ArtefactSupport()
  var absence = ""

  if rows.len == 0:
    # §8's fourth state: the build SUCCEEDED and the producer has totals but
    # no rows. This is not an empty listing and must not render as one — it is
    # every build on the current deploy pin, whose compiler module predates
    # `VfsResponse.acir_listing`.
    absence = "this build's Noir compiler does not print a constraint " &
      "listing, so the generated code cannot be shown for what it compiled"
  else:
    let read = readArtefactJson(lastArtefact.artefactJson, rows.len)
    if read.outcome == aroOk:
      (anchors, support) = produceAnchors(read.artefact)
      # THE ANCHORS ARRIVE IN THE COMPILER'S SPELLING AND THE CURSOR IS IN THE
      # EDITOR'S. `file_map` says `hello_noir/src/main.nr` because that is the
      # key the compiler was handed; `sourcePath` here is the name the tab was
      # opened by, `/hello_noir/src/main.nr`. `syncFromSource` compares those
      # two strings.
      #
      # Without this line the listing opens, its rows are real, and every
      # single line of the file reports that no generated code is mapped to it
      # — indistinguishable from a build stripped of debug information, and
      # undetectable by the model, because a path that matches nothing is not
      # a malformed path. `rendererPathFor` is the SAME rule the build pane's
      # clickable diagnostics use, called rather than restated.
      let root = lastArtefact.projectRoot
      let pkg = lastArtefact.packageDir
      anchors = rebaseSources(anchors, proc(p: string): string =
        rendererPathFor(root, pkg, p))
    else:
      # Rows without anchors is a legitimate state, not a failure: every row
      # is unmapped and synchronisation suspends visibly, which is exactly what
      # GCL-D5 specifies for the SSA target and what an artefact stripped of
      # debug information gives for any of them. The listing is still worth
      # reading; it just does not map.
      anchors = @[]

  (GeneratedListing(
    targetId: t.id,
    sourcePath: sourcePath,
    producer: t.producer,
    rows: rows,
    anchors: anchors,
    support: support,
    listingAbsence: absence), "")

proc generatedCodeCommandsAt*(path: cstring): seq[TargetCommand] =
  ## What the editor's context menu offers over `path`. GCL-D17's table lives
  ## in `commandsForPath`; this supplies its inputs.
  ##
  ## The proposal is read as canonical here because the Noir web toolchain is
  ## the only producer wired, and its build command is not in doubt. When a
  ## second language's producer lands, this is the call site that must start
  ## reading `edit_mode_toolbar.buildProposal(projectKinds(...))` — and the
  ## disabled-with-a-reason arm is already written and asserted
  ## (`gcl_a19_a_non_canonical_proposal_disables_with_its_own_reason`), so the
  ## change is an input change rather than a new branch.
  commandsForPath($path, CommandProposal(command: "nargo",
    args: @["compile"], confidence: pcCanonical, reason: ""))

proc showGeneratedCode*(data: Data; path: cstring; line: int;
                        targetId: string) =
  ## THE OPERATION. A developer put the cursor in a source file and asked what
  ## this code became.
  ##
  ## `line` is passed IN rather than read from an ambient "current line", which
  ## is GCL-D16 as a signature: the projection is a pure function of the
  ## landing position, so this call site cannot make a deferred open differ
  ## from a live one.
  var t: GeneratedCodeTarget
  if not targetById(targetId, t):
    return

  initGeneratedCodeVM()
  if generatedCodeVMInstance.isNil:
    return

  generatedCodeVMInstance.noteBuildStarted(t, $path, line)

  let (listing, failure) = buildListing(t, $path)
  if failure.len > 0:
    generatedCodeVMInstance.noteBuildFailed(failure)
    # THE SURFACE STILL OPENS, carrying the reason. §8: a build that fails must
    # show WHY rather than resolving into an empty listing, and a command that
    # silently does nothing is the same defect as a listing nobody paints.
    data.openLowLevelCode()
    discard showGeneratedListing(@[], @[], ArtefactSupport(), $path, line,
      failure)
    return
  generatedCodeVMInstance.openListing(listing, line)

  # AND SOMETHING PAINTS IT. `Generated-Code-Listing.md` §7 asks for an editor
  # TAB; this opens the Low Level Code PANE, and the divergence is deliberate
  # and recorded rather than glossed.
  #
  # `openTab(name, ViewInstructions)` is what §0 observes `openAlternativeView`
  # already doing, and it is the wrong instrument here: that view is fed by
  # `CtLoadAsmFunction` against a recording's asm and knows nothing about a
  # compile artefact, so the tab would have opened EMPTY. A surface a user
  # invokes and finds blank is precisely the defect this thread exists to
  # close, and matching the spec's noun while reintroducing it would have been
  # the worse divergence.
  #
  # The pane already renders what the spec asks the surface to render: a
  # fidelity badge per row (GCL-A7), the three not-aligned states told apart
  # (GCL-A8) and the sync toggle's visible state — all asserted against the
  # view in `test_low_level_code_view_anchors.nim`. The tab is the right long
  # answer and it needs a view of its own; this is the surface that exists.
  data.openLowLevelCode()
  var rows: seq[LowLevelInstruction] = @[]
  for r in listing.rows:
    rows.add LowLevelInstruction(
      name: r.text, args: "", other: r.annotation, offset: r.index,
      highLevelPath: "", highLevelLine: NO_HIGH_LEVEL_LINE)
  discard showGeneratedListing(rows, listing.anchors, listing.support,
    $path, line, listing.listingAbsence)

# `showFirstGeneratedCodeTarget` WAS HERE AND IS DELETED, with
# `generated_code_operation.keybindingTarget` behind it.
#
# GCL-D11 specifies a keybinding bound to "the first target of the current
# file's language", so the familiar one-key gesture survives without any
# binding having to mean different things in different files. NO KEY IS BOUND,
# and an entry point for a gesture nobody can make is the defect this feature
# was written to close, not a head start on closing it. The context menu is the
# open path that exists; the keybinding is spec that is not built, and saying
# so here is what stops the next reader from assuming otherwise.

proc noteEditorCursorMoved*(path: cstring; line: int) =
  ## THE CURSOR LEADS. Installed into `ui/editor.editorCursorMovedHook`.
  ##
  ## Silent when no listing is open, and that silence is structural rather
  ## than polite: `GeneratedCodeVM.noteCursorMoved` refuses a move on a closed
  ## VM, refuses one from a tab that is not the active one, and refuses one
  ## that does not change the line. Monaco fires this for column moves and for
  ## background models, and all three refusals are asserted.
  if generatedCodeVMInstance.isNil:
    return
  discard generatedCodeVMInstance.noteCursorMoved($path, line)

proc noteEditorTabActivated*(path: cstring; line: int) =
  ## THE LISTING FOLLOWS THE ACTIVE TAB. Installed into
  ## `ui/editor.editorActiveTabChangedHook`.
  ##
  ## The cursor arrives WITH the tab: each tab has its own, and a listing that
  ## switched files and then waited for a cursor event would spend the interval
  ## showing the previous tab's line under the new tab's name.
  if generatedCodeVMInstance.isNil:
    return
  discard generatedCodeVMInstance.noteActiveTabChanged($path, line)

proc noteEditorSourceEdited*(path: cstring) =
  ## GCL-D18. Marks the tab stale, suspends the correspondence, and KEEPS the
  ## rows. Installed beside `constraints.noteEditorSourceChanged`, from the
  ## same editor hook, because it is the same fact about the same edit.
  if generatedCodeVMInstance.isNil:
    return
  generatedCodeVMInstance.noteSourceEdited($path)

# `closeGeneratedCode` and `setGeneratedCodeSync` WERE HERE AND ARE DELETED,
# for the same reason. §7 says closing the tab is how the operation is undone
# and GCL-D15 specifies a synchronisation toggle with a visible state; neither
# has a control on any surface yet. `generated_code_vm.closeListing` and
# `.setSyncEnabled` implement the behaviour and are asserted; these two were
# wrappers waiting for a button.
