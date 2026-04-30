import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import std/strformat

type
  SimpleStore = ref object
    debugger: Signal[int]
    storeId: int

  SimpleVM = ref object of ViewModel
    store: SimpleStore

var storeCount = 0

proc createSimpleStore(): SimpleStore =
  inc storeCount
  result = SimpleStore(debugger: createSignal(0), storeId: storeCount)
  echo fmt"Created store id={result.storeId}"

proc createSimpleVM(store: SimpleStore): SimpleVM =
  echo fmt"Creating VM with store id={store.storeId}"
  withViewModel proc(dispose: proc()): SimpleVM =
    createEffect proc() =
      let val = store.debugger.val
      echo fmt"  VM effect fired: storeId={store.storeId} val={val}"
    SimpleVM(store: store)

# Simulate CodeTracer's double-creation pattern

# Step 1: Create stub store + stub VM (like initCalltraceVM in register())
var vmInstance: SimpleVM
var vmStore: SimpleStore
echo "--- Step 1: Stub creation ---"
let stubStore = createSimpleStore()  # storeId=1
vmStore = stubStore
vmInstance = createSimpleVM(stubStore)

# Step 2: Replace with shared store (like initCalltraceVMWithStore)
echo "--- Step 2: Replacement with shared store ---"
let sharedStore = createSimpleStore()  # storeId=2
vmStore = sharedStore
vmInstance = createSimpleVM(sharedStore)  # Creates NEW effect watching sharedStore

# Step 3: Update the shared store (like syncCalltraceDebuggerPosition)
echo "--- Step 3: Update shared store ---"
vmStore.debugger.val = 42

echo "--- Step 4: Update again ---"
vmStore.debugger.val = 100

echo ""
echo "Expected: VM effect should fire with val=42 and val=100"
