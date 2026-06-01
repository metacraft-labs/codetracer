"""Worked example: binary-search bisect for the first record-vs-replay
divergence (MW47 Phase 3 — MCR cross-trace agentic interface).

The user-described algorithm (verbatim, 2026-06-01):

    "We can do something like binary search.  Capture snapshot at event
    X.  If the snapshots differ, look for divergence earlier.  If the
    snapshots are the same, look later."

This script is the cascade-peeling agent's reference implementation for
that algorithm.  It binary-searches over GEID X by re-recording and
re-replaying the program with the matched ``CT_MEMORY_SNAPSHOT_AT_GEID``
/ ``CT_REPLAY_SNAPSHOT_AT_GEID`` env vars at each iteration, then
asking the daemon (via :meth:`codetracer.Trace.memory_diff_record_vs_replay`)
whether the snapshot pair at the midpoint matches.

Convergence
-----------

Each iteration tests one midpoint.  The window halves regardless of
which branch is taken, so the loop terminates in ``O(log N)`` iterations
where ``N`` is the initial size of the search window.

CLR non-determinism caveat
--------------------------

This script assumes that successive recordings of the same program
produce the same event stream (same GEIDs at the same logical points).
That is the normative MCR contract — per AGENTS.md, "there is no such
thing as a slight divergence".  But a real-world CLR fixture that has
NOT yet had every non-deterministic input captured will produce
diverging event streams across runs.  If that's the case for your
fixture, the bisect may oscillate:

  * iteration k says "snapshots at GEID X match (no divergence yet)"
  * iteration k+1 (narrower window, same logical phase) says "snapshots
    at GEID X differ (divergence happened earlier)"

The agent should watch for adjacent iterations contradicting each
other and bail out with a "fixture is non-deterministic — fix the
missing-capture surface FIRST before bisecting" diagnostic.  We track
``last_result_at_geid`` for exactly this purpose.

Usage
-----

::

    python mcr_record_vs_replay_bisect.py <record_program_cmd> <trace_path> \\
        [lo_geid] [hi_geid] [max_diffs]

where ``<record_program_cmd>`` is a shell command that records the
program once with ``CT_MEMORY_SNAPSHOT_AT_GEID`` and
``CT_REPLAY_SNAPSHOT_AT_GEID`` (etc.) set in the environment, and
``<trace_path>`` is where that command writes its ``.ct`` trace.  The
script substitutes the current bisect midpoint into the env vars then
shells out.

For a real agent the ``re_record_and_replay()`` helper would be a
class method that knows the fixture and the record/verify-replay
harness — the function below shows the contract.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

import codetracer


# ---------------------------------------------------------------------------
# Fixture driver — the interesting part is the env-var contract.
# ---------------------------------------------------------------------------

def re_record_and_replay(record_cmd: str, trace_path: str,
                          replay_snapshot_path: str,
                          geid: int) -> int:
    """Re-record the fixture, then re-replay it, with the snapshot
    GEID gates configured so both runs take exactly one snapshot at
    ``geid``.  Returns the subprocess exit code (0 on success).

    Contract: ``record_cmd`` is a shell command that performs the
    record + verify-replay cycle as one script.  It is invoked with
    these env vars set:

      * ``CT_MEMORY_SNAPSHOT_AT_GEID``       -- the recorder fires
        exactly one ``evMemorySnapshot`` event at this GEID.
      * ``CT_REPLAY_SNAPSHOT_AT_GEID``       -- the replayer takes one
        page-walk snapshot at this GEID.
      * ``CT_REPLAY_SNAPSHOT_OUT_PATH``      -- absolute path the
        replayer writes its standalone snapshot file to (same path
        we pass back to ``memory_diff_record_vs_replay``).

    A real agent's driver may need additional vars (e.g.
    ``CT_LICENSE_DEV_NO_FFI=1`` in our test environment).  Keep them
    in the parent process so they propagate via ``os.environ.copy()``.
    """
    # Always wipe the prior snapshot file so a stale value from an
    # earlier iteration can't mask a successful capture on this run.
    try:
        os.remove(replay_snapshot_path)
    except FileNotFoundError:
        pass
    try:
        os.remove(trace_path)
    except FileNotFoundError:
        pass

    env = os.environ.copy()
    env["CT_MEMORY_SNAPSHOT_AT_GEID"] = str(geid)
    env["CT_REPLAY_SNAPSHOT_AT_GEID"] = str(geid)
    env["CT_REPLAY_SNAPSHOT_OUT_PATH"] = replay_snapshot_path
    print(f"  [iter] re-record+replay with GEID={geid}")
    completed = subprocess.run(record_cmd, shell=True, env=env,
                                capture_output=True, text=True)
    if completed.returncode != 0:
        print(f"  [iter] WARNING: record_cmd exited {completed.returncode}")
        if completed.stderr:
            print(f"  [iter] stderr: {completed.stderr[:400]}")
    return completed.returncode


# ---------------------------------------------------------------------------
# Bisect loop.
# ---------------------------------------------------------------------------

def bisect_first_divergence_record_vs_replay(
    record_cmd: str,
    trace_path: str,
    replay_snapshot_dir: str,
    lo: int,
    hi: int,
    max_diffs: int = 16,
) -> Optional[int]:
    """Binary-search for the first GEID at which the replay diverges
    from the record.

    Each iteration:
      1. mid = (lo + hi) // 2
      2. Re-record + re-replay with ``CT_MEMORY_SNAPSHOT_AT_GEID=mid``
         and ``CT_REPLAY_SNAPSHOT_AT_GEID=mid``.
      3. Open the (new) recorded trace; call
         ``trace.memory_diff_record_vs_replay(snapshot_file, mid)``.
      4. If ``differing_pages > 0`` --> divergence happened at or
         before ``mid``; narrow ``hi = mid``.
         Else --> divergence (if any) is strictly later; ``lo = mid + 1``.

    Returns the smallest GEID at which divergence was observed, or
    ``None`` if no divergence was ever found in ``[lo, hi]``.

    Non-determinism guard: tracks the snapshot-pair outcome at the
    most-recently-tested GEID; if a later iteration revisits the same
    GEID and disagrees, prints a CLR-non-determinism warning and
    returns its best-known answer.
    """
    if lo > hi:
        return None

    # Track the outcome of the previously-tested midpoint so we can
    # detect non-determinism.  Maps GEID -> bool (divergence observed
    # at that GEID).
    seen: dict[int, bool] = {}
    last_divergent: Optional[int] = None

    iteration = 0
    while lo <= hi and iteration < 64:
        iteration += 1
        mid = (lo + hi) // 2
        snapshot_path = os.path.join(
            replay_snapshot_dir,
            f"replay-snapshot-geid-{mid}.bin",
        )
        rc = re_record_and_replay(record_cmd, trace_path, snapshot_path, mid)
        if rc != 0:
            print(f"  [iter {iteration}] record_cmd failed; aborting bisect")
            return last_divergent

        if not os.path.exists(trace_path):
            print(f"  [iter {iteration}] expected trace not produced at {trace_path}")
            return last_divergent
        if not os.path.exists(snapshot_path):
            print(f"  [iter {iteration}] replay snapshot file not produced at "
                  f"{snapshot_path} (CT_REPLAY_SNAPSHOT_AT_GEID gate may not "
                  f"have fired — GEID may be past end-of-trace)")
            # The recorder ran but the replayer never reached GEID=mid.
            # Treat this as "no divergence at mid" and look later
            # (lo = mid + 1) — the bisect window may straddle the end
            # of the recording.
            lo = mid + 1
            continue

        with codetracer.open_trace(trace_path) as trace:
            try:
                result = trace.memory_diff_record_vs_replay(
                    snapshot_path, mid, max_diffs=max_diffs)
            except codetracer.TraceError as e:
                print(f"  [iter {iteration}] diff failed: {e}")
                return last_divergent

        diverged = result.differing_pages > 0
        print(f"  [iter {iteration}] GEID={mid} differingPages="
              f"{result.differing_pages} truncated={result.truncated}"
              f" -> {'DIVERGED' if diverged else 'matched'}")

        # CLR-non-determinism guard.
        if mid in seen and seen[mid] != diverged:
            print(f"  [iter {iteration}] WARNING: GEID {mid} previously"
                  f" reported {'DIVERGED' if seen[mid] else 'matched'} but"
                  f" now reports the opposite.  The fixture appears to be"
                  f" non-deterministic across re-recordings — fix the"
                  f" missing-capture surface BEFORE relying on this bisect.")
            return last_divergent
        seen[mid] = diverged

        if diverged:
            # Show a sample of the divergent pages — useful for the
            # human reading the log.
            for d in result.diffs[:4]:
                print(f"      page #{d.page_index} @ {d.page_va} "
                      f"region={d.region_base} "
                      f"recorded={d.hash_recorded} "
                      f"replayed={d.hash_replayed}")
            last_divergent = mid
            hi = mid - 1
        else:
            lo = mid + 1

    return last_divergent


# ---------------------------------------------------------------------------
# Demo entry point.
# ---------------------------------------------------------------------------

def main() -> int:
    if len(sys.argv) < 3:
        print("usage: mcr_record_vs_replay_bisect.py <record_cmd> <trace_path>"
              " [lo_geid] [hi_geid] [max_diffs]")
        return 2

    record_cmd = sys.argv[1]
    trace_path = sys.argv[2]
    lo = int(sys.argv[3]) if len(sys.argv) >= 4 else 0
    # A modest default upper bound — the fixture's actual event count
    # is usually known to the agent driving this.
    hi = int(sys.argv[4]) if len(sys.argv) >= 5 else 4096
    max_diffs = int(sys.argv[5]) if len(sys.argv) >= 6 else 16

    snapshot_dir = tempfile.mkdtemp(prefix="mcr_rvr_bisect_")
    print(f"binary-searching first record-vs-replay divergence in "
          f"[{lo}, {hi}]; snapshots in {snapshot_dir}")

    first = bisect_first_divergence_record_vs_replay(
        record_cmd, trace_path, snapshot_dir, lo, hi, max_diffs=max_diffs)
    if first is None:
        print("\nno divergence observed in the search window — "
              "the fixture replays byte-equal across this range")
        return 0
    print(f"\n>>> first divergent GEID (within search window): {first} <<<")
    print("Next step: rewind to the prior event boundary with the")
    print("emulator and trace the executed code between that event")
    print("and GEID", first, "to find the missing-capture surface.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
