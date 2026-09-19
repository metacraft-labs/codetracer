## Unit tests for the M0 collaborative ViewModel signal registry.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_collab_signal_registry.nim

import std/[os, sequtils, strutils, unittest]

import ../../collab/signal_registry
import ../../collab/runtime_role

## The fixture below is a *source root* rather than a mock: `discoverViewModelFields`
## reads real files off disk, so the only thing this needs from a temporary
## directory is files.  Nothing about the parser is stubbed — the same code path
## the gate runs against `src/frontend/viewmodel` runs against these bytes.
##
## Every declaration in it is a legal Nim spelling that SOME version of this
## scanner could not see, and a field the scanner misses is a field
## `validateRegistry` is never asked about — an unclassified collaborative
## signal the gate waves through.  The fixture deliberately holds both
## directions, because a rewrite is only an improvement if its OWN blind spots
## were looked for too:
##
##   * spellings the original literal matcher (`find("*:")` /
##     `contains("* =")`) missed — `*` with a space or a pragma before the
##     colon, two names on one line, `*=` with no spaces, a generic owner;
##   * spellings the FIRST DRAFT of the replacement token scan missed, which
##     the literal matcher had happened to catch — an object declared on the
##     `type` keyword's own line, and a stropped field name;
##   * and one that must keep working in BOTH (`typeNameProbeVM`), so the fix
##     for the keyword case cannot become an unconditional four-character chop.

const
  fixtureViewModel = """
## A ViewModel written in spellings the literal scanner missed.

type
  ProbeVM*= ref object of ViewModel
    ## `*=` with no surrounding spaces — a whole type, and with it every
    ## field below, used to be invisible.
    plain*: Signal[int]
    probeSpaced* : Signal[int]
    tagged* {.used.}: Signal[string]
    fromProbe*, toProbe*: Signal[bool]
    derived*: Memo[int]
    notExported: Signal[int]
    # commentedOut*: Signal[int]
    withTrailingComment*: Signal[int] # still a field

  GenericProbeVM*[T] = ref object
    generic*: Signal[T]
    ## A STROPPED field name.  Nim spells a field whose name collides with a
    ## keyword this way; the declared name is the text between the backticks.
    `type`*: Signal[int]

## The object on the SAME LINE as the section keyword — the spelling
## `viewmodels/edit_mode_toolbar.nim` and `viewmodels/verification_report.nim`
## both use for a one-off record.  If the keyword is read as the type's name,
## no owner is recognised and every field here disappears silently.
type OneLineProbeVM* = object
  oneLine*: Signal[int]

## `typeName` is an identifier that merely STARTS with the keyword; consuming
## four characters unconditionally would rename this type to `Name`.
type
  typeNameProbeVM* = object
    keywordPrefixed*: Signal[int]

proc afterTheTypeSection*: Signal[int] =
  ## Nothing here may be attributed to `GenericProbeVM`: the body is no longer
  ## indented under it.
  discard

const notAField* = 1
"""

  fixtureSessionVm = """
type
  ProbeSessionVM* = ref object
    sessionField*: Signal[int]
"""

  fixtureStore = """
type
  ProbeStore* = object
    storeField*: Signal[int]
"""

proc writeFixtureSourceRoot(root: string) =
  createDir(root / "store")
  createDir(root / "viewmodels")
  writeFile(root / "session_vm.nim", fixtureSessionVm)
  writeFile(root / "store" / "replay_data_store.nim", fixtureStore)
  writeFile(root / "viewmodels" / "probe_vm.nim", fixtureViewModel)

suite "collaborative signal registry":

  test "test_collab_signal_registry_covers_session_vm":
    let inventory = discoverViewModelFields()
    let registry = collabSignalRegistry()
    let validation = validateRegistry(inventory, registry)

    check inventory.anyIt(it.fieldPath == "ReplayDataStore.session")
    check inventory.anyIt(it.fieldPath == "CalltraceStore.lines")
    check inventory.anyIt(it.fieldPath == "CalltraceVM.selectedEntry")
    check inventory.anyIt(it.fieldPath == "StateVM.watchExpressions")
    check inventory.anyIt(it.fieldPath == "EditorVM.activeTabIndex")

    check registry.anyIt(it.fieldPath == "CalltraceVM.selectedEntry" and
      it.syncClass == vscSharedSessionViewState and it.requiresStableId)
    check registry.anyIt(it.fieldPath == "ReplayDataStore.debugger" and
      it.syncClass == vscBackendAuthoritative)
    check registry.anyIt(it.fieldPath == "CalltraceVM.viewportHeight" and
      it.syncClass == vscRendererLocal)
    check registry.anyIt(it.fieldPath == "FlowVM.hoveredStep" and
      it.syncClass == vscPresenceAwareness)
    check registry.anyIt(it.fieldPath == "CalltraceVM.visibleLines" and
      it.syncClass == vscDerivedNonSignal)

    if not validation.isValid:
      checkpoint validation.formatValidation
    check validation.isValid()

    let stableIdBlocked = stableIdBlockedFields(registry)
    check stableIdBlocked.anyIt(it.fieldPath == "CalltraceVM.selectedEntry")
    check stableIdBlocked.anyIt(it.fieldPath == "EventLogVM.selectedRow")
    check stableIdBlocked.anyIt(it.fieldPath == "EditorVM.activeTabIndex")

    check ownsBackend(vrrStandalone)
    check ownsBackend(vrrBackendOwner)
    check not ownsBackend(vrrCollaborator)

  test "test_collab_signal_registry_rejects_unclassified_signal":
    var inventory = discoverViewModelFields()
    inventory.add ViewModelField(
      owner: "InjectedVM",
      field: "newMutableSignal",
      kind: vfkSignal,
      typeExpr: "Signal[int]",
      sourceFile: "test-only",
      line: 1,
    )

    let validation = validateRegistry(inventory, collabSignalRegistry())
    check not validation.isValid()
    check validation.missing.anyIt(it.fieldPath == "InjectedVM.newMutableSignal")

  test "test_collab_renderer_local_fields_are_not_published":
    let registry = collabSignalRegistry()
    let rendererLocal = registry.filterIt(it.syncClass == vscRendererLocal)
    check rendererLocal.len > 0
    check rendererLocal.anyIt(it.fieldPath == "CalltraceVM.viewportHeight")
    check rendererLocal.anyIt(it.fieldPath == "EditorVM.scrollTop")
    check rendererLocal.allIt(not it.canPublishAsViewStateOperation)

    let shared = registry.filterIt(it.syncClass == vscSharedSessionViewState)
    check shared.len > 0
    check shared.allIt(it.canPublishAsViewStateOperation)

  test "test_collab_signal_registry_discovers_unusual_field_spellings":
    ## The gate is only fail-closed for the spellings its scanner can READ.
    ## Each declaration asserted here is legal Nim that the previous
    ## literal-matching scanner skipped, i.e. a collaborative signal that could
    ## be added with undefined replication behaviour and a green lane.
    let root = getTempDir() / "ct-signal-registry-spellings"
    removeDir(root)
    writeFixtureSourceRoot(root)
    defer: removeDir(root)

    let inventory = discoverViewModelFields(root)
    let paths = inventory.mapIt(it.fieldPath)

    # The baseline spelling, so a fixture that discovers NOTHING (a broken
    # source root, a scanner that returns early) cannot be mistaken for a pass
    # on the interesting cases below.
    check "ProbeVM.plain" in paths
    check "ProbeSessionVM.sessionField" in paths
    check "ProbeStore.storeField" in paths

    # `probeSpaced* : Signal[int]` — one space before the colon.
    check "ProbeVM.probeSpaced" in paths
    # `tagged* {.used.}: Signal[string]` — a pragma between `*` and `:`.
    check "ProbeVM.tagged" in paths
    # `fromProbe*, toProbe*: Signal[bool]` — one line, two fields.  The old
    # scanner produced the single bogus name `fromProbe*, toProbe`.
    check "ProbeVM.fromProbe" in paths
    check "ProbeVM.toProbe" in paths
    # `ProbeVM*= ref object` and `GenericProbeVM*[T] = ref object` — owners the
    # old `contains("* =")` test could not name, which hid every field in them.
    check "GenericProbeVM.generic" in paths
    # A `#` comment after the declaration must not become part of the type.
    check "ProbeVM.withTrailingComment" in paths
    # `` `type`*: Signal[int] `` — a stropped field name, reported unstropped
    # because that is the name a registry row would have to spell.
    check "GenericProbeVM.type" in paths
    # `type OneLineProbeVM* = object` — the object on the section keyword's own
    # line.  Reading `type` as the type's name hides every field in it, and the
    # real tree spells two records exactly this way.
    check "OneLineProbeVM.oneLine" in paths
    # ...but only the KEYWORD is consumed: `typeNameProbeVM` keeps its name.
    check "typeNameProbeVM.keywordPrefixed" in paths
    check not paths.anyIt(it.startsWith("NameProbeVM."))

    check inventory.anyIt(it.fieldPath == "ProbeVM.derived" and
      it.kind == vfkMemo)
    check inventory.anyIt(it.fieldPath == "ProbeVM.probeSpaced" and
      it.kind == vfkSignal and it.typeExpr == "Signal[int]")

    # Tolerance must not become credulity: these are NOT fields.
    check "ProbeVM.notExported" notin paths      # no export marker
    check "ProbeVM.commentedOut" notin paths     # inside a `#` comment
    # Nothing below the type section may inherit the last owner seen.
    check not paths.anyIt(it.endsWith(".afterTheTypeSection"))
    check not paths.anyIt(it.endsWith(".notAField"))
