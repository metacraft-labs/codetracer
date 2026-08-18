# CodeTracer GDScript recorder — N1 (Nested-Trace Join Keys) reference program.
#
# Deterministic, headless. Recorded UNDER a controlled parent-native context
# (CT_MCR_GEID / CT_MCR_TICK, or a real ct-mcr recording) so the recorder tags
# GDScript call-entry/exit and native-call boundaries with the parent native
# (GEID, tick) join keys — the correlation record defined in
# codetracer-trace-format-spec/nested-trace-correlation.md.
#
#   CT_MCR_GEID=1000 CT_MCR_TICK=500000 CT_GDSCRIPT_TRACE=<dir> \
#     godot --headless --script res://n1_nested.gd
#
# The program exercises all three join SITES:
#   - call-enter / call-exit : the gd->gd call helper(x) (a GDScriptFunction::call
#     frame; its enter/exit joins fire because a step already exists by then).
#   - native-call            : helper() calls native builtin methods on an UNTYPED
#     Array (Array.append / Array.size compile to OPCODE_CALL / method-bind, the
#     native-call opcodes the recorder hooks).
#
# Recorded STANDALONE (no CT_MCR_* and not under ct-mcr) the join-key emission is
# INERT — zero join events — so the trace is byte-identical to a pre-N1 recording.
#
# Deterministic value:
#   helper(10) -> [10, 11], size 2   => c = 2
#   total = x + c = 10 + 2 = 12      => prints "CT_N1_RESULT=12"

extends MainLoop

func helper(n):
	var a = []          # untyped Array
	a.append(n)         # native-call (OPCODE_CALL / method-bind) -> native-call join
	a.append(n + 1)     # native-call -> native-call join
	return a.size()     # native-call -> native-call join; then helper call-exit join

func _init():
	var x = 10          # first executed line -> first step (recording started)
	var c = helper(x)   # helper call-enter join + native-call joins + call-exit join
	var total = x + c   # 10 + 2 = 12
	print("CT_N1_RESULT=%d" % total)

func _process(_delta):
	return true
