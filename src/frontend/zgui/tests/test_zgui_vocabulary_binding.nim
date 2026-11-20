## test_zgui_vocabulary_binding.nim — the zgui binding against the web binding,
## on zgui's headless platform, with no recording.
##
## The part of the cross-renderer subset that needs no `replay-server`, so it
## runs wherever zgui runs (x86_64-linux on Mesa's software Vulkan driver,
## aarch64-darwin on Metal): every vocabulary entry rendered by both bindings,
## the state each one shows read back and compared; keys delivered through
## zgui's own dispatch and through the web binding's handler, compared after
## every key; the in-place update checked against a fresh render; and the
## editor rows drawn by the real wgpu renderer and read back as pixels.
##
## ## WHAT IS COMPARED WITH WHAT
##
## The zgui arm's facts come out of zgui's document across the shim's C ABI
## (`zg_get_attribute`); the web arm's out of isonim's `MockRenderer` DOM.
## Both arms walk with `fact_reader.readAttributeFacts`, so the last case
## shows the comparison can go red over that shared walk.
##
## ## NO MOCKS
##
## `MockRenderer` is one of the renderer backends isonim ships, the backend the
## web binding's non-JS instantiation compiles against (the justification
## `tui/tests/test_view_vocabulary_cross_medium.nim` gives, inherited here).
## zgui is the real runtime on its headless platform.

import std/[strutils, tables, unittest]

import isonim/testing/mock_dom
import isonim_zgui/testing

import ../../../common/view_vocabulary
import ../../view_vocabulary/web_binding as wbind
import ../../view_vocabulary/zgui_binding as zbind
import ../../view_vocabulary/fact_reader
import ../app/zgui_leaves
import ../../styles/generated/design_tokens

var countedAssertions = 0
const ExpectedAssertions = 53

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc opt(id, label: string; disabled = false): ViewOption =
  ViewOption(id: id, label: label, disabled: disabled)

proc wholeVocabulary(): ViewNode =
  ## Every entry, as the GPUI binding's suite builds it.
  viewCollapsible("panel", "Debug settings", @[
    viewText("title", "Settings"),
    viewButton("apply", "Apply"),
    viewCheckbox("wrap", "Wrap long values"),
    viewToggle("live", "Live update"),
    viewInput("filter", "abc"),
    viewSelect("lang", @[opt("rs", "Rust"), opt("py", "Python"),
                         opt("go", "Go")], selected = 0),
    viewList("recent", @[opt("a", "alpha"), opt("b", "beta", disabled = true),
                         opt("c", "gamma")]),
    viewTreeNode("state", "locals", @[
      viewTreeNode("state.x", "x"),
      viewTreeNode("state.p", "p", @[viewTreeNode("state.p.y", "y")])],
      expanded = true),
    viewTable("tbl", @["name", "value"],
              @[@["a", "1"], @["b", "2"], @["c", "3"]]),
    viewTabs("panes", @[opt("t1", "Source"), opt("t2", "State")]),
    viewMenu("ctx", @[opt("m1", "Copy"), opt("m2", "Paste")]),
    viewProgress("load", 40),
    viewImage("shot", "image/png", "screenshot of the state panel", 2048),
    viewMarkdown("doc", "# Title\n\nbody"),
    viewModal("dlg", "Confirm", @[viewText("dlgtext", "Are you sure?")])],
    expanded = true)

proc table(fs: seq[StateFact]): Table[string, string] =
  for f in fs: result[f.id & "." & f.field] = f.value

proc webFacts(model: ViewNode): Table[string, string] =
  let b = renderWeb[MockRenderer, MockNode](MockRenderer(), model)
  table(b.readWebFacts())

proc differences(a, b: Table[string, string]): seq[string] =
  for k, v in a:
    if k notin b: result.add k & ": only in the first"
    elif b[k] != v: result.add k & ": " & v & " vs " & b[k]
  for k in b.keys:
    if k notin a: result.add k & ": only in the second"

var root: ZguiNode

proc openWindow(mode = zrNowhere) =
  openHeadless(800, 600, ZguiVocabularyCss & ZguiLeavesCss, mode,
               proc(r: ZguiNode) = root = r)
  discard settle()

suite "the zgui binding shows what the web binding shows":

  test "every entry's state, read back out of zgui, equals the web binding's":
    openWindow()
    try:
      let model = wholeVocabulary()
      let z = renderZgui(ZguiRenderer(), model)
      root.mount(z.root)
      let zf = table(z.readZguiFacts())
      let wf = webFacts(wholeVocabulary())
      checkpoint(differences(zf, wf).join("\n"))
      ck differences(zf, wf).len == 0
      # Every entry reached the document, not only the ones that agree.
      var kinds: set[ViewKind]
      for id, el in z.nodes:
        let name = getAttribute(el, ViewKindAttribute)
        for k in ViewKind:
          if vocabularyName(k) == name: kinds.incl k
      ck kinds == {low(ViewKind) .. high(ViewKind)}
      ck z.ownTextOf("title") == "Settings"
    finally:
      closeHeadless()

  test "keys through zgui's own dispatch move the state the web binding moves":
    openWindow()
    try:
      let z = renderZgui(ZguiRenderer(), wholeVocabulary())
      root.mount(z.root)
      let w = renderWeb[MockRenderer, MockNode](MockRenderer(),
                                                wholeVocabulary())
      let script = @[("recent", kDown), ("recent", kDown), ("recent", kUp),
                     ("tbl", kDown), ("tbl", kDown), ("panes", kRight),
                     ("lang", kDown), ("state", kDown), ("wrap", kSpace)]
      var consumed = 0
      for (id, key) in script:
        let zo = z.sendKey(id, key)
        discard settle()
        let wo = w.sendKey(id, key)
        ck zo.handled == wo.handled
        if zo.handled: inc consumed
        let d = differences(table(z.readZguiFacts()), table(w.readWebFacts()))
        checkpoint(id & " " & $key & ": " & d.join("; "))
        ck d.len == 0
      # The keys were real deliveries: zgui routed each to the focused element
      # and its listener consumed it.
      ck consumed > 0
      ck z.keysHandled == consumed
    finally:
      closeHeadless()

  test "a key the entry does not claim is left to the window":
    openWindow()
    try:
      let z = renderZgui(ZguiRenderer(), wholeVocabulary())
      root.mount(z.root)
      var reached = 0
      addListener(root, "keydown", proc(ev: ZguiEvent): uint32 =
        inc reached
        0'u32)
      let before = z.keysHandled
      ck not z.sendKey("tbl", kChar, "n").handled
      ck z.keysHandled == before
      ck reached == 1
    finally:
      closeHeadless()

suite "an update writes into the document zgui holds":

  test "one changed cell is written in place, and reads back as a fresh render":
    openWindow()
    try:
      let rows = block:
        var rs: seq[seq[string]]
        for i in 0 ..< 200: rs.add @["e" & $i, "v" & $i]
        rs
      let z = renderZgui(ZguiRenderer(), viewTable("log", @["event", "value"], rows))
      root.mount(z.root)
      let before = z.root
      var changed = rows
      changed[57][1] = "changed"
      z.resetCounters()
      z.update(viewTable("log", @["event", "value"], changed))
      discard settle()
      ck z.root == before
      ck z.replaced == 0
      ck z.written >= 1 and z.written <= 3
      ck "changed" in textContent(z.root)
      ck differences(table(z.readZguiFacts()),
                     webFacts(viewTable("log", @["event", "value"], changed))).len == 0
    finally:
      closeHeadless()

  test "a moved cursor rewrites two rows; a new shape is drawn afresh":
    openWindow()
    try:
      let rows = @[@["a", "1"], @["b", "2"], @["c", "3"]]
      let z = renderZgui(ZguiRenderer(), viewTable("t", @["k", "v"], rows))
      root.mount(z.root)
      var moved = viewTable("t", @["k", "v"], rows)
      moved.cursor = 2
      z.resetCounters()
      z.update(moved)
      ck z.replaced == 0
      ck table(z.readZguiFacts())["t.row"] == "2"
      # A list where a table was: nothing of the old element can be kept.
      z.resetCounters()
      z.update(viewList("t", @[opt("x", "x")]))
      ck z.replaced == 1
      ck table(z.readZguiFacts())["t.highlight"] == "0"
    finally:
      closeHeadless()

  test "a tree that gains and loses children keeps the ones it still has":
    openWindow()
    try:
      proc locals(names: seq[string]): ViewNode =
        var kids: seq[ViewNode]
        for n in names: kids.add viewTreeNode("v." & n, n & ": 1")
        viewTreeNode("vars", "locals", kids, expanded = true)
      let z = renderZgui(ZguiRenderer(), locals(@["a", "b", "c"]))
      root.mount(z.root)
      let kept = z.nodes["v.c"]
      z.resetCounters()
      z.update(locals(@["a", "x", "c", "d"]))
      discard settle()
      # `b` released, `x` and `d` created; `a` and `c` are the same elements.
      ck z.replaced == 3
      ck z.nodes["v.c"] == kept
      ck differences(table(z.readZguiFacts()),
                     webFacts(locals(@["a", "x", "c", "d"]))).len == 0
      let text = textContent(z.root)
      ck text.find("a: 1") < text.find("x: 1") and
         text.find("x: 1") < text.find("c: 1") and
         text.find("c: 1") < text.find("d: 1")
      ck not text.contains("b: 1")
    finally:
      closeHeadless()

  test "rows added and removed at the end of a table":
    openWindow()
    try:
      let z = renderZgui(ZguiRenderer(), viewTable("t", @["k"], @[@["a"], @["b"]]))
      root.mount(z.root)
      z.update(viewTable("t", @["k"], @[@["a"], @["b"], @["c"], @["d"]]))
      ck textContent(z.root).contains("d")
      z.update(viewTable("t", @["k"], @[@["a"]]))
      discard settle()
      ck not textContent(z.root).contains("b")
      ck textContent(z.root).contains("a")
    finally:
      closeHeadless()

suite "the editor's rows, drawn by the real renderer":

  test "each row publishes its model, and the execution row has its band":
    openWindow(zrOffscreen)
    try:
      let r = ZguiRenderer()
      let rowsEl = r.createElement("div")
      r.setAttribute(rowsEl, "class", "ct-editor-rows")
      r.setStyle(rowsEl, "width", "800px")
      r.setStyle(rowsEl, "height", "600px")
      r.setStyle(rowsEl, "background-color",
                 DesignTokenHex[dtEditorThemeGround][dmDark])
      let rows = @[
        EditorRow(line: 1, text: "def add(a, b):", held: true),
        EditorRow(line: 2, text: "    return a + b", held: true,
                  pointer: eptExecution,
                  values: @[EditorValue(name: "a", value: "1"),
                            EditorValue(name: "b", value: "2")],
                  flow: efsTaken),
        EditorRow(line: 3, text: "else:", held: true, flow: efsNotTaken,
                  mark: emBreakpoint)]
      var els: seq[ZguiNode]
      for row in rows:
        let el = renderEditorRow(r, row, @[])
        r.appendChild(rowsEl, el)
        els.add el
      root.mount(rowsEl)
      discard settle()
      ck getAttribute(els[1], EditorPointerAttribute) == $eptExecution
      ck getAttribute(els[1], EditorValuesAttribute) == "a=1|b=2"
      ck getAttribute(els[2], EditorFlowAttribute) == $efsNotTaken
      ck getAttribute(els[2], EditorMarkAttribute) == $emBreakpoint
      ck textContent(els[1]).contains("return a + b")
      ck textContent(els[1]).contains("a1")
      let c = capture()
      ck c.width > 0
      # The pixel 3px into the code column of each row: the execution row
      # carries the design system's execution-line band, the others the
      # editor's ground.
      proc codeLeft(el: ZguiNode): tuple[r, g, b, a: int] =
        let row = el.borderBox()
        c.pixel(int(row.x) + 64 + 3, int(row.y + row.h / 2))
      proc hexOf(p: tuple[r, g, b, a: int]): string =
        "#" & toHex(p.r, 2).toLowerAscii & toHex(p.g, 2).toLowerAscii &
          toHex(p.b, 2).toLowerAscii
      let band = DesignTokenHex[dtEditorThemeExecutionLine][dmDark]
      let ground = DesignTokenHex[dtEditorThemeGround][dmDark]
      checkpoint("exec " & hexOf(codeLeft(els[1])) & " other " &
                 hexOf(codeLeft(els[0])))
      ck hexOf(codeLeft(els[1])) == band
      ck hexOf(codeLeft(els[0])) == ground
    finally:
      closeHeadless()

suite "the comparison can go red":

  test "a fact zgui keeps differently is reported":
    openWindow()
    try:
      let z = renderZgui(ZguiRenderer(), wholeVocabulary())
      root.mount(z.root)
      # Write a wrong highlight straight into the document, as a binding with
      # a defect would: the reader sees it and the comparison names it.
      ZguiRenderer().setAttribute(z.nodes["recent"],
                                  factAttributeName("highlight"), "2")
      let d = differences(table(z.readZguiFacts()), webFacts(wholeVocabulary()))
      ck d == @["recent.highlight: 2 vs 0"]
    finally:
      closeHeadless()

suite "assertion count":
  test "every case in this file ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
