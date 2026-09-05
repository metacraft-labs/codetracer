#!/usr/bin/env python3
"""threads — the program CTUI-1's ``threads`` fixture would be recorded from.

READ THIS BEFORE ASSUMING THE FIXTURE EXISTS
--------------------------------------------
CTUI-1 asks for "a genuinely multi-threaded recording for CTUI-6's thread
selector", and explicitly forbids substituting a single-threaded trace and
letting a thread test pass vacuously.  This file is the *program* half of that
fixture.  Whether the *recording* half is obtainable is a question about the
replay stack, not about this program, and the answer is recorded — with the
evidence that established it — in the ``threads`` entry of
``src/frontend/tui/tests/fixtures/fixture_provider.nim``.

The program is kept in the tree even while the fixture is unavailable for two
reasons:

1. the finding is then reproducible by anyone who wants to re-check it, rather
   than being a claim in a comment;
2. when the replay layer grows a real per-thread surface, the fixture becomes
   available by deleting one field in the provider — no new program, no new
   recording procedure to reinvent.

WHAT IT DOES
------------
Four worker threads plus the main thread, each doing enough recorded work to be
visible in a trace, synchronised through a ``Lock`` so the *shared* state is
deterministic even though the interleaving is not.  ``results`` is indexed by
worker id rather than appended to, so the final state does not depend on
completion order: the program's OUTPUT is deterministic while its SCHEDULE is
genuinely concurrent, which is exactly the combination a thread-selector
fixture needs.
"""

import threading

WORKER_COUNT = 4
ITERATIONS = 50

results = [0] * WORKER_COUNT
results_lock = threading.Lock()
start_barrier = threading.Barrier(WORKER_COUNT)


def accumulate(worker_id, iterations):
    """Per-worker arithmetic.  Its own frame, so each thread has a call stack."""
    total = 0
    for step in range(iterations):
        total += worker_id * step + 1
    return total


def worker(worker_id):
    """Thread entry point.

    The barrier is what makes the concurrency real rather than nominal: every
    worker waits until all four have started, so the four threads are provably
    alive at the same time and a recorder that only ever sees one running
    thread is telling us something about the recorder.
    """
    start_barrier.wait()
    total = accumulate(worker_id, ITERATIONS)
    with results_lock:
        results[worker_id] = total
    return total


def main():
    workers = []
    for worker_id in range(WORKER_COUNT):
        thread = threading.Thread(target=worker, args=(worker_id,),
                                  name="worker-%d" % worker_id)
        workers.append(thread)
        thread.start()

    for thread in workers:
        thread.join()

    for worker_id in range(WORKER_COUNT):
        print("worker %d total = %d" % (worker_id, results[worker_id]))
    print("grand total = %d" % sum(results))
    return results


main()
