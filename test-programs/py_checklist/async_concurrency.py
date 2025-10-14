"""Asyncio, threading, futures, and multiprocessing probes."""

from __future__ import annotations

import asyncio
import contextvars
import multiprocessing as mp
import os
import threading
from concurrent.futures import ThreadPoolExecutor
from typing import Any, List


async def demo_1_async_primitives() -> None:
    """Exercise async context managers, async iterators, and tasks."""

    class AsyncContext:
        async def __aenter__(self) -> "AsyncContext":
            print("1. async-context: enter")
            return self

        async def __aexit__(self, exc_type, exc, tb) -> bool:
            print("1. async-context: exit", exc_type.__name__ if exc_type else None)
            return False  # do not suppress errors.

    class AsyncIter:
        def __init__(self) -> None:
            self.n = 0

        def __aiter__(self) -> "AsyncIter":
            return self

        async def __anext__(self) -> int:
            await asyncio.sleep(0)
            if self.n >= 2:
                raise StopAsyncIteration
            self.n += 1
            return self.n

    async with AsyncContext():
        async for value in AsyncIter():
            print("1a. async-iter:", value)

    async def compute() -> int:
        await asyncio.sleep(0)
        return 42

    task = asyncio.create_task(compute())
    print("1b. task result:", await task)


def demo_2_contextvars() -> None:
    """Context variables isolate async task state."""
    var = contextvars.ContextVar("counter", default=0)

    def bump() -> int:
        var.set(var.get() + 1)
        return var.get()

    values = [bump(), bump()]
    print("2. contextvars:", values)


def demo_3_threads() -> None:
    """Threads with locks and thread-local storage."""
    lock = threading.Lock()
    counter = 0
    tls = threading.local()

    def worker(name: str) -> None:
        nonlocal counter
        tls.calls = getattr(tls, "calls", 0) + 1
        for _ in range(100):
            with lock:
                counter += 1
        print(f"3. thread {name}: tls.calls={tls.calls}")

    threads = [threading.Thread(target=worker, args=(f"t{i}",)) for i in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    print("3b. threads counter:", counter)


def demo_4_thread_pool() -> None:
    """Use concurrent.futures ThreadPoolExecutor."""
    with ThreadPoolExecutor(max_workers=2) as executor:
        future = executor.submit(sum, [1, 2, 3])
        print("4. thread-pool result:", future.result())


def child_process(queue: mp.Queue) -> None:
    """Child process used by demo_5_multiprocessing."""
    queue.put(("pid", os.getpid()))


def demo_5_multiprocessing() -> None:
    """Start a process; guard with __name__ check for Windows safety."""
    queue: mp.Queue[Any] = mp.Queue()
    process = mp.Process(target=child_process, args=(queue,))
    process.start()
    message = queue.get()
    process.join()
    print("5. multiprocessing:", message)


def run_all() -> None:
    """Run all async/concurrency demos; skip multiprocessing if imported."""
    asyncio.run(demo_1_async_primitives())
    demo_2_contextvars()
    demo_3_threads()
    demo_4_thread_pool()
    if __name__ == "__main__":
        # On Windows, the spawn start method re-imports modules, so we only
        # launch child processes when the module is the main entry point.
        demo_5_multiprocessing()
    else:
        print("5. multiprocessing: skipped (imported module)")


if __name__ == "__main__":
    run_all()
