## test_view_census.nim — the Headless-SDK front-ends' verification census.
##
## Three properties of the SOURCE TREE that the shared-view work established
## and that nothing else would notice regressing, because each regression
## still builds and still renders on the backend someone happens to look at:
##
## 1. **No pane polls for its container.** Every pane is mounted by whoever
##    creates its container (`ui/panel_host`, GoldenLayout's factories in
##    `ui/layout.nim`). The deferred, retrying `tryMountIsoNim…` mounts are
##    gone; the name must not come back in product code under `src/frontend`.
##    Test files are outside the scan: some assert the name's ABSENCE, and
##    some quote it as history.
##
## 2. **A view has one implementation for every renderer.** Under
##    `viewmodel/views/`, no proc or func is declared once for
##    `MockRenderer` / `MockNode` and again for `WebRenderer` / a DOM
##    `Element`. Such a pair is two implementations the headless tests can
##    only see one of. Views are generic (`[R, N]`) and use the renderer's
##    own API (isonim's `firstElementChild`, `getAttribute`, `inputValue`,
##    `setChecked`, `setInnerHtml`, …). Procs over ONE renderer — a
##    browser-only mount entry, an FFI wrapper — are not pairs and are
##    allowed. Templates are outside the scan: the one renderer-keyed
##    template left (`isonim_state_view.BadgeEvent`) maps an event TYPE, which
##    a generic proc cannot express.
##
## 3. **No `for` / `if` over a signal inside a `ui` block.** The DSL's
##    `for` and `if` run ONCE, when the block builds, so a loop or branch
##    over reactive state renders its first value forever. Reactive lists and
##    branches go through `indexEach` / `forEachKeyed` / `show`, and a
##    reactive attribute through an expression in the attribute. A control
##    statement is flagged when it starts a line inside a `ui(r):` block
##    (outside an event-handler lambda) and its header reads a signal: a
##    `.val`, a free zero-argument call (`item()`), or a parameter declared
##    as a `proc(): T` accessor in the same file. The heuristic is
##    line-based; its positive and negative controls are the synthetic
##    sources below, so a scan that stopped matching anything fails here
##    rather than reporting a clean tree.
##
## Native only: the subject is the source tree, read with `std/os`, which the
## JS target lacks (`ci/lib/test-lane-files.sh` rejects it from `vm-unit-js`
## for that reason, as it does the other source-scan suites).

import std/[os, sets, strutils, tables, unittest]

const
  FrontendDir = "src/frontend"
  ViewsDir = "src/frontend/viewmodel/views"

proc isIdentChar(c: char): bool = c in IdentChars

proc productFiles(): seq[string] =
  ## Every `.nim` file under `src/frontend` that is not a test.
  for path in walkDirRec(FrontendDir):
    if path.endsWith(".nim") and "/tests/" notin path:
      result.add path

proc viewFiles(): seq[string] =
  for path in walkFiles(ViewsDir / "*.nim"):
    result.add path

# ---------------------------------------------------------------------------
# 2. Overload pairs
# ---------------------------------------------------------------------------

type RendererSide = enum rsMock, rsWeb

proc signatureAfter(text: string; nameEnd: int): string =
  ## The parameter list following a proc name, up to its closing `)`.
  var i = nameEnd
  while i < text.len and text[i] in {'*', ' '}: inc i
  if i >= text.len or text[i] != '(':
    return ""
  var depth = 0
  let start = i
  while i < text.len:
    case text[i]
    of '(': inc depth
    of ')':
      dec depth
      if depth == 0:
        return text[start .. i]
    else: discard
    inc i
  ""

proc rendererOverloads*(text: string): Table[string, set[RendererSide]] =
  ## Per non-generic proc / func name declared in `text`, which renderer
  ## sides its signatures name.
  for keyword in ["proc ", "func "]:
    var at = text.find(keyword)
    while at >= 0:
      let atLineStart = at == 0 or text[at - 1] in {' ', '\n'}
      var i = at + keyword.len
      let nameStart = i
      while i < text.len and text[i].isIdentChar: inc i
      let name = text[nameStart ..< i]
      if atLineStart and name.len > 0:
        let sig = signatureAfter(text, i)
        if sig.len > 0:
          var sides: set[RendererSide]
          if "MockRenderer" in sig or "MockNode" in sig:
            sides.incl rsMock
          if "WebRenderer" in sig or "Element" in sig:
            sides.incl rsWeb
          if sides.len > 0:
            result.mgetOrPut(name, {}).incl sides
      at = text.find(keyword, at + keyword.len)

proc overloadPairs*(text: string): seq[string] =
  for name, sides in rendererOverloads(text):
    if sides == {rsMock, rsWeb}:
      result.add name

# ---------------------------------------------------------------------------
# 3. Control flow over signals inside `ui` blocks
# ---------------------------------------------------------------------------

proc indentOf(line: string): int =
  while result < line.len and line[result] == ' ': inc result

proc opensUiBlock(line: string): bool =
  ## `ui(r):` / `let x = ui(r):` — a `ui` call over one identifier, ending
  ## the line with its block colon.
  let s = line.strip
  if not s.endsWith(":"):
    return false
  let at = s.find("ui(")
  if at < 0 or (at > 0 and s[at - 1].isIdentChar):
    return false
  var i = at + 3
  while i < s.len and s[i] == ' ': inc i
  let argStart = i
  while i < s.len and s[i].isIdentChar: inc i
  if i == argStart: return false
  while i < s.len and s[i] == ' ': inc i
  if i >= s.len or s[i] != ')': return false
  s[i + 1 .. ^1].strip == ":"

proc opensHandler(line: string): bool =
  ## `onclick = proc() =` / `proc(ev: Event) =` ending the line: the body is
  ## an event handler, which runs per event, not at build time.
  let s = line.strip
  let at = s.find("proc")
  at > 0 and s[0 ..< at].strip.endsWith("=") and s.endsWith("=")

proc accessorNames*(text: string): HashSet[string] =
  ## Names declared `name: proc(): T` — a reactive per-item accessor.
  var at = text.find("proc")
  while at >= 0:
    var i = at + 4
    while i < text.len and text[i] == ' ': inc i
    if text.continuesWith("()", i):
      i += 2
      while i < text.len and text[i] == ' ': inc i
      if i < text.len and text[i] == ':':
        var j = at - 1
        while j >= 0 and text[j] == ' ': dec j
        if j >= 0 and text[j] == ':':
          dec j
          while j >= 0 and text[j] == ' ': dec j
          let nameEnd = j
          while j >= 0 and text[j].isIdentChar: dec j
          if nameEnd > j:
            result.incl text[j + 1 .. nameEnd]
    at = text.find("proc", at + 4)

proc containsWord(s, word: string): bool =
  var at = s.find(word)
  while at >= 0:
    let before = at == 0 or not s[at - 1].isIdentChar
    let after = at + word.len >= s.len or not s[at + word.len].isIdentChar
    if before and after:
      return true
    at = s.find(word, at + 1)

proc readsSignal(header: string; accessors: HashSet[string]): bool =
  ## Whether a control statement's header reads reactive state.
  var at = header.find(".val")
  while at >= 0:
    if at + 4 >= header.len or not header[at + 4].isIdentChar:
      return true
    at = header.find(".val", at + 1)
  # A free zero-argument call: `item()`, not `x.len()`.
  at = header.find("()")
  while at >= 0:
    var j = at - 1
    while j >= 0 and header[j].isIdentChar: dec j
    if j < at - 1 and (j < 0 or header[j] != '.'):
      return true
    at = header.find("()", at + 1)
  for name in accessors:
    if header.containsWord(name):
      return true
  false

proc signalControlFlow*(text: string): seq[string] =
  ## `line: statement` for each control statement over a signal inside a
  ## `ui` block of `text`.
  let accessors = accessorNames(text)
  var uiIndent = -1
  var handlerIndent = -1
  let lines = text.splitLines
  for n, line in lines:
    let stripped = line.strip
    let indent = indentOf(line)
    if stripped.len > 0 and uiIndent >= 0 and indent <= uiIndent:
      uiIndent = -1
    if stripped.len > 0 and handlerIndent >= 0 and indent <= handlerIndent:
      handlerIndent = -1
    if opensUiBlock(line):
      uiIndent = indent
      continue
    if uiIndent < 0:
      continue
    if handlerIndent < 0 and opensHandler(line):
      handlerIndent = indent
      continue
    if handlerIndent >= 0:
      continue
    for keyword in ["for ", "if ", "elif ", "case ", "while "]:
      if stripped.startsWith(keyword):
        if readsSignal(stripped[keyword.len .. ^1], accessors):
          result.add $(n + 1) & ": " & stripped
        break

# ---------------------------------------------------------------------------
# The census
# ---------------------------------------------------------------------------

suite "the views census":

  test "the scan has a tree to read":
    # Run from the repository root, as every lane runs it; a wrong working
    # directory would otherwise scan nothing and pass.
    check dirExists(ViewsDir)
    check viewFiles().len > 20
    check productFiles().len > viewFiles().len

  test "no pane polls for its container":
    var found: seq[string]
    for path in productFiles():
      if "tryMountIsoNim" in readFile(path):
        found.add path
    check found.len == 0
    if found.len > 0:
      echo "  still naming tryMountIsoNim: ", found

  test "no view has one implementation per renderer":
    var found: seq[string]
    for path in viewFiles():
      for name in overloadPairs(readFile(path)):
        found.add path & ": " & name
    check found.len == 0
    if found.len > 0:
      echo "  Mock/Web overload pairs: ", found

  test "no ui block loops or branches over a signal":
    var found: seq[string]
    for path in viewFiles():
      for hit in signalControlFlow(readFile(path)):
        found.add path & ":" & hit
    check found.len == 0
    if found.len > 0:
      echo "  one-shot control flow over a signal: ", found

suite "the census's own controls":

  test "an overload pair is found, a generic or one-sided proc is not":
    let pair = """
proc helper(r: MockRenderer; node: MockNode) = discard
when defined(js):
  proc helper(r: WebRenderer;
              node: isonim_dom.Element) = discard
proc generic[R, N](r: R; node: N) = discard
proc webOnly(container: isonim_dom.Element) = discard
"""
    check overloadPairs(pair) == @["helper"]

  test "a loop or branch over a signal inside ui is found":
    let source = """
proc row[R, N](r: R; item: proc(): Item): N =
  ui(r):
    tdiv:
      if item().expanded:
        text "open"
      for entry in vm.entries.val:
        text entry
      if item.isLeaf:
        discard
"""
    check signalControlFlow(source).len == 3

  test "control flow outside ui, in a handler, or over plain values is not":
    let source = """
proc panel[R, N](r: R; vm: VM; rows: seq[string]): N =
  if vm.ready.val:
    discard
  ui(r):
    tdiv(onclick = proc() =
        if vm.open.val:
          vm.close()):
      for name in rows:
        text name
      if rows.len() > 0:
        text "rows"
      span(display = (if vm.busy.val: "inline" else: "none"))
"""
    check signalControlFlow(source).len == 0
