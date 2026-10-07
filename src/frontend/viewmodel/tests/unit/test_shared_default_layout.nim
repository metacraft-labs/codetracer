## test_shared_default_layout.nim — PLAT-45. **One default arrangement,
## shared by every front-end: the model half.**
##
## Run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_shared_default_layout.nim
##
## What this file asserts, each against the REAL code and none against a copy:
##
##   1. **The vocabulary** (deliverable 1): `PaneKind` names every pane the
##      desktop's default places; `desktop_panes.PaneContent` is one-to-one
##      onto `Content` ordinals and is the only relation between the two;
##      `EditModeHiddenPanes` is exactly the image of the desktop's own
##      `editModeHiddenContentIds()` through that table.
##   2. **The persisted format** (deliverable 1): `LayoutSchemaVersion` is 4;
##      every committed v3 document in the fixtures corpus restores through the
##      migration chain unchanged; a v4 document round-trips; a v3 document
##      migrates to exactly the tree it described.
##   3. **The capability** (deliverable 2): every pane a front-end cannot draw
##      carries a reason; `reportLeaves` names exactly the placed undrawable
##      panes and never omits one.
##   4. **The fold** (deliverable 4): the four laws at EVERY depth of BOTH
##      shared defaults, plus totality (negative and past-the-end depths) and
##      purity (the input is untouched); every authored step is effective.
##   5. **The generated desktop default** (deliverable 7): the committed
##      `src/config/default_layout.json` is byte-for-byte what the generator
##      writes, and the arrangement it produces on the desktop (config plus the
##      runtime's editor insertion) equals the hand-written file it replaced,
##      kept as `tests/fixtures/plat45/hand-written-default_layout.json` — so
##      the desktop's appearance did not change.
##   6. **The relation's own twin**: `arrangement_relation.ofRegions` really
##      can tell two arrangements apart (Verification-Harness-Traps §4a), and
##      refuses a tiling it cannot decompose.
##
## No mocks: every case is a pure function of values and committed files.

import std/[json, options, sets, strutils, unittest]

import headless_app/layout_model
import headless_app/desktop_panes
import headless_app/arrangement_relation
import ../../../../common/types

when defined(js):
  import std/jsffi
  import ../../../index/mode_default_layout

  proc jsParse(raw: cstring): js {.importjs: "JSON.parse(#)".}
  proc jsText(value: js): cstring {.importjs: "JSON.stringify(#)".}

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  CommittedDefault = staticRead("../../../../config/default_layout.json")
  HandWrittenDefault = staticRead(
    "../fixtures/plat45/hand-written-default_layout.json")
  V3Corpus = [
    staticRead("../../../../tests/visual/plat40-layout.json"),
    staticRead("../../../../tests/visual/plat41-layout.json"),
    staticRead("../../../../tests/visual/plat41-all-panes.json")]
    ## The committed schema-3 documents: PLAT-40's and PLAT-41's layout
    ## records, written by builds that predate PLAT-45.

proc paneTimelineIsGone(): bool =
  ## No `PaneKind` spells "timeline" any more.
  for p in PaneKind:
    if $p == "timeline": return false
  true

proc panesOf(tree: LayoutNode): set[PaneKind] =
  for p in allPanes(tree): result.incl p

# ---------------------------------------------------------------------------
# The desktop's arrangement, read out of a GoldenLayout config
# ---------------------------------------------------------------------------

proc percentOf(item: JsonNode): float =
  ## A GoldenLayout `size` string as a number, or -1 when absent.
  if item.hasKey("size"):
    let s = item["size"].getStr
    if s.endsWith("%"):
      return parseFloat(s[0 ..< s.len - 1])
  -1.0

proc goldenRegions(item: JsonNode; x, y, w, h: float;
                   into: var seq[RegionRect]) =
  ## Lay a GoldenLayout item out on the unit square the way GoldenLayout
  ## sizes children: a declared percentage is taken, and the undeclared
  ## children share what is left equally.
  let kind = item["type"].getStr
  case kind
  of "stack":
    var tabs: seq[string] = @[]
    var active = item{"activeItemIndex"}.getInt(0)
    var i = 0
    for c in item["content"]:
      let content = c["componentState"]["content"].getInt
      # PLAT-51: a retired panel (the Timeline) is dropped as the desktop's
      # `sanitizeLayoutConfig` drops it on load — the arrangement a user
      # sees has no tab for it.
      if content in retiredContentIds():
        if i < item{"activeItemIndex"}.getInt(0): dec active
        inc i
        continue
      let pane = paneOfContent(content)
      tabs.add(if pane.isSome: $pane.get else: "content#" & $content)
      inc i
    if tabs.len == 0:
      return
    into.add RegionRect(x: x, y: y, w: w, h: h, tabs: tabs,
                        active: clamp(active, 0, tabs.len - 1))
  of "component":
    goldenRegions(%*{"type": "stack", "content": [item]}, x, y, w, h, into)
  of "row", "column":
    let kids = item["content"]
    var declared = 0.0
    var undeclared = 0
    for c in kids:
      let p = percentOf(c)
      if p >= 0: declared += p else: inc undeclared
    let free = if undeclared > 0: max(0.0, 100.0 - declared) / float(undeclared)
               else: 0.0
    var cursor = if kind == "row": x else: y
    for c in kids:
      let p = percentOf(c)
      let share = (if p >= 0: p else: free) / 100.0
      if kind == "row":
        goldenRegions(c, cursor, y, w * share, h, into)
        cursor += w * share
      else:
        goldenRegions(c, x, cursor, w, h * share, into)
        cursor += h * share
  else:
    discard

proc desktopRuntimeRegions(config: JsonNode): seq[RegionRect] =
  ## The desktop's arrangement as the RUNTIME makes it from `config`: the
  ## root row's children, then the editor inserted at index 1 by
  ## `utils.openNewLayoutContainer`, which GoldenLayout gives `1/n` of the row
  ## and scales the others by `(n-1)/n`. The editor is a region like any
  ## other once it is there.
  let root = config["root"]
  let kids = root["content"]
  let n = kids.len + 1
  let editorShare = 1.0 / float(n)
  let scale = float(n - 1) / float(n)
  var cursor = 0.0
  var i = 0
  for c in kids:
    if i == DesktopEditorIndex:
      result.add RegionRect(x: cursor, y: 0, w: editorShare, h: 1,
                            tabs: @[$paneEditor], active: 0)
      cursor += editorShare
    let share = percentOf(c) / 100.0 * scale
    goldenRegions(c, cursor, 0, share, 1, result)
    cursor += share
    inc i

suite "PLAT-45 deliverable 1 — the vocabulary covers the desktop's default":

  test "PaneKind names every pane the hand-written desktop default placed":
    var contents: seq[int] = @[]
    proc walk(n: JsonNode) =
      if n.kind == JObject:
        if n.hasKey("componentState"):
          contents.add n["componentState"]["content"].getInt
        for k, v in n: walk(v)
      elif n.kind == JArray:
        for v in n: walk(v)
    walk(parseJson(HandWrittenDefault))
    ck contents.len == 11
    # PLAT-51: every one but the Timeline, which is RETIRED (no `PaneKind`,
    # sanitised out of a saved desktop config) — and exactly one is.
    var retired = 0
    for c in contents:
      if c in retiredContentIds():
        inc retired
        ck c == ord(Content.RetiredTimelinePanel)
      else:
        ck paneOfContent(c).isSome
    ck retired == 1

  test "the table is one-to-one onto Content ordinals, and inverts":
    var seen = initHashSet[int]()
    var rows = 0
    for p in PaneKind:
      let row = PaneContent[p]
      if row.placement == dpNone:
        continue
      inc rows
      ck ord(row.content) notin seen
      seen.incl ord(row.content)
      ck paneOfContent(ord(row.content)).get == p
      ck row.label.len > 0
    # Every PaneKind but flow has a desktop Content; flow is an editor overlay.
    ck rows == PaneKind.high.ord
    ck PaneContent[paneFlow].placement == dpNone
    # The five PLAT-45 added map to the ordinals the desktop's default used.
    ck ord(PaneContent[paneVcs].content) == 41
    ck ord(PaneContent[paneAgentActivity].content) == 35
    ck ord(PaneContent[paneTerminalOutput].content) == 24
    ck ord(PaneContent[paneTestResults].content) == 48
    ck ord(PaneContent[paneConstraints].content) == 49
    # An ordinal no pane maps to is none, not a guess.
    ck paneOfContent(ord(Content.History)).isNone
    ck paneOfContent(9999).isNone

  test "EditModeHiddenPanes is the desktop's own edit-mode set, through the table":
    var image: set[PaneKind] = {}
    for c in editModeHiddenContentIds():
      let p = paneOfContent(c)
      if p.isSome: image.incl p.get
    ck image == EditModeHiddenPanes

suite "PLAT-45 deliverable 1 — LayoutSchemaVersion 3 -> 4 (and PLAT-48's 5, PLAT-51's 6)":

  # PLAT-48 bumped the schema to 5 (the desktop's PROBLEMS and REQUESTS
  # footer panels are new `PaneKind`s, docked by the shared default); v3 and
  # v4 documents migrate forward unchanged in their trees.
  test "the version is 6 and the chain still starts at 1":
    ck LayoutSchemaVersion == 6
    ck FirstLayoutSchemaVersion == 1

  test "every committed v3 document restores unchanged, migrated to the current version":
    var placedTimeline = 0
    for text in V3Corpus:
      let doc = parseJson(text)
      ck doc["version"].getInt == 3
      let restored = restoreLayoutDocument(doc)
      ck restored.version == LayoutSchemaVersion
      # MIGRATION, NOT REJECTION, AND NOT A REWRITE: the panes the document
      # placed are the panes that came back — less the Timeline (PLAT-51),
      # which every one of these documents placed and v6 drops.
      var spelled: seq[string] = @[]
      proc walk(n: JsonNode) =
        if n.kind == JObject:
          if n.hasKey("pane"): spelled.add n["pane"].getStr
          if n.hasKey("children"):
            for c in n["children"]: walk(c)
      walk(doc["layout"])
      if "timeline" in spelled: inc placedTimeline
      var back: seq[string] = @[]
      for p in allPanes(restored.tree): back.add $p
      var want: seq[string] = @[]
      for sp in spelled:
        if sp != "timeline": want.add sp
      ck back == want
      ck validate(restored, {}).len == 0

  test "a current document naming the new panes round-trips":
    let layout = initLayout(sharedDefaultLayout().tree)
    let doc = saveLayout(layout)
    ck doc["version"].getInt == 6
    let back = restoreLayoutDocument(parseJson($doc))
    ck equalTrees(back.tree, layout.tree)
    ck panesOf(back.tree) == panesOf(layout.tree)

  test "a v3-stamped document is re-stamped and nothing else moves":
    var doc = saveLayout(initLayout(defaultReplayLayout()))
    doc["version"] = %3
    let back = restoreLayoutDocument(doc)
    ck back.version == 6
    ck equalTrees(back.tree, defaultReplayLayout())

  test "a v4 document as the previous build wrote it restores exactly, docked panes included":
    # PLAT-45/47's shape: a tree and a docked pane, no `beside` / `weight`,
    # version 4. It restores to the same tree and the same docked list —
    # it gains no footer panel (a saved arrangement is the user's).
    let layout = initLayout(sharedDefaultLayout().tree)
    let docked = layout.apply(cmdDock(paneFileTree, leLeft))
    ck docked.kind == loApplied
    var doc = saveLayout(docked.layout)
    doc["version"] = %4
    for d in doc["docked"]:
      for field in ["beside", "weight"]:
        if d.hasKey(field): d.delete(field)
    let back = restoreLayoutDocument(doc)
    ck back.version == 6
    ck equalTrees(back.tree, docked.layout.tree)
    ck back.docked.len == 1
    ck back.docked[0].pane == paneFileTree and back.docked[0].edge == leLeft
    ck back.docked[0].beside.isNone
    ck validate(back, {}).len == 0
    # …and unpinning it with no anchor still places it (at the root, the
    # pre-PLAT-48 answer, since the document names nowhere to go back to).
    let restored = back.apply(cmdRestoreDocked(paneFileTree))
    ck restored.kind == loApplied
    ck restored.layout.tree.contains(paneFileTree)

  test "a document from a newer build is refused as a whole":
    var doc = saveLayout(initLayout(sharedDefaultLayout().tree))
    doc["version"] = %(LayoutSchemaVersion + 1)
    var kind = ldeNotAnObject
    try:
      discard restoreLayoutDocument(doc)
    except LayoutDecodeError as e:
      kind = e.kind
    ck kind == ldeUnknownVersion

suite "PLAT-51 — LayoutSchemaVersion 5 -> 6: the Timeline panel is removed":

  # Layout-System.md, "The Timeline panel is removed (2026-10-05)": a saved
  # layout that placed it opens WITHOUT it — its stack keeps the other tabs,
  # a container left empty goes, a docked Timeline goes — and is never
  # refused with `ldeUnknownPane`.

  proc v5(layout: JsonNode; docked = newJArray()): JsonNode =
    %*{"version": 5, "layout": layout, "docked": docked}

  test "the v5 shared default (Event Log | Timeline | Terminal Output) opens without the tab":
    let doc = v5(%*{"kind": "column", "weight": 1.0, "children": [
      {"kind": "pane", "pane": "editor", "weight": 1.0},
      {"kind": "stack", "weight": 1.0, "activeIndex": 0, "children": [
        {"kind": "pane", "pane": "eventLog", "weight": 1.0},
        {"kind": "pane", "pane": "timeline", "weight": 1.0},
        {"kind": "pane", "pane": "terminalOutput", "weight": 1.0}]}]})
    let back = restoreLayoutDocument(doc)
    ck back.version == 6
    ck ofTree(back.tree).canonical ==
      "column(editor,stack[eventLog*,terminalOutput])"
    ck validate(back, {}).len == 0

  test "the ACTIVE Timeline tab hands its place to the tab that slid into it":
    for (active, want) in [(1, "stack[eventLog,terminalOutput*]"),
                           (2, "stack[eventLog,terminalOutput*]"),
                           (0, "stack[eventLog*,terminalOutput]")]:
      let doc = v5(%*{"kind": "row", "weight": 1.0, "children": [
        {"kind": "pane", "pane": "editor", "weight": 1.0},
        {"kind": "stack", "weight": 1.0, "activeIndex": active, "children": [
          {"kind": "pane", "pane": "eventLog", "weight": 1.0},
          {"kind": "pane", "pane": "timeline", "weight": 1.0},
          {"kind": "pane", "pane": "terminalOutput", "weight": 1.0}]}]})
      let back = restoreLayoutDocument(doc)
      checkpoint($active & " -> " & ofTree(back.tree).canonical)
      ck ofTree(back.tree).canonical == "row(editor," & want & ")"

  test "a container the Timeline alone filled is removed, and its siblings keep the space":
    let doc = v5(%*{"kind": "column", "weight": 1.0, "children": [
      {"kind": "pane", "pane": "editor", "weight": 3.0},
      {"kind": "stack", "weight": 1.0, "activeIndex": 0, "children": [
        {"kind": "pane", "pane": "timeline", "weight": 1.0}]}]})
    let back = restoreLayoutDocument(doc)
    ck back.tree.contains(paneEditor)
    ck allPanes(back.tree) == @[paneEditor]
    ck validate(back, {}).len == 0

  test "a docked Timeline is dropped; a pane docked beside it keeps its edge":
    let doc = v5(%*{"kind": "row", "weight": 1.0, "children": [
        {"kind": "pane", "pane": "editor", "weight": 1.0},
        {"kind": "pane", "pane": "state", "weight": 1.0}]},
      %*[{"pane": "timeline", "edge": "bottom", "order": 0},
         {"pane": "eventLog", "edge": "bottom", "order": 1,
          "beside": "timeline", "besideBefore": true}])
    let back = restoreLayoutDocument(doc)
    ck back.docked.len == 1
    ck back.docked[0].pane == paneEventLog
    ck back.docked[0].edge == leBottom
    ck back.docked[0].beside.isNone
    ck validate(back, {}).len == 0

  test "the spelling is retired, not unknown: a v6 document naming it is refused":
    ck "timeline" in RetiredPaneSpellings
    var doc = v5(%*{"kind": "pane", "pane": "timeline", "weight": 1.0})
    doc["version"] = %6
    var kind = ldeNotAnObject
    try:
      discard restoreLayoutDocument(doc)
    except LayoutDecodeError as e:
      kind = e.kind
    # A CURRENT document cannot name it (no build writes one); the migration
    # is what keeps an OLD document opening.
    ck kind == ldeUnknownPane
    ck paneTimelineIsGone()

suite "PLAT-45 deliverable 2 — a declared capability per front-end":

  test "every undrawable pane carries a reason, and a drawable one none":
    let caps = [desktopCapability()]
    for c in caps:
      for p in PaneKind:
        if c.canDraw(p): ck c.reasons[p].len == 0
        else: ck c.reasons[p].len > 0

  test "report leaves are exactly the placed panes a front-end cannot draw":
    let tree = sharedDefaultLayout().tree
    let narrow = paneCapability(feTerminal, {paneEditor, paneState},
      [(paneVcs, "no view")])
    let leaves = reportLeaves(tree, narrow)
    var named: set[PaneKind] = {}
    for r in leaves:
      named.incl r.pane
      ck r.frontEnd == feTerminal
      ck reportText(r).contains($r.pane)
    ck named == panesOf(tree) - {paneEditor, paneState}
    # Nothing is omitted: drawn + reported is the whole placed set.
    ck (named + ({paneEditor, paneState} * panesOf(tree))) == panesOf(tree)

  test "the desktop draws every pane of the shared default":
    ck reportLeaves(sharedDefaultLayout().tree, desktopCapability()).len == 0

  test "a report names the pane and the reason":
    let r = ReportLeaf(pane: paneTestResults, frontEnd: feGpui,
                       reason: "no view yet")
    ck reportText(r) == "testResults: not drawn by the gpui front-end — no view yet"
    ck reportText(r, "Test Results").startsWith("Test Results:")

suite "PLAT-45 deliverable 3 — the shared default's content":

  test "the BUNDLED tree is the desktop's arrangement: the panes it placed, plus the editor":
    let tree = sharedBundledLayout()
    var desktop: set[PaneKind] = {paneEditor}
    for r in desktopRuntimeRegions(parseJson(HandWrittenDefault)):
      for t in r.tabs:
        for p in PaneKind:
          if $p == t: desktop.incl p
    ck panesOf(tree) == desktop
    ck validate(initLayout(tree), panesOf(tree)).len == 0

  test "its fold order names placed panes only, and never the editor first":
    let s = sharedDefaultLayout()
    for step in s.folds:
      ck step.region in panesOf(s.tree)
      ck step.into in panesOf(s.tree)
      ck step.region != paneEditor

  test "the edit default is the bundled tree minus the replay-only panes, plus the build pane":
    let debugRel = ofTree(sharedBundledLayout())
    let editRel = ofTree(sharedEditLayout().tree)
    ck panesOf(sharedEditLayout().tree) ==
       (panesOf(sharedBundledLayout()) - EditModeHiddenPanes) +
         {paneBuildOutput}
    # Placement: every BEFORE pair between panes both defaults show is the same.
    for pair in editRel.before:
      let parts = pair.split('<')
      if parts[0] == "buildOutput" or parts[1] == "buildOutput": continue
      let other = parts[1] & "<" & parts[0]
      ck other notin debugRel.before

suite "PLAT-45 deliverable 4 — foldLayout and its laws":

  for (name, shared) in [("debug", sharedDefaultLayout()),
                         ("edit", sharedEditLayout())]:
    test "the four laws at every depth of the " & name & " default":
      let all = panesOf(shared.tree)
      var previous = high(int)
      for d in 0 .. maxFoldDepth(shared) + 2:
        let folded = foldLayout(shared, d)
        # LAW 1: every pane of the input is in every output.
        ck panesOf(folded) == all
        ck allPanes(folded).len == allPanes(shared.tree).len
        # LAW 3: monotone.
        let regions = visibleRegionCount(folded)
        ck regions <= previous
        previous = regions
        # LAW 4: the result validates, as a tree and as a whole layout.
        ck validate(folded).len == 0
        ck validate(initLayout(folded), all).len == 0
      # LAW 2: depth 0 is the identity.
      ck equalTrees(foldLayout(shared, 0), shared.tree)

    test "every authored step of the " & name & " order folds exactly one region":
      for d in 0 ..< maxFoldDepth(shared):
        ck visibleRegionCount(foldLayout(shared, d + 1)) ==
           visibleRegionCount(foldLayout(shared, d)) - 1

    test "the fold of the " & name & " default is total and pure":
      let before = $shared.tree
      ck equalTrees(foldLayout(shared, -3), shared.tree)
      ck equalTrees(foldLayout(shared, maxFoldDepth(shared) + 5),
                    foldLayout(shared, maxFoldDepth(shared)))
      discard foldLayout(shared, maxFoldDepth(shared))
      ck $shared.tree == before

  test "the deepest debug fold is one stack with the editor in front":
    let s = sharedDefaultLayout()
    let deepest = foldLayout(s, maxFoldDepth(s))
    ck deepest.kind == lnStack
    ck deepest.children[deepest.activeIndex].pane == paneEditor
    ck visibleRegionCount(deepest) == 1

  test "a folded pane becomes a tab of its target, never a region of its own":
    let s = sharedDefaultLayout()
    let one = foldLayout(s, 1)
    let host = regionOf(one, paneCalltrace)
    ck host.kind == lnStack
    ck regionOf(one, paneFileTree) == host
    ck regionOf(one, paneTestResults) == host
    # The target keeps its visible tab.
    ck host.children[host.activeIndex].pane == paneCalltrace

suite "PLAT-45 deliverable 7 — the desktop default is GENERATED":

  test "the committed file is byte-for-byte the generator's output":
    ck CommittedDefault == generatedDefaultLayoutText()

  test "and on the desktop it is the arrangement the hand-written file gave":
    let generated = ofRegions(desktopRuntimeRegions(parseJson(CommittedDefault)),
                              tolerance = 1e-6)
    let handWritten = ofRegions(
      desktopRuntimeRegions(parseJson(HandWrittenDefault)), tolerance = 1e-6)
    ck generated.problem.len == 0
    ck handWritten.problem.len == 0
    ck sameArrangement(generated, handWritten)
    # AND IT IS THE BUNDLED TREE'S, which is the claim that makes it generated
    # rather than merely equal.
    ck sameArrangement(generated, ofTree(sharedBundledLayout()))

  test "and the rendered SHARES are the shared tree's weights":
    # The generator writes the percentages that make the desktop's runtime
    # arrive at the tree's weights: the editor's 1/4 and the others scaled by
    # 3/4 must give back 15 / 25 / 41.25 / 18.75.
    let regions = desktopRuntimeRegions(parseJson(CommittedDefault))
    var files, editor = -1.0
    for r in regions:
      if r.tabs[0] == "fileTree": files = r.w
      if r.tabs[0] == "editor": editor = r.w
    ck abs(files - 0.15) < 1e-9
    ck abs(editor - 0.25) < 1e-9

  test "a tree whose editor the desktop would put elsewhere is refused":
    var refused = false
    try:
      discard layoutNodeToGoldenConfig(row([pane(paneEditor),
                                            pane(paneState)]))
    except ValueError:
      refused = true
    ck refused

  test "the generated default satisfies the loader's required-panel rule":
    # `index/config.isValidLayoutConfig` resets a layout with no Files panel;
    # the generated one must never trip it.
    ck CommittedDefault.contains("\"content\": " & $ord(Content.Filesystem))

suite "PLAT-47 deliverable 1 — the shared default is the desktop's Debug-mode layout":

  const GeneratedShared = staticRead(
    "../../../headless_app/shared_default_layout.generated.json")

  test "TESTS is a tab of the FILES panel beside VCS, and there is no CONSTRAINTS":
    let tree = sharedDefaultLayout().tree
    let files = regionOf(tree, paneFileTree)
    ck files.kind == lnStack
    var tabs: seq[PaneKind] = @[]
    for c in files.children: tabs.add c.pane
    ck tabs == @[paneFileTree, paneVcs, paneTestResults]
    ck files.children[files.activeIndex].pane == paneFileTree
    ck paneConstraints notin panesOf(tree)
    # No standing column for either: the root row is FILES | editor | the
    # replay column, exactly the desktop's Debug-mode row.
    ck tree.kind == lnRow
    ck tree.children.len == 3

  test "its relation is the desktop Debug layout's, stated once":
    ck ofTree(sharedDefaultLayout().tree).canonical ==
      "row(stack[fileTree*,vcs,testResults],editor," &
      "column(row(stack[state*,scratchpad],stack[calltrace*,agentActivity])," &
      "stack[eventLog*,terminalOutput]))"

  test "it is the generated file, read back, not a tree authored here":
    ck equalTrees(sharedDefaultLayout().tree,
                  fromJson(parseJson(GeneratedShared)))
    # The weights are the desktop's rendered Debug-mode shares: FILES and the
    # replay column keep their declared 20% and 55%, and the editor takes the
    # 25% they leave unclaimed (`utils.openNewLayoutContainer`).
    let tree = sharedDefaultLayout().tree
    ck tree.children[0].weight == 20.0
    ck tree.children[1].pane == paneEditor
    ck tree.children[1].weight == 25.0
    ck tree.children[2].weight == 55.0

  test "the inverse translation undoes the forward one on the bundled tree":
    # `goldenConfigToLayoutNode` is what reads the desktop's Debug-mode config
    # back; on the bundled config it must give back the bundled tree's
    # arrangement AND its rendered shares (the runtime's 1/4 editor).
    let back = goldenConfigToLayoutNode(parseJson(CommittedDefault))
    ck sameArrangement(ofTree(back), ofTree(sharedBundledLayout()))
    ck back.children[0].weight == 15.0
    ck back.children[1].weight == 25.0

  test "the inverse translation refuses what it cannot read":
    var refused = 0
    for bad in ["{}", """{"root": {"type": "column", "content": []}}""",
                """{"root": {"type": "row", "content": [{"type": "stack",
                   "content": [{"type": "component", "componentState":
                   {"content": 9999}}]}]}}"""]:
      try:
        discard goldenConfigToLayoutNode(parseJson(bad))
      except ValueError:
        inc refused
    ck refused == 3

  when defined(js):
    # THE ONE DERIVATION, run here on the JS backend where it lives: the
    # desktop's own `modeDefaultLayout` over the committed bundled config,
    # read back, must be byte-for-byte the committed shared default. The C
    # lane cannot run it (the derivation is `importjs`); this is the lane that
    # can, and `ci/test/default-layout-fresh.sh` runs the same check under
    # node at lint time.
    test "the desktop's Debug-mode derivation generates the committed default":
      let debugConfig = modeDefaultLayout(jsParse(cstring(CommittedDefault)),
                                          DebugMode)
      ck generatedSharedDefaultText(parseJson($jsText(debugConfig))) ==
        GeneratedShared

suite "PLAT-45 — the medium-independent relation can fail":

  test "two arrangements that differ are told apart":
    let a = ofTree(row([pane(paneEditor), pane(paneState)]))
    let b = ofTree(row([pane(paneState), pane(paneEditor)]))
    let c = ofTree(column([pane(paneEditor), pane(paneState)]))
    ck not sameArrangement(a, b)
    ck not sameArrangement(a, c)
    ck "editor<state" in a.before
    ck "state<editor" in b.before

  test "rectangles with splitter gaps reduce to the tree they came from":
    let rects = @[
      RegionRect(x: 0, y: 0, w: 30, h: 100, tabs: @["fileTree"], active: 0),
      RegionRect(x: 34, y: 0, w: 66, h: 48, tabs: @["state", "scratchpad"],
                 active: 1),
      RegionRect(x: 34, y: 52, w: 66, h: 48, tabs: @["eventLog"], active: 0)]
    let got = ofRegions(rects, tolerance = 5)
    ck got.problem.len == 0
    ck got.canonical == "row(fileTree,column(stack[state,scratchpad*],eventLog))"
    ck sameArrangement(got, ofTree(row([pane(paneFileTree),
      column([stack([pane(paneState), pane(paneScratchpad)], activeIndex = 1),
              pane(paneEventLog)])])))

  test "a tiling no straight cut separates is refused, not guessed":
    # A pinwheel: four rectangles around a centre, no full-length cut.
    let rects = @[
      RegionRect(x: 0, y: 0, w: 60, h: 40, tabs: @["a"], active: 0),
      RegionRect(x: 60, y: 0, w: 40, h: 60, tabs: @["b"], active: 0),
      RegionRect(x: 40, y: 60, w: 60, h: 40, tabs: @["c"], active: 0),
      RegionRect(x: 0, y: 40, w: 40, h: 60, tabs: @["d"], active: 0),
      RegionRect(x: 40, y: 40, w: 20, h: 20, tabs: @["e"], active: 0)]
    ck ofRegions(rects).problem.len > 0

echo "CHECKS: ", CHECKS
