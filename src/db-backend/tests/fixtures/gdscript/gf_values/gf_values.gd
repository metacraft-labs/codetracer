# CodeTracer GDScript recorder — G4 (Values) reference program.
#
# Deterministic, headless. Run as a Godot main loop:
#   CT_GDSCRIPT_TRACE=<dir> godot --headless --script res://gf_values.gd
#
# Exercises the G4 value-capture pipeline for the COMMON scalar/String types —
# int, float, bool, String, null — plus a reassignment and an argument. The
# recorder captures each WRITTEN named stack slot as a variable value attached
# to the step at that source line. Compiler temporaries are skipped.
#
# Named locals / args and their expected captured values (see EXPECTED-G4.md):
#   scale(factor):              (called with factor = 15)
#     line 30  var received     -> received = 15 (Int; mirrors the passed arg)
#     line 31  factor = factor*2-> factor = 30   (Int; the ARGUMENT, by name)
#   _init():
#     line 35  var i := 10      -> i = 10   (Int)
#     line 36  var f := 2.5     -> f = 2.5  (Float)
#     line 37  var b := true    -> b = true (Bool)
#     line 38  var s := "hi"    -> s = "hi" (String)
#     line 39  var n = null     -> n = null (None)
#     line 40  i = i + 5        -> i = 15   (Int, reassignment)
#     line 41  var r := scale(i)-> r = 30   (Int, return of scale(15))
#
# Deterministic checksum: i + int(f) + r = 15 + 2 + 30 = 47
#   => prints "CT_G4_RESULT=47"

extends MainLoop

func scale(factor):
	var received = factor
	factor = factor * 2
	return factor

func _init():
	var i := 10
	var f := 2.5
	var b := true
	var s := "hi"
	var n = null
	i = i + 5
	var r = scale(i)
	print("CT_G4_RESULT=%d" % (i + int(f) + r))
	# Reference the scalars so no line is dead-code-eliminated.
	if b and s == "hi" and n == null:
		pass

func _process(_delta):
	return true
