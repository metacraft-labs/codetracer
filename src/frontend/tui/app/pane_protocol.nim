## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/pane_protocol.nim — the pane server's protocol as values
## (Editor-Hosted-Front-Ends §E2–§E7, HSF-E1).
##
## Owns: the protocol version, the wire names of panes, and the JSON shape of
## everything the server sends — a pane's rows with their semantic styles and
## hotspots, a layout, a keymap, the operation catalogue. Pure: no I/O, so the
## shape is assertable without a process, and `host/pane_server.nim` owns only
## the transport and the sessions.
##
## Refuses to own: framing and the message loop (`host/pane_server.nim`), and
## what a pane shows (the terminal's painters, `runtime.hostedPaneRows`).
##
## ## Offsets are UTF-8 bytes
##
## A span's and a hotspot's `start` / `end` are UTF-8 BYTE offsets into the
## row's `text` — what Neovim's extmark columns are, and what `initialize`
## declares as `positionEncoding: "utf-8"` (the LSP 3.17 spelling,
## https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#positionEncodingKind).
## The painters work in terminal CELLS; `cellToByte` converts once per row.

import std/[json, unicode]

import codetracer_embed
import headless_app/layout_model

import ./runtime
import ./views/styled_row
import ./theme/roles

const
  PaneProtocolVersion* = 1
    ## The protocol's version, sent in the `initialize` answer. A plugin
    ## refuses a server whose version it does not know (§ Protocol summary).
  PositionEncoding* = "utf-8"

  QuietSurfaces = {srNone, srSurfacePanel, srSurfaceEditor, srSurfaceCanvas}
    ## The pane's own ground: the editor window has one already, so a span is
    ## not given a surface for it.

func styleName*(role: SemanticRole): string =
  ## A semantic role as the style an editor maps to a highlight group or a
  ## face: `ct.` and the role's own spelling (`ct.value-modified`).
  "ct." & $role

proc paneOfWire*(name: string): (bool, PaneKind) =
  ## A pane's wire name — the layout document's own spelling (`calltrace`,
  ## `state`, `eventLog`, …) — as a pane.
  for p in PaneKind:
    if $p == name:
      return (true, p)
  (false, paneEditor)

proc cellToByte(row: StyledRow): seq[int] =
  ## For each cell of `row`, the UTF-8 byte offset of the text it shows; one
  ## more entry for the end of the row.
  var bytes = 0
  for span in row:
    for r in span.text.runes:
      let w = max(1, cellWidthOf($r))
      for _ in 0 ..< w:
        result.add bytes
      bytes += r.size
  result.add bytes

proc byteAt(map: seq[int]; cell: int): int =
  if map.len == 0: 0
  elif cell >= map.len: map[^1]
  else: map[max(0, cell)]

proc argsJson(a: PaneOpArgs; operation: string): JsonNode =
  ## Only the arguments `operation` names.
  result = newJObject()
  case operation
  of "calltrace.go-to-call", "calltrace.toggle-call":
    result["index"] = %a.index
  of "event-log.jump":
    result["index"] = %a.index
    result["tick"] = %a.tick
    result["path"] = %a.path
    result["line"] = %a.line
    result["text"] = %a.text
  of "variables.toggle-expand", "variables.value-history",
     "variables.value-origin", "variables.load-more":
    result["path"] = %a.path
  of "history.seek-to-tick":
    result["tick"] = %a.tick
  else: discard

proc paneArgsOf*(j: JsonNode): PaneOpArgs =
  ## A pane operation's arguments, read back from `operation/run`.
  if j.isNil or j.kind != JObject:
    return
  result.index = j{"index"}.getBiggestInt(0)
  result.tick = uint64(max(0'i64, j{"tick"}.getBiggestInt(0)))
  result.path = j{"path"}.getStr("")
  result.line = j{"line"}.getInt(0)
  result.text = j{"text"}.getStr("")

proc rowJson*(row: StyledRow; hotspots: seq[PaneHotspot] = @[]): JsonNode =
  ## One content row: its text, a span per run of one style, and the
  ## hotspots on it.
  let map = cellToByte(row)
  var text = ""
  var spans = newJArray()
  for span in row:
    let start = text.len
    text.add span.text
    if span.text.len == 0:
      continue
    let quiet = span.style.role == srNone and
                span.style.surface in QuietSurfaces and not span.style.bold
    if quiet:
      continue
    var s = %*{"start": start, "end": text.len,
               "style": styleName(span.style.role)}
    if span.style.surface notin QuietSurfaces:
      s["surface"] = %styleName(span.style.surface)
    if span.style.bold: s["bold"] = %true
    if span.style.italic: s["italic"] = %true
    if span.style.underline: s["underline"] = %true
    spans.add s
  result = %*{"text": text, "spans": spans}
  if hotspots.len > 0:
    var hs = newJArray()
    for h in hotspots:
      hs.add %*{"start": map.byteAt(h.startCol), "end": map.byteAt(h.endCol),
                "operation": h.operation,
                "args": argsJson(h.args, h.operation)}
    result["hotspots"] = hs

proc layoutJson*(node: LayoutNode): JsonNode =
  ## A mode's layout, logically: the persisted layout document's node shape
  ## (`layout_model.toJson`) — splits with their orientation and relative
  ## weights, leaves naming a pane.
  layout_model.toJson(node)

proc keymapJson*(entries: seq[ReferenceEntry];
                 shadowed: seq[string]): JsonNode =
  ## A pane's bindings (§E6), in resolution order, the first binding of a key
  ## winning. A key in `shadowed` is one the editor's own configuration binds
  ## for this pane: it is listed with `shadowedBy: "editor"` and the plugin
  ## leaves the editor's mapping in place.
  result = newJArray()
  var seen: seq[string] = @[]
  for e in entries:
    if e.keyText.len == 0 or e.keyText in seen:
      continue
    seen.add e.keyText
    var b = %*{"key": e.keyText, "operation": e.operation, "layer": e.layer}
    if e.keyText in shadowed:
      b["shadowedBy"] = %"editor"
    elif e.shadowedBy.len > 0:
      b["shadowedBy"] = %e.shadowedBy
    result.add b

proc operationsJson*(): JsonNode =
  ## The operation catalogue (§E6: the plugins generate their commands from
  ## it): every catalogued operation, then the panes' own.
  result = newJArray()
  for o in Catalogue:
    result.add %*{"name": o.name, "label": o.label, "argument": $o.arg}
  for (name, label) in PaneOperations:
    result.add %*{"name": name, "label": label, "argument": "pane-target",
                  "pane": true}
