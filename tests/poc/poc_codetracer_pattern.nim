## PoC: Replicate the exact CodeTracer wiring pattern to find where reactivity breaks.
##
## The CodeTracer pattern:
## 1. createCalltraceVM creates a VM inside withViewModel (which calls createRoot)
## 2. The VM has signals (store.calltrace.lines) and memos (visibleLines)
## 3. mountIsoNimCalltrace calls renderCalltracePanel(WebRenderer(), vm)
##    which creates DOM elements and indexEach effects
## 4. syncCalltraceData updates store.calltrace.lines.val = newLines
## 5. The indexEach effect should fire and update the DOM
##
## This test mimics the exact same sequence with MockRenderer.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/poc_codetracer_pattern.nim    # native
##   nim js -r src/frontend/viewmodel/tests/poc_codetracer_pattern.nim   # JS

import std/tables
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/viewmodel
import isonim/dsl/components

# ---------------------------------------------------------------------------
# Types mimicking CodeTracer's store + VM
# ---------------------------------------------------------------------------

type
  CallLine = object
    name: string
    depth: int
    index: int64

  SimpleStore = ref object
    ## Mimics ReplayDataStore.calltrace — holds the raw signal data
    lines: Signal[seq[CallLine]]
    startLineIndex: Signal[int64]

  SimpleVM = ref object of ViewModel
    ## Mimics CalltraceVM — has store + derived memos
    store: SimpleStore
    visibleLines: Memo[seq[CallLine]]
    selectedEntry: Signal[int]

# ---------------------------------------------------------------------------
# Factory mimicking createCalltraceVM
# ---------------------------------------------------------------------------

proc createSimpleVM(store: SimpleStore): SimpleVM =
  ## Mimics createCalltraceVM: creates VM inside withViewModel/createRoot
  withViewModel proc(dispose: proc()): SimpleVM =
    let visibleLines = createMemo[seq[CallLine]] proc(): seq[CallLine] =
      let lines = store.lines.val
      let startIdx = store.startLineIndex.val
      echo "  [memo] visibleLines recomputing: lines.len=", lines.len,
           " startIdx=", startIdx
      result = lines  # simplified: return all lines

    let selectedEntry = createSignal(0)

    SimpleVM(
      store: store,
      visibleLines: visibleLines,
      selectedEntry: selectedEntry,
      disposeProc: dispose,
    )

# ---------------------------------------------------------------------------
# View rendering mimicking renderCalltracePanel + renderCallLineList
# ---------------------------------------------------------------------------

proc renderCallLineList(r: MockRenderer; parent: MockNode; vm: SimpleVM) =
  ## Mimics renderCallLineList: uses indexEach to create rows
  let container = r.createElement("div")
  r.setAttribute(container, "class", "calltrace-lines")
  r.appendChild(parent, container)

  echo "  [view] renderCallLineList: starting indexEach"

  indexEach[CallLine, MockRenderer, MockNode](r, container,
    proc(): seq[CallLine] =
      let lines = vm.visibleLines.val
      echo "  [indexEach source] visibleLines.val => len=", lines.len
      lines,
    proc(item: proc(): CallLine, index: int): MockNode =
      let row = r.createElement("div")
      r.setAttribute(row, "class", "call-line")

      createRenderEffect proc() =
        let line = item()
        echo "  [renderEffect] row ", index, ": name=", line.name
        r.clearChildren(row)
        let nameSpan = r.createElement("span")
        r.setAttribute(nameSpan, "class", "call-name")
        r.setTextContent(nameSpan, line.name)
        r.appendChild(row, nameSpan)

      row
  )

proc renderSimplePanel(r: MockRenderer; vm: SimpleVM): MockNode =
  ## Mimics renderCalltracePanel
  let panel = r.createElement("div")
  r.setAttribute(panel, "class", "calltrace-component")
  renderCallLineList(r, panel, vm)
  panel

proc mountSimpleView(r: MockRenderer; container: MockNode; vm: SimpleVM) =
  ## Mimics mountIsoNimCalltrace
  echo "  [mount] mountSimpleView starting"
  let panel = renderSimplePanel(r, vm)
  r.appendChild(container, panel)
  echo "  [mount] mountSimpleView done"

# ---------------------------------------------------------------------------
# Helper: count calltrace-lines children
# ---------------------------------------------------------------------------

proc getLineContainer(container: MockNode): MockNode =
  ## Navigate: container > panel > calltrace-lines div
  assert container.children.len > 0, "container has no children"
  let panel = container.children[0]
  assert panel.children.len > 0, "panel has no children"
  let linesList = panel.children[0]  # calltrace-lines div
  assert linesList.attributes.getOrDefault("class") == "calltrace-lines",
    "Expected calltrace-lines, got class=" & linesList.attributes.getOrDefault("class")
  linesList

# ===========================================================================
# TEST 1: The exact CodeTracer pattern with MockRenderer
# ===========================================================================

echo "====== TEST 1: CodeTracer pattern (store created outside VM) ======"
echo ""

block testCodeTracerPattern:
  # Step 0: Create the store OUTSIDE any reactive root (like ReplayDataStore)
  echo "Step 0: Create store"
  let store = SimpleStore(
    lines: createSignal(newSeq[CallLine]()),
    startLineIndex: createSignal(0'i64),
  )
  echo "  Store created, lines.len=", store.lines.val.len

  # Step 1: Create VM (in its own root via withViewModel)
  echo ""
  echo "Step 1: Create VM via withViewModel"
  let vm = createSimpleVM(store)
  echo "  VM created"

  # Step 2: Mount view (creates effects that read from VM signals)
  echo ""
  echo "Step 2: Mount view (creates indexEach effects)"
  let r = MockRenderer()
  let container = r.createElement("div")
  mountSimpleView(r, container, vm)
  let linesList = getLineContainer(container)
  echo "  After mount: linesList.children.len=", linesList.children.len

  # Step 3: Update store from outside (simulating syncCalltraceData)
  echo ""
  echo "Step 3: Update store.lines from outside (like syncCalltraceData)"
  store.lines.val = @[
    CallLine(name: "main", depth: 0, index: 0),
    CallLine(name: "foo", depth: 1, index: 1),
    CallLine(name: "bar", depth: 2, index: 2),
  ]
  echo "  After update: linesList.children.len=", linesList.children.len

  # Verify
  if linesList.children.len == 3:
    echo ""
    echo "  SUCCESS: 3 rows rendered after store update"
    for i, child in linesList.children:
      echo "    row[", i, "]: ", child.textContent
  else:
    echo ""
    echo "  FAILURE: Expected 3 rows, got ", linesList.children.len
    echo "  The indexEach effect did NOT fire when store.lines changed!"

  assert linesList.children.len == 3,
    "TEST 1 FAILED: Expected 3 rows, got " & $linesList.children.len

  # Step 4: Update again (simulate another sync)
  echo ""
  echo "Step 4: Update store.lines again (add more entries)"
  store.lines.val = @[
    CallLine(name: "main", depth: 0, index: 0),
    CallLine(name: "foo", depth: 1, index: 1),
    CallLine(name: "bar", depth: 2, index: 2),
    CallLine(name: "baz", depth: 2, index: 3),
    CallLine(name: "qux", depth: 1, index: 4),
  ]
  echo "  After second update: linesList.children.len=", linesList.children.len

  assert linesList.children.len == 5,
    "TEST 1 STEP 4 FAILED: Expected 5 rows, got " & $linesList.children.len
  echo "  SUCCESS: 5 rows after second update"

  echo ""
  echo "TEST 1 PASSED"

# ===========================================================================
# TEST 2: Store created INSIDE a root (different from CodeTracer pattern)
# ===========================================================================

echo ""
echo "====== TEST 2: Store created inside root (control test) ======"
echo ""

block testStoreInRoot:
  var store: SimpleStore
  var vm: SimpleVM

  createRoot proc(dispose: proc()) =
    store = SimpleStore(
      lines: createSignal(newSeq[CallLine]()),
      startLineIndex: createSignal(0'i64),
    )

  vm = createSimpleVM(store)

  let r = MockRenderer()
  let container = r.createElement("div")
  mountSimpleView(r, container, vm)
  let linesList = getLineContainer(container)

  store.lines.val = @[
    CallLine(name: "alpha", depth: 0, index: 0),
    CallLine(name: "beta", depth: 1, index: 1),
  ]

  echo "  After update: linesList.children.len=", linesList.children.len

  assert linesList.children.len == 2,
    "TEST 2 FAILED: Expected 2 rows, got " & $linesList.children.len
  echo "  SUCCESS: 2 rows rendered"
  echo ""
  echo "TEST 2 PASSED"

# ===========================================================================
# TEST 3: Mount INSIDE its own createRoot (what if the view needs its own root?)
# ===========================================================================

echo ""
echo "====== TEST 3: Mount inside createRoot ======"
echo ""

block testMountInRoot:
  let store = SimpleStore(
    lines: createSignal(newSeq[CallLine]()),
    startLineIndex: createSignal(0'i64),
  )

  let vm = createSimpleVM(store)

  let r = MockRenderer()
  let container = r.createElement("div")

  # Mount inside a separate root (some CodeTracer code might do this)
  createRoot proc(dispose: proc()) =
    mountSimpleView(r, container, vm)

  let linesList = getLineContainer(container)

  store.lines.val = @[
    CallLine(name: "one", depth: 0, index: 0),
  ]

  echo "  After update: linesList.children.len=", linesList.children.len

  assert linesList.children.len == 1,
    "TEST 3 FAILED: Expected 1 row, got " & $linesList.children.len
  echo "  SUCCESS: 1 row rendered"
  echo ""
  echo "TEST 3 PASSED"

# ===========================================================================
# TEST 4: Mount with NO owner context (global scope — like browser event handler)
# ===========================================================================

echo ""
echo "====== TEST 4: Mount with no owner context (global scope) ======"
echo ""

block testNoOwner:
  let store = SimpleStore(
    lines: createSignal(newSeq[CallLine]()),
    startLineIndex: createSignal(0'i64),
  )

  let vm = createSimpleVM(store)

  let r = MockRenderer()
  let container = r.createElement("div")

  # Mount directly at global scope (no createRoot wrapping)
  # This is like calling mountIsoNimCalltrace from a JS callback
  mountSimpleView(r, container, vm)

  let linesList = getLineContainer(container)

  store.lines.val = @[
    CallLine(name: "globalA", depth: 0, index: 0),
    CallLine(name: "globalB", depth: 1, index: 1),
  ]

  echo "  After update: linesList.children.len=", linesList.children.len

  assert linesList.children.len == 2,
    "TEST 4 FAILED: Expected 2 rows, got " & $linesList.children.len
  echo "  SUCCESS: 2 rows rendered"
  echo ""
  echo "TEST 4 PASSED"

# ===========================================================================
# TEST 5: createEffect reading a Memo (simpler version without indexEach)
# ===========================================================================

echo ""
echo "====== TEST 5: Direct createEffect reading Memo (no indexEach) ======"
echo ""

block testDirectEffect:
  let store = SimpleStore(
    lines: createSignal(newSeq[CallLine]()),
    startLineIndex: createSignal(0'i64),
  )

  let vm = createSimpleVM(store)

  let r = MockRenderer()
  let container = r.createElement("div")
  var effectCount = 0

  # Direct effect reading the memo (simplest form of the pattern)
  createEffect proc() =
    let items = vm.visibleLines.val
    r.clearChildren(container)
    for item in items:
      let row = r.createElement("span")
      r.setTextContent(row, item.name)
      r.appendChild(container, row)
    inc effectCount

  echo "  After setup: children=", container.children.len, " effectCount=", effectCount

  store.lines.val = @[
    CallLine(name: "directA", depth: 0, index: 0),
    CallLine(name: "directB", depth: 1, index: 1),
    CallLine(name: "directC", depth: 2, index: 2),
  ]

  echo "  After update: children=", container.children.len, " effectCount=", effectCount

  assert container.children.len == 3,
    "TEST 5 FAILED: Expected 3 children, got " & $container.children.len
  assert effectCount == 2,
    "TEST 5 FAILED: Expected 2 effect runs, got " & $effectCount
  echo "  SUCCESS: Direct effect through Memo works"
  echo ""
  echo "TEST 5 PASSED"

echo ""
echo "======================================================"
echo "ALL TESTS PASSED"
echo "======================================================"
