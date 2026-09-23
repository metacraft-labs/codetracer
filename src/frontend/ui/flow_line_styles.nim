## Pure per-line CSS classes for the Omniscience flow overlay.
##
## THE RULE ITSELF LIVES IN `common/flow_line_rule.nim` since 2026-09-23 —
## `flowStyledLines`, `hasBranchStateAt`, `insideUntakenBranch` and the
## `FlowLineStyleKind` they answer in — and is re-exported here, so every
## existing importer of this module keeps its names. What stays here is the
## part that IS rendering: the CSS class each kind is painted with. The split
## is what lets the ViewModel layer call the same rule without the Embed SDK
## facade reaching the desktop UI tree (`ci/test/sdk-facade-boundary.sh`).

import ../../common/flow_line_rule
export flow_line_rule

const
  FlowLineHitClass* = "line-flow-hit"
  FlowLineSkipClass* = "line-flow-skip"
  FlowLineUnknownClass* = "line-flow-unknown"

func flowLineStyleClass*(kind: FlowLineStyleKind): string =
  ## The CSS class `styles/components/flow.styl` styles this kind with.
  case kind
  of flskHit: FlowLineHitClass
  of flskSkip: FlowLineSkipClass
  of flskUnknown: FlowLineUnknownClass
