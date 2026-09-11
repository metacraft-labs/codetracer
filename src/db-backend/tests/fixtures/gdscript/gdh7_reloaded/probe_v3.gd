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
#
# ===========================================================================
# VERSION 3 — the source generation 3 installed, mid-run.
#
# This file is probe_v1.gd with an INERT BLOCK INSERTED ABOVE `func probe`,
# and NOTHING ELSE MOVED.  Everything from the insertion down is shifted by
# exactly the block's height, which is the property GDH-M0 required and this
# milestone inherits: a post-reload step's line number must not exist in the
# PREVIOUS version's text at all, so a consumer that resolves the recorded
# path to the single source view an unversioned container carries is not
# merely showing the wrong line — it is being asked for a line the file it
# has does not reach.
#
# The block is comments only, so the shift is purely positional and no new
# behaviour is confounded with it.  Its HEIGHT is never written into a
# verifier: `verify_gdh6.py` derives every probe line number by scanning each
# fixture for the token literals, and refuses to run if a literal disagrees
# with the line it sits on.
#
# This version has 5 probe lines — deliberately a different number from
# every other version, so the expected step count is a SUM over versions and
# not a flat product.
# ===========================================================================
extends MainLoop

const TICK_MS := 60
const TICKS := 30

var tick := 0
static var counter := 4242

func _initialize() -> void:
	print("GDH6_BEGIN")

# ======================================================================
# v3 insertion line 1 of 40 — inert.
# v3 insertion line 2 of 40 — inert.
# v3 insertion line 3 of 40 — inert.
# v3 insertion line 4 of 40 — inert.
# v3 insertion line 5 of 40 — inert.
# v3 insertion line 6 of 40 — inert.
# v3 insertion line 7 of 40 — inert.
# v3 insertion line 8 of 40 — inert.
# v3 insertion line 9 of 40 — inert.
# v3 insertion line 10 of 40 — inert.
# v3 insertion line 11 of 40 — inert.
# v3 insertion line 12 of 40 — inert.
# v3 insertion line 13 of 40 — inert.
# v3 insertion line 14 of 40 — inert.
# v3 insertion line 15 of 40 — inert.
# v3 insertion line 16 of 40 — inert.
# v3 insertion line 17 of 40 — inert.
# v3 insertion line 18 of 40 — inert.
# v3 insertion line 19 of 40 — inert.
# v3 insertion line 20 of 40 — inert.
# v3 insertion line 21 of 40 — inert.
# v3 insertion line 22 of 40 — inert.
# v3 insertion line 23 of 40 — inert.
# v3 insertion line 24 of 40 — inert.
# v3 insertion line 25 of 40 — inert.
# v3 insertion line 26 of 40 — inert.
# v3 insertion line 27 of 40 — inert.
# v3 insertion line 28 of 40 — inert.
# v3 insertion line 29 of 40 — inert.
# v3 insertion line 30 of 40 — inert.
# v3 insertion line 31 of 40 — inert.
# v3 insertion line 32 of 40 — inert.
# v3 insertion line 33 of 40 — inert.
# v3 insertion line 34 of 40 — inert.
# v3 insertion line 35 of 40 — inert.
# v3 insertion line 36 of 40 — inert.
# v3 insertion line 37 of 40 — inert.
# v3 insertion line 38 of 40 — inert.
# v3 insertion line 39 of 40 — inert.
# v3 insertion line 40 of 40 — inert.
# ======================================================================
func probe(n: int) -> void:
	print("GDH6|it=", n, "|v=3|L=120|")  # v3 probe 1 of 5
	print("GDH6|it=", n, "|v=3|L=121|")  # v3 probe 2 of 5
	print("GDH6|it=", n, "|v=3|L=122|")  # v3 probe 3 of 5
	print("GDH6|it=", n, "|v=3|L=123|")  # v3 probe 4 of 5
	print("GDH6|it=", n, "|v=3|L=124|")  # v3 probe 5 of 5

func _process(_delta: float) -> bool:
	tick += 1
	probe(tick)
	print("GDH6_TICK=", tick, " ")
	print("GDH6_STATIC=", counter, " ")
	OS.delay_msec(TICK_MS)
	return tick >= TICKS

func _finalize() -> void:
	print("GDH6_END")
