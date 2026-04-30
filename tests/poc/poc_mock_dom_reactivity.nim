## Test: Signal changes drive MockRenderer DOM updates via effects.
## Verifies that the reactive system propagates signal writes into
## DOM-like mutations through the mock renderer.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/poc_mock_dom_reactivity.nim    # native
##   nim js -r src/frontend/viewmodel/tests/poc_mock_dom_reactivity.nim   # JS

import isonim/core/[signals, computation, owner, batch]
import isonim/testing/mock_dom

# --- Test 1: Signal→Effect→MockRenderer text content update ---

block testTextUpdate:
  var sig: Signal[int]
  createRoot proc(dispose: proc()) =
    sig = createSignal(0)

  let r = MockRenderer()
  let output = r.createElement("div")
  var updateCount = 0

  createRoot proc(dispose: proc()) =
    createEffect proc() =
      let val = sig.val
      r.setTextContent(output, "Value: " & $val)
      inc updateCount

  assert output.textContent == "Value: 0", "Initial: expected 'Value: 0', got '" & output.textContent & "'"
  assert updateCount == 1

  sig.val = 42
  assert output.textContent == "Value: 42", "After 42: expected 'Value: 42', got '" & output.textContent & "'"
  assert updateCount == 2

  sig.val = 100
  assert output.textContent == "Value: 100", "After 100: expected 'Value: 100', got '" & output.textContent & "'"
  assert updateCount == 3

  # No-op write (same value) should NOT trigger effect
  sig.val = 100
  assert updateCount == 3, "No-op write should not trigger effect, but count is " & $updateCount

  echo "Test 1 PASSED: Signal→Effect→DOM text update works"

# --- Test 2: Signal→Effect→MockRenderer child list rebuild ---

block testChildList:
  var items: Signal[seq[string]]
  createRoot proc(dispose: proc()) =
    items = createSignal(newSeq[string]())

  let r = MockRenderer()
  let container = r.createElement("div")

  createRoot proc(dispose: proc()) =
    createEffect proc() =
      let current = items.val
      r.clearChildren(container)
      for item in current:
        let row = r.createElement("span")
        r.setTextContent(row, item)
        r.appendChild(container, row)

  assert container.children.len == 0, "Initial: no children"

  items.val = @["hello", "world"]
  assert container.children.len == 2, "After update: expected 2 children, got " & $container.children.len
  assert container.children[0].textContent == "hello"
  assert container.children[1].textContent == "world"

  items.val = @["a", "b", "c"]
  assert container.children.len == 3, "After second update: expected 3, got " & $container.children.len
  assert container.children[2].textContent == "c"

  echo "Test 2 PASSED: Signal→Effect→DOM child list rebuild works"

# --- Test 3: Batched updates trigger effect only once ---

block testBatch:
  var a: Signal[int]
  var b: Signal[int]
  createRoot proc(dispose: proc()) =
    a = createSignal(0)
    b = createSignal(0)

  var effectCount = 0
  var lastSum = -1

  createRoot proc(dispose: proc()) =
    createEffect proc() =
      lastSum = a.val + b.val
      inc effectCount

  assert effectCount == 1
  assert lastSum == 0

  batch proc() =
    a.val = 10
    b.val = 20

  assert lastSum == 30, "Batch: expected sum 30, got " & $lastSum
  assert effectCount == 2, "Batch: expected 2 effect fires (init + 1 batched), got " & $effectCount

  echo "Test 3 PASSED: Batched signal writes trigger single effect execution"

# --- Test 4: Event handler simulation (fireEvent → signal write → DOM update) ---

block testEventHandler:
  var counter: Signal[int]
  createRoot proc(dispose: proc()) =
    counter = createSignal(0)

  let r = MockRenderer()
  let button = r.createElement("button")
  let display = r.createElement("span")

  # Wire up: button click increments the signal
  r.addEventListener(button, "click", proc() =
    counter.val = counter.val + 1
  )

  # Effect renders the counter into the display
  createRoot proc(dispose: proc()) =
    createEffect proc() =
      r.setTextContent(display, "Count: " & $counter.val)

  assert display.textContent == "Count: 0"

  # Simulate three clicks
  button.fireEvent("click")
  assert display.textContent == "Count: 1", "After click 1: got '" & display.textContent & "'"

  button.fireEvent("click")
  assert display.textContent == "Count: 2", "After click 2: got '" & display.textContent & "'"

  button.fireEvent("click")
  assert display.textContent == "Count: 3", "After click 3: got '" & display.textContent & "'"

  echo "Test 4 PASSED: Event handler → signal write → DOM update works"

echo ""
echo "ALL TESTS PASSED: Signal→Effect→MockRenderer DOM rendering is fully functional"
