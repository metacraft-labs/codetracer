# GDH6 probe — VERSION 1.  The source the process STARTS with (generation 1).
#
# scripts/record-and-verify-gdh6.sh copies this file to `probe.gd` in a scratch
# project, runs it headless under CT_GDSCRIPT_TRACE with the in-target HCR
# agent connected, and part-way through the run hands the engine probe_v2.gd
# and then probe_v3.gd over the agent's `sourceChanged` notification.  TWO
# reloads, one program, one container.
#
# THE TOKEN.  Every probe line prints exactly one token:
#
#     GDH6|it=<iteration>|v=<version>|L=<line>|
#
# `<line>` is the 1-based line number of the `print` statement THAT EMITTED IT,
# as this version's file has it.  GDScript has no `__LINE__`, so the number is
# written by hand — and `verify_gdh6.py` re-derives every one of them by
# scanning this file and REFUSES to run if a literal disagrees with the line it
# sits on.  A fixture edit that shifts a probe therefore fails loudly instead of
# quietly re-defining what the gate compares.
#
# The trailing `|` is not decoration.  `L=4` must not match `L=40`, and
# `it=1` must not match `it=12`; the same rule EXPECTED-HCR1.md's marker uses.
#
# THREE PROPERTIES THIS VERSION MUST HAVE, each asserted by the harness rather
# than trusted:
#
#   (i)   its probe LINE NUMBERS are disjoint from v2's and v3's.  Without that
#         "the step decoded to line N" would not identify a version and the
#         gate would silently degrade to a line-number check;
#   (ii)  its probe lines' SOURCE TEXT differs from the other versions' at
#         every compared line, so "the retrieved source view has the right text
#         at that line" is a real discrimination rather than two versions
#         agreeing for free;
#   (iii) it has a DIFFERENT NUMBER of probe lines from v2 and v3 (3 here, 4 in
#         v2, 5 in v3).  The expected step count is then a sum over versions of
#         (iterations live x that version's probe-line count) and cannot be
#         written as a flat product — which is what stops the harness from
#         agreeing with a trace that lost a whole version's worth of steps.
#
# Every printed value is deterministic: no clock, no RNG, no host-dependent
# value.  The tick delay exists so the driver has a real window in which to
# deliver each reload; without it the program finishes in ~0.1 s and both
# reloads land after the run is over.
extends MainLoop

const TICK_MS := 60
const TICKS := 30

var tick := 0
static var counter := 4242

func _initialize() -> void:
	print("GDH6_BEGIN")

func probe(n: int) -> void:
	print("GDH6|it=", n, "|v=1|L=55|")
	print("GDH6|it=", n, "|v=1|L=56|")
	print("GDH6|it=", n, "|v=1|L=57|")

func _process(_delta: float) -> bool:
	tick += 1
	probe(tick)
	print("GDH6_TICK=", tick, " ")
	print("GDH6_STATIC=", counter, " ")
	OS.delay_msec(TICK_MS)
	return tick >= TICKS

func _finalize() -> void:
	print("GDH6_END")
