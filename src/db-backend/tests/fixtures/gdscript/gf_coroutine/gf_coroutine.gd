# CodeTracer GDScript recorder — GF10 (Coroutines & `await`, async-continuation
# integration) reference program.
#
# Deterministic, headless. Run as a Godot main loop:
#   CT_GDSCRIPT_TRACE=<dir> godot --headless --script res://gf_coroutine.gd
#
# `--script` requires the entry to inherit SceneTree / MainLoop. A user `signal`
# declared on the SceneTree instance can be `await`ed and emitted a frame later
# from `_process`, so the suspend/resume path runs for real headless.
#
# WHAT GF10 PROVES (this milestone DOES change the recorder — two new VM hooks):
# GDScript `await` on a Signal makes GDScriptFunction::call RETURN early with a
# GDScriptFunctionState (the CallState `p_state`); the matching resume re-enters
# call() with that SAME CallState. The recorder emits a SUSPEND marker at the
# await step and a RESUME marker at the first resumed line, both carrying
# context_id = the CallState pointer, so the db-backend pairs them into a
# ContinuationLink (link_type "await"). Call/return stays BALANCED across the
# yield (G3 unchanged: one enter/exit per call() invocation), and the coroutine's
# locals survive the suspension with their pre-await values on resume.
#
# TWO awaits are exercised, producing TWO continuation links:
#   A) `await go`      — await a SIGNAL    (inside work())      → signal-await link
#   B) `await work()`  — await a COROUTINE (inside _initialize) → coroutine link
# GDScript requires a coroutine call to be `await`ed directly, so B cannot split
# the call and the await onto separate lines.
#
# Deterministic result (hand-derived; see scripts/EXPECTED-GF10.md):
#   work(): base=10, await go (suspends), resumes with payload=32,
#           kept = base = 10 (proves the pre-await local survived),
#           result = kept + payload = 42, returns 42.
#   _initialize(): r = await work() = 42, check = r = 42.
#   => prints "CT_GF10_RESULT=42"

extends SceneTree

signal go(payload)                  # GF10: a user signal awaited by work()

var frames := 0

# Coroutine: does steps, awaits a SIGNAL, then returns 42. `base` is set BEFORE
# the await and read AFTER it (into `kept`), directly proving locals survive the
# suspension. Distinct line numbers keep each captured value crisp.
func work() -> int:
	var base := 10                  # pre-await local
	var payload: int = await go     # SUSPEND on signal `go`; payload bound on resume
	var kept := base                # RESUME line — reads surviving base (==10)
	var result := kept + payload    # 10 + 32 = 42
	return result

func _initialize() -> void:
	var r: int = await work()       # AWAIT the coroutine work()
	var check := r                  # RESUME line — r == 42 after the join
	print("CT_GF10_RESULT=%d" % check)
	quit()

func _process(_delta: float) -> bool:
	frames += 1
	if frames == 2:
		go.emit(32)                 # emit the awaited signal a frame later
	if frames >= 6:
		quit()                      # safety net so the loop never hangs headless
	return false                    # keep the main loop running until quit()
