## test_pane_protocol.nim — HSF-E1, the pane server's protocol as values.
##
## `app/pane_protocol` is pure, so its shape is asserted here without a
## process or a recording: the command line that starts the server, the
## semantic style names, the pane wire names, and the row encoding — above
## all that a span's and a hotspot's offsets are UTF-8 BYTES into the row's
## text (the `positionEncoding` the server declares) when the painters measure
## in terminal CELLS, which differ as soon as a row carries a wide or a
## multi-byte glyph. The protocol against a real recording is
## `tests/test_pane_server.nim`.

import std/[json, strutils, unittest]

import codetracer_embed
import headless_app/layout_model

import ../cli
import ../pane_protocol
import ../runtime
import ../theme/roles
import ../theme/cell_style
import ../views/styled_row

suite "HSF-E1: the pane protocol's values":

  test "--pane-server is the whole command line":
    check parseTuiCommand(["--pane-server"]).kind == tckPaneServer
    let refused = parseTuiCommand(["--pane-server", "/some/trace"])
    check refused.kind == tckUsageError
    check refused.kind == tckUsageError and "--pane-server" in refused.message

  test "styles are semantic, panes are the layout's spelling":
    check styleName(srValueModified) == "ct.value-modified"
    let (ok, pane) = paneOfWire("eventLog")
    check ok and pane == paneEventLog
    check not paneOfWire("timeline")[0]

  test "span offsets are UTF-8 bytes, not cells":
    # `▾` is three bytes and one cell; `漢` is three bytes and two cells.
    let row: StyledRow = @[
      StyledSpan(text: "▾ ", style: CellStyle(role: srChromeMuted)),
      StyledSpan(text: "漢x", style: CellStyle(role: srValueModified,
                                               bold: true)),
      StyledSpan(text: " tail", style: CellStyle())]
    let spot = PaneHotspot(startCol: 2, endCol: 5,
                           operation: "calltrace.go-to-call",
                           args: PaneOpArgs(index: 7))
    let j = rowJson(row, @[spot])
    check j["text"].getStr == "▾ 漢x tail"
    let spans = j["spans"]
    # The plain span names no style and is not sent.
    check spans.len == 2
    check spans[0]["start"].getInt == 0 and spans[0]["end"].getInt == 4
    check spans[1]["start"].getInt == 4 and spans[1]["end"].getInt == 8
    check spans[1]["style"].getStr == "ct.value-modified"
    check spans[1]["bold"].getBool
    # Cells 2..5 are `漢` (two cells) and `x`: bytes 4..8.
    let h = j["hotspots"][0]
    check h["start"].getInt == 4 and h["end"].getInt == 8
    check h["operation"].getStr == "calltrace.go-to-call"
    check h["args"]["index"].getInt == 7
    check paneArgsOf(h["args"]).index == 7

  test "a key the editor binds is marked, the first binding of a key wins":
    let entries = @[
      ReferenceEntry(layer: "user:global", keyText: "F10",
                     operation: "debugger.step-over"),
      ReferenceEntry(layer: "base:global", keyText: "F10",
                     operation: "debugger.step-into"),
      ReferenceEntry(layer: "base:global", keyText: "Enter",
                     operation: "list.expand")]
    let km = keymapJson(entries, @["Enter"])
    check km.len == 2
    check km[0]["operation"].getStr == "debugger.step-over"
    check km[1]["shadowedBy"].getStr == "editor"

  test "the catalogue lists the panes' operations after the keymap's":
    var sawCatalogued, sawPane = false
    for o in operationsJson():
      if o["name"].getStr == "debugger.step-over": sawCatalogued = true
      if o["name"].getStr == "variables.toggle-expand":
        sawPane = o{"pane"}.getBool
    check sawCatalogued and sawPane
    check PaneProtocolVersion == 1
