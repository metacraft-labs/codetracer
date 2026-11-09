## window_pointer.nim — the GPUI window's half of the pointer's shape
## (Pointer-Affordances.md §4): what kind of element each drawn element is, as
## a `HitTarget`, and its `cursor` style from the one shared function.
##
## The elements already say what they are: `window_clicks` stamps the rows it
## wires, and the renderers stamp every control, field and scrollbar with a
## `data-ct-*` attribute. A walk after each redraw reads those (hit-testing
## stays this front-end's own, Input-Routing §5.3) and writes the answer.

import isonim_gpui/renderer

import ../../common/pointer_shape
import ./window_clicks

export pointer_shape

const
  PointerStampAttribute* = "data-ct-pointer-kind"
    ## The `HitKind` a walk read off an element, for the render plan's reader.

  AttributeKinds: array[63, (string, HitKind)] = [
    ("data-ct-control", hkControl), ("data-ct-tool", hkControl),
    ("data-ct-menu-button", hkControl), ("data-ct-menu-item", hkControl),
    ("data-ct-session-tab-close", hkControl),
    ("data-ct-session-tab-add", hkControl), ("data-ct-window-button", hkControl),
    ("data-ct-context-entry", hkControl), ("data-ct-footer-copy-path", hkControl),
    ("data-ct-footer-build", hkControl), ("data-ct-find-toggle", hkControl),
    ("data-ct-build-control", hkControl), ("data-ct-test-control", hkControl),
    ("data-ct-problems-button", hkControl), ("data-ct-agent-button", hkControl),
    ("data-ct-agent-control", hkControl), ("data-ct-agent-add", hkControl),
    ("data-ct-verification-control", hkControl),
    ("data-ct-search-option", hkControl), ("data-ct-unpin", hkControl),
    ("data-ct-low-level-sync", hkControl), ("data-ct-dock-slot", hkControl),
    ("data-ct-session-tab", hkTab), ("data-ct-tab", hkTab),
    ("data-ct-omnibar-result", hkRow), ("data-ct-welcome-row", hkRow),
    ("data-ct-search-row", hkRow), ("data-ct-problem-index", hkRow),
    ("data-ct-test-row", hkRow), ("data-ct-low-level-index", hkRow),
    ("data-ct-verification-key", hkRow), ("data-ct-request-id", hkRow),
    ("data-ct-build-history-item", hkRow), ("data-ct-build-location", hkRow),
    ("data-ct-agent-key", hkRow), ("data-ct-constraint-row", hkRow),
    ("data-ct-shell-action", hkControl), ("data-ct-shell-lines", hkTextInput),
    ("data-call-toggle", hkExpander),
    ("data-ct-fold", hkExpander), ("data-ct-cut", hkCell),
    ("data-ct-omnibar", hkTextInput), ("data-ct-find-field", hkTextInput),
    ("data-ct-files-field", hkTextInput), ("data-ct-search-field", hkTextInput),
    ("data-ct-agent-prompt", hkTextInput), ("data-ct-requests-search", hkTextInput),
    ("data-ct-welcome-input", hkTextInput),
    ("data-ct-column-separator", hkColumnSeparator),
    ("data-ct-divider-vertical", hkDividerVertical),
    ("data-ct-divider-horizontal", hkDividerHorizontal),
    ("data-ct-window-drag", hkDragHandle), ("data-ct-state-scrollbar", hkScrubber),
    ("data-ct-state-scroll-track", hkScrubber), ("data-ct-hbar", hkScrubber),
    ("data-ct-hscroll", hkScrubber), ("data-ct-hscroll-thumb", hkScrubber),
    ("data-ct-editor-scrollbar", hkScrubber),
    ("data-ct-editor-vscrollbar", hkScrubber), ("data-ct-list-scrubber", hkScrubber),
    ("data-ct-terminal-track", hkScrubber), ("data-ct-build-hbar", hkScrubber),
    ("data-ct-terminal-thumb", hkScrubber)]
    ## What each attribute says the element is. First match wins, so an
    ## element's specific attribute comes before a general one.

  DisabledMarks = [("data-ct-enabled", "false"),
                   ("data-ct-context-enabled", "false"),
                   ("data-ct-welcome-enabled", "false"),
                   ("data-ct-disabled", "true")]

func kindOfPart(part: string): HitKind =
  ## The rows `window_clicks` wired (`GClickPart`'s names).
  case part
  of $gcpFileNode, $gcpEventRow, $gcpVariable, $gcpCallRow, $gcpPoint,
     $gcpCallArg, $gcpVcsFile, $gcpVcsCommit, $gcpHistoryEntry, $gcpOriginHop:
    hkRow
  of $gcpGutter: hkGutterGlyph
  of $gcpCode: hkEditorText
  of $gcpTab: hkTab
  of $gcpEventHeader, $gcpScratchClose, $gcpValue, $gcpPosition,
     $gcpStateControl, $gcpAddWatch:
    hkControl
  of $gcpCallSearch: hkTextInput
  else: hkNone

func hitTargetOf*(n: SnapshotNode): HitTarget =
  ## The element's kind and state, read off what the renderers stamped — its
  ## attributes, as `snapshotTree` read them.
  if n.attributes.len == 0:
    return HitTarget(kind: hkNone)
  let part = n.attr(WiredAttribute)
  var kind = if part.len > 0: kindOfPart(part) else: hkNone
  if kind == hkNone or kind == hkRow:
    for (attribute, attributeKind) in AttributeKinds:
      if n.attr(attribute).len > 0:
        kind = attributeKind
        break
  result = HitTarget(kind: kind)
  if kind == hkCell:
    result.truncated = true
  for (attribute, value) in DisabledMarks:
    if n.attr(attribute) == value:
      result.disabled = true

proc stampPointerShapes*(r: GpuiRenderer; nodes: openArray[SnapshotNode]) =
  ## Every interactive element's `cursor`, from `pointerShapeOf` (§4). An
  ## element the walk reads as nothing keeps no style: it inherits the arrow.
  ##
  ## `nodes` is the window's tree as `snapshotTree` read it, after
  ## `window_clicks.wireWindowClicks` recorded the rows it wired: this runs
  ## after every redraw, over every element of the window, and asking the
  ## shim for each of the names above one call at a time cost about 40 ms a
  ## redraw. Only the elements styled here take a handle.
  for n in nodes:
    let target = hitTargetOf(n)
    if target.kind != hkNone:
      let el = elementOf(n.id)
      if el.isNil:
        continue
      let kindName = $target.kind
      if n.attr(PointerStampAttribute) != kindName:
        r.setAttribute(el, PointerStampAttribute, kindName)
      r.setStyle(el, "cursor", pointerShapeOf(target).cssName)
