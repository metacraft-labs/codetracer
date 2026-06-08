"""Worked example: cascade-peeling binary search over MCR memory snapshots.

MW47 Phase 2 — agentic interface to MCR's memory-snapshot diagnostic.

Background
----------

When ``ct-mcr replay-worker`` diverges from the recording (per AGENTS.md,
"there is no such thing as a slight or tolerable divergence"; per
``feedback_mcr_divergence_is_a_bug``, NEVER normalise divergence — fix
the upstream missing capture), the ground-truth localisation technique
is:

1.  Record the program with ``CT_MEMORY_SNAPSHOT_AT_EVENT=1`` so MCR's
    MW47 producer emits an ``evMemorySnapshot`` event into the calling
    thread's per-thread ring at every event boundary.
2.  Replay the same program with the same env var: each replay-side
    snapshot lands at the SAME GEID as its record-side counterpart
    (Castor epoch ordering — per
    ``feedback_mcr_sideband_is_per_ring_spill``, the per-thread rings
    drain in deterministic GEID order).
3.  Bisect: find the earliest GEID at which the recorded page hashes
    diverge.  The code that ran between the previous snapshot event and
    that one is the missing-capture surface — that is the new
    instrumentation site MCR needs to add (CLR profiler / vDSO / ntdll
    detour / inline patch, depending on the surface).

This script is the **worked example** future cascade-peeling agents
will copy.  It demonstrates the full bisect using only the public
:meth:`codetracer.Trace.memory_diff` Python API — NO ``ct-mcr`` CLI
subcommand, NO direct ``.ct`` file parsing.  The agentic interface is
the only entry point (see ``feedback_codetracer_agentic_interface``).

In practice, you run this script ONCE against the recorded trace and
again against the replay trace (or two separate recorded traces, if
you're trying to localise a non-deterministic difference between two
runs of the same program).  The ``first_divergence_event_geid`` field
of the result tells you which event to inspect next with the emulator.

Usage
-----

::

    python mcr_memory_diff_bisect.py <trace.ct> [max_diffs]

If ``max_diffs`` is omitted, defaults to 16 (the per-call API cap; the
``differing_pages`` field always reports the true total).
"""

from __future__ import annotations

import sys
from typing import Optional

import codetracer


def list_snapshot_geids(trace: codetracer.Trace) -> list[int]:
    """Enumerate every ``evMemorySnapshot`` GEID in the trace.

    Implementation note: we shell out via ``trace.memory_diff(0, 0)`` to
    get the helper to enumerate snapshots for us.  The first invocation
    surfaces ``snapshotsInRange`` (counted from 0) so we know how many
    snapshots exist.  In practice the agent passes the endpoint GEIDs
    directly — this enumeration is just for the demo.
    """
    # The helper accepts equal endpoints (snapshot vs itself) and
    # returns the count of snapshots in [a..a] = 1, but we want the
    # full count.  Instead, we ask for diff(min, max) of a guessed wide
    # range and look at snapshotsInRange.  For very large traces an
    # agent should call trace.events() with type_filter='memory-snapshot'
    # — but that requires backend support not yet wired (see spec).
    #
    # For now: the helper itself can be invoked with eventA == eventB
    # to fetch the in-trace GEID list via the error path, but the cleanest
    # demonstration is to pass an absurdly large eventB and let the
    # error message surface the available GEIDs.  We keep this simple:
    # rely on the caller to pass two known endpoints.
    raise NotImplementedError(
        "enumeration not implemented in the agent demo — call "
        "trace.memory_diff(a, b) with known endpoints"
    )


def bisect_first_divergence(
    trace: codetracer.Trace,
    lo: int,
    hi: int,
    max_diffs: int = 16,
) -> Optional[codetracer.MemoryDiffResult]:
    """Binary-search down to the earliest divergent snapshot in (lo, hi].

    The helper does the heavy lifting: each call to
    :meth:`codetracer.Trace.memory_diff` returns
    ``first_divergence_event_geid`` — the GEID of the *earliest*
    snapshot in ``(lo, hi]`` whose page hashes differ from the snapshot
    at ``lo``.  We then narrow the upper bound to that GEID, re-run the
    diff (now against a tighter window), and repeat until the diff
    against ``[lo, hi]`` reports the same first divergence as
    ``[lo, lo+1]`` (i.e. no further refinement is possible).

    Because each call already does an O(snapshots-in-range) walk on the
    helper side, this loop typically converges in 1–3 iterations even
    on traces with millions of snapshots.  The bisect is here as
    illustration — for the most common case ``first_divergence_event_geid``
    from a single call is the answer.

    Returns the final :class:`codetracer.MemoryDiffResult`, or ``None``
    if no divergence was found between ``lo`` and ``hi``.
    """
    last_result: Optional[codetracer.MemoryDiffResult] = None
    current_hi = hi
    for iteration in range(64):  # safety cap on iterations
        print(
            f"[bisect iter {iteration}] memory_diff(lo={lo}, hi={current_hi}, "
            f"max_diffs={max_diffs})"
        )
        result = trace.memory_diff(lo, current_hi, max_diffs=max_diffs)
        print(
            f"  -> snapshotsInRange={result.snapshots_in_range} "
            f"pagesCompared={result.pages_compared} "
            f"differingPages={result.differing_pages} "
            f"firstDivergenceEventGeid={result.first_divergence_event_geid}"
        )
        if result.first_divergence_event_geid < 0:
            # No divergence in this window — done.
            return last_result
        if (
            last_result is not None
            and result.first_divergence_event_geid
            == last_result.first_divergence_event_geid
        ):
            # Same first-divergence point as last iteration: we have
            # converged.  Return the most refined result.
            return result
        last_result = result
        # Narrow the search window.  Move ``hi`` to the reported first
        # divergence; the next iteration will look in (lo, new_hi].
        # This is a single-sided narrowing because the helper already
        # tells us the earliest divergent snapshot — no need to bisect
        # the lower half.
        current_hi = result.first_divergence_event_geid
        if current_hi <= lo + 1:
            # Adjacent snapshots: we cannot narrow further.
            return result
    return last_result


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: mcr_memory_diff_bisect.py <trace.ct> [max_diffs]")
        return 2

    trace_path = sys.argv[1]
    max_diffs = int(sys.argv[2]) if len(sys.argv) >= 3 else 16

    with codetracer.open_trace(trace_path) as trace:
        # In a real cascade-peeling session the agent already knows two
        # candidate endpoints — e.g. the GEID right after process start
        # and a GEID near where the divergence symptom is observed.
        # For the demo we use GEID 0 (typically the first recorded
        # snapshot in process startup) and ``trace.total_events`` as a
        # loose upper bound.  The helper resolves both to actual
        # snapshot GEIDs; if the upper GEID isn't itself a snapshot,
        # we'll get an error pointing to the correct one.
        lo = 0
        hi = max(1, trace.total_events - 1)

        # Single shot — most cases need nothing more.
        print("=== single-shot memory_diff ===")
        single = trace.memory_diff(lo, hi, max_diffs=max_diffs)
        print(f"  eventA={single.event_a} eventB={single.event_b}")
        print(f"  snapshotsInRange={single.snapshots_in_range}")
        print(f"  pagesCompared={single.pages_compared}")
        print(f"  differingPages={single.differing_pages}")
        print(f"  truncated={single.truncated}")
        print(f"  firstDivergenceEventGeid={single.first_divergence_event_geid}")
        for d in single.diffs[:8]:  # cap the demo's stdout
            print(
                f"    page #{d.page_index} @ {d.page_va} "
                f"region={d.region_base} prot={d.region_protect:#x} "
                f"recorded={d.hash_recorded} replayed={d.hash_replayed}"
            )

        if single.first_divergence_event_geid < 0:
            print("no divergence detected — trace is internally consistent")
            return 0

        # Multi-iteration bisect (illustrative; usually no extra
        # iterations are needed because ``first_divergence_event_geid``
        # is already the precise answer).
        print("\n=== bisect_first_divergence ===")
        final = bisect_first_divergence(trace, lo, hi, max_diffs=max_diffs)
        if final is None:
            print("bisect returned no divergence (unexpected — see single-shot output)")
            return 0
        print(
            f"\n>>> missing-capture surface ran BETWEEN snapshot GEIDs "
            f"{lo} and {final.first_divergence_event_geid} <<<"
        )
        print(
            "Next step: rewind to the prior snapshot event with the emulator and "
            "carefully trace the executed code with all live threads to find the "
            "race that produced the unrecorded write."
        )
        return 0


if __name__ == "__main__":
    sys.exit(main())
