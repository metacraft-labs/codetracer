## gpui/app/capability.nim — PLAT-45 deliverable 2, the GPUI window's row.
##
## Which `PaneKind` values this front-end can DRAW. Derived from
## `view_vocabulary/pane_views`' own three sets rather than listed beside them:
## a pane is drawable here exactly when it is expressed in the vocabulary or is
## a declared native view, and every ACCEPTED EXCEPTION is a pane the window
## places and draws as a report — so the capability and the dispatch in
## `pane_views.paneView` cannot disagree, because they are the same sets.
##
## A pane of the shared default this front-end cannot draw is still placed
## (`leaves.renderLeaves` draws `pane_views`' report text in its slot), which is
## what makes "every product opens with the same panes" literally true.

import headless_app/layout_model
import ../../view_vocabulary/pane_views

proc gpuiCapability*(): PaneCapability =
  var reasons: seq[(PaneKind, string)] = @[]
  for p in PaneAcceptedExceptions:
    reasons.add (p,
      if p == paneBuildOutput:
        "an edit-mode pane; a replay session does not build the working tree"
      else:
        "drawn by the desktop front-end; this window has no view for it yet")
  paneCapability(feGpui, PaneVocabularyPanes + PaneNativePanes, reasons)
