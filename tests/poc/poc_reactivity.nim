## Test: Do effects in one root see signal changes from another root?
## Also tests updates from outside any reactive context.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/poc_reactivity.nim    # native
##   nim js -r src/frontend/viewmodel/tests/poc_reactivity.nim   # JS

import isonim/core/[signals, computation, owner]

var effectFired = 0
var lastSeen = -1

# Root 1: create signal
var sig: Signal[int]
createRoot proc(dispose: proc()) =
  sig = createSignal(0)
  echo "Root 1: signal created with value ", sig.val

# Root 2: create effect that reads the signal
createRoot proc(dispose: proc()) =
  createEffect proc() =
    lastSeen = sig.val
    inc effectFired
    echo "Root 2 effect: saw value ", lastSeen

echo "After setup: effectFired=", effectFired, " lastSeen=", lastSeen

# Update from outside any root (simulating event handler / setTimeout)
sig.val = 42
echo "After update to 42: effectFired=", effectFired, " lastSeen=", lastSeen

sig.val = 100
echo "After update to 100: effectFired=", effectFired, " lastSeen=", lastSeen

assert effectFired == 3, "Expected 3 effect fires (init + 2 updates), got " & $effectFired
assert lastSeen == 100, "Expected lastSeen=100, got " & $lastSeen
echo "SUCCESS: Cross-root reactivity works!"
