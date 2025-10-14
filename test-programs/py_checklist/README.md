# Python Checklist Test Programs

This suite mirrors the `ruby_checklist` sample by collecting small,
targeted probes that exercise diverse areas of the Python language and
standard library. The code is intentionally verbose and heavily
commented so that engineers working across multiple languages can
quickly understand what a probe demonstrates and why it matters.

## Goals

- Capture representative call stacks for critical Python features so the
  debugger and tracer integrations can be validated.
- Provide ready-made snippets that illustrate specific language
  behaviors, pitfalls, and idioms for reference during development.
- Keep each probe independent and side-effect light so they can run in
  isolation without hidden dependencies.

## Organization

- Minimum Python version: **3.11**. This allows us to cover structural
  pattern matching, `except*` for exception groups, and other
  post-3.10 features without fallbacks.
- Each feature cluster lives in its own module (for example,
  `basics.py`, `functions_exceptions.py`, …). Modules should export
  numbered `demo_*` functions that focus on a single behavior.
- A top-level `run_all()` function inside each module executes its demos
  sequentially, printing numbered lines so missed events are easy to
  spot in traces.
- Inline comments and docstrings must explain **what** the snippet does,
  **why** someone would use it, and any common gotchas.
- Helpers that spin up threads or processes must protect their entry
  points with `if __name__ == "__main__":` to stay portable across
  platforms (especially Windows).

## Feature Coverage

| Area | Modules / Demos | Notes |
| --- | --- | --- |
| Literals, operators, control flow | `basics.run_all()` | Covers literals, slicing, unpacking, match/case, loop `else`. |
| Functions, decorators, exceptions | `functions_exceptions.run_all()` | Demonstrates call signatures, mutable defaults, closures, decorator stacking, caching, chained exceptions, `ExceptionGroup`. |
| Context managers & iterators | `contexts_iterators.run_all()` | Custom `__enter__/__exit__`, `contextlib`, iterator protocol, generators with `send`/`throw`/`close`. |
| Async & concurrency | `async_concurrency.run_all()` | Async context/iter, `create_task`, contextvars, threading/TLS, `ThreadPoolExecutor`, guarded multiprocessing. |
| Data model & classes | `data_model.run_all()` | `__repr__`, formatting, rich ops, properties with `__slots__`, attribute hooks, descriptors, subclass hooks, metaclass lifecycle. |
| Collections & dataclasses | `collections_dataclasses.run_all()` | Dataclasses with slots/order, enums and flags, namedtuple/deque/defaultdict/Counter, mapping proxy, pattern matching with `__match_args__`. |
| System utilities | `system_utils.run_all()` | `subprocess.run` with env overrides, tz-aware datetime math, `Decimal`/`Fraction`, deterministic random, regex capture groups. |
| Introspection & dynamic code | `introspection.run_all()` | `inspect.signature`, dynamic attributes, globals/locals snapshots, `eval`/`exec`/`compile`, AST parse/dump (with security notes in comments). |
| Import system | `imports_demo.run_all()` | Runtime module creation via `types.ModuleType`, adjusting `sys.path`, `importlib.import_module`, `__all__`, module caching notes. |
| Logging, warnings, GC, typing | `advanced_runtime.run_all()` | Scoped logging config, forced warnings, GC cycle collection with weakrefs/finalizers, runtime protocol checks, generics. |
| Miscellaneous constructs | `miscellaneous.run_all()` | `iter(callable, sentinel)`, `del`, custom mapping protocol, context manager without suppression. |

> **Planned additions:** Remaining entries from the original checklist
> (I/O & serialization, subprocess variants, JSON/pickle, etc.) can be
> layered in by following the same pattern—add `<topic>.py`, expose
> `run_all()`, then register it in `__main__.py`.

## Running The Suite

Once all modules are implemented, you will be able to run the entire
checklist from the project root:

```bash
python -m test-programs.python_checklist
```

During early development, it is fine to run individual modules directly
with `python test-programs/python_checklist/<module>.py` to iterate on a
specific feature cluster.

## Contribution Guidelines

- Follow the numbering scheme diligently so console output gaps surface
  immediately.
- Prefer deterministic behavior (avoid randomness unless the purpose is
  to exercise the random module).
- Clean up temporary files, subprocesses, and other resources within the
  probe itself. Each demo should leave the environment in the same state
  it found it.
- If a snippet showcases risky behavior (e.g., `eval`), highlight the
  security implications in comments.

This structure keeps the checklist maintainable and allows future
contributors to plug in additional probes without surprising teammates.
