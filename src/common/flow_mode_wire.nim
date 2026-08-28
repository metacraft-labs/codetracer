## flow_mode_wire.nim
##
## The `ct/load-flow` `flowMode` vocabulary — the single Nim-side source of
## truth for what goes on the wire.
##
## ## Why this module exists
##
## `ct/load-flow` had two `FlowMode` enums that did not agree and no way to
## notice:
##
##   * `src/db-backend/src/task.rs` — `Call | Diff`, a *query* mode, and until
##     recently serialised as a bare `u8` (`serde_repr`);
##   * `src/frontend/viewmodel/viewmodels/flow_vm.nim` — `fmCall | fmLine |
##     fmFunction`, a *view granularity*, serialised as `$mode` (`"fmCall"`).
##
## The immediate symptom was a hard rejection (`invalid type: string
## "fmCall", expected u8`) plus a missing required `location`. The deeper
## defect is the one that would have survived "fixing" the symptom: an
## ordinal crossing a boundary where the two sides define different orderings
## does not fail, it silently means something else. `fmLine` as `1` is
## `Diff`, a different query with a plausible-looking answer.
##
## So the wire form is a **name**. A name either matches a known spelling or
## is rejected by name; it cannot be quietly reinterpreted when either enum
## gains a member.
##
## ## The cross-language pin
##
## `FLOW_MODE_WIRE_NAMES` in `src/db-backend/src/task.rs` is the Rust half.
## `src/db-backend/tests/flow_mode_wire_test.rs` **reads this file** and fails
## if the two lists differ, so the vocabularies cannot drift apart without a
## test failing — which is the property that was missing, not the strings.
##
## This module deliberately has no imports: it is included in the
## `common_types` graph, imported directly by the IsoNim ViewModel layer, and
## read as text by a Rust test. Anything it depended on would have to be
## available to all three.

const
  FlowModeWireCall* = "call"
    ## Engine `FlowMode::Call` — the ordinary "flow through this call" query.
    ## Every `flow_vm.FlowMode` view granularity maps here; they differ in
    ## how the panel lays the returned steps out, not in what it asks for.
  FlowModeWireDiff* = "diff"
    ## Engine `FlowMode::Diff` — the raw-diff-index query, reached from the
    ## legacy Karax editor.

  FlowModeWireNames* = [FlowModeWireCall, FlowModeWireDiff]
    ## In engine-enum declaration order, so `FlowModeWireNames[ord(mode)]`
    ## is the spelling for `mode`. The order is load-bearing only for the
    ## legacy ordinal form the engine still accepts on the way in.

proc flowModeWireName*(ordinal: int): string =
  ## Spelling for an engine-`FlowMode` ordinal. Raises rather than returning
  ## a default: a wrong-but-plausible flow mode is exactly the failure this
  ## module exists to prevent.
  if ordinal < FlowModeWireNames.low or ordinal > FlowModeWireNames.high:
    raise newException(ValueError,
      "flowMode ordinal " & $ordinal & " has no wire name")
  FlowModeWireNames[ordinal]

proc flowModeWireOrdinal*(name: string): int =
  ## Engine-`FlowMode` ordinal for a wire spelling, or `-1` when unknown.
  ## Callers that cannot handle `-1` should raise, not substitute.
  for i, wire in FlowModeWireNames.pairs:
    if wire == name:
      return i
  -1
