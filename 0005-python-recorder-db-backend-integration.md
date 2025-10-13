# ADR 0005: Wire the Rust/PyO3 Python Recorder into the Codetracer DB Backend

- **Status:** Proposed
- **Date:** 2025-10-09
- **Deciders:** Codetracer Runtime & Tooling Leads
- **Consulted:** Desktop Packaging, Python Platform WG, Release Engineering
- **Informed:** Developer Experience, Support, Product Management

## Context

We now have a Rust-based `codetracer_python_recorder` PyO3 extension that captures Python execution through `sys.monitoring` and emits the `runtime_tracing` event stream (`libs/codetracer-python-recorder/codetracer-python-recorder/src/lib.rs`). The module ships with a thin Python façade (`codetracer_python_recorder/session.py`) and is intended to become the canonical recorder for Python users.

Inside the desktop Codetracer distribution, the `ct record` workflow still routes Python scripts through the legacy rr-based backend. That path is not portable across platforms, diverges from the new recorder API, and prevents us from delivering a unified CLI experience. Today only Ruby/Noir/WASM go through the self-contained db-backend (`src/ct/db_backend_record.nim`), so Python recordings inside the desktop app do not benefit from the same trace schema, caching, or upload flow. More importantly, developers expect `ct record foo.py` to behave exactly like `python foo.py` (or inside wrappers such as `uv run python foo.py`), reusing the same interpreter, virtual environment, and installed dependencies.

To ship a single CLI/UI (`ct record`, `ct upload`) regardless of installation method, we must integrate the Rust-backed Python recorder into the db-backend flow used by other languages. Instead of bundling the wheel inside every Codetracer distribution, we expect developers to install `codetracer_python_recorder` in the interpreter environment they use for their projects. The CLI therefore has to discover the active interpreter, verify that the module is available, provide actionable guidance when it is not, and still import traces through the same sqlite pipeline used by Ruby.

## Decision

We will treat Python as a db-backend language inside Codetracer by adding a Python-specific launcher that invokes the PyO3 module already installed in the user’s interpreter, streams traces into the standard `trace.json`/`trace_metadata.json` format, and imports the results via `importDbTrace`.

1. **Introduce `LangPythonDb`:** Extend `Lang` to include a db-backed variant for Python (`LangPythonDb`), mark it as db-based, and update language detection so `.py` scripts resolve to this enum whenever the recorder can be imported.
2. **Rely on a User-Managed Recorder Wheel:** Publish and maintain the `codetracer_python_recorder` wheel so users can install or upgrade it with their chosen tooling (`pip`, `uv`, virtualenv managers). Codetracer releases do not bundle the wheel; instead, the CLI checks for it and explains how to obtain it.
3. **CLI Invocation & Environment Parity:** Update `recordDb` so when `lang == LangPythonDb` it launches the *same* Python that the user’s shell would resolve for `python`/`python3` (or whatever interpreter is on `$PATH` inside wrappers such as `uv run`). The command will execute `-m codetracer_python_recorder` (or an equivalent entry point) inside the caller’s environment so that site-packages, virtualenvs, and tool-managed setups behave identically. If no interpreter is available, we surface the same error the user would see when running `python`, rather than falling back to a bundled runtime.
4. **Configuration Parity:** Respect the same flags (`--with-diff`, activation scopes, environment auto-start) by translating CLI options into recorder arguments/env vars, and inherit all user environment variables untouched. The db backend will continue to populate sqlite indices and cached metadata as it does for Ruby.
5. **Guidance & Diagnostics:** Provide clear documentation, CLI help, and error messaging that explain how to install the recorder wheel, how interpreter resolution works, and how to remediate missing-module scenarios. Installers simply place the `ct` CLI on PATH; they no longer patch `PYTHONPATH` or ship auxiliary launchers.
6. **Failure Behaviour:** When interpreter discovery or module import fails, surface a structured error that matches what the user would experience running `python myscript.py`, along with remediation steps (e.g., install `codetracer_python_recorder`). The expectation is parity—if their environment cannot run the script, neither can `ct record`.

This decision establishes the db-backend as the single ingestion interface for Codetracer traces, simplifying future features such as diff attachment, uploads, and analytics.

## Alternatives Considered

- **Keep Python on the rr backend:** Rejected because rr is not available on Windows/macOS ARM, adds heavyweight dependencies, and diverges from the new recorder capabilities (sys.monitoring, value capture).
- **Call the PyO3 recorder directly from Nim:** Rejected; embedding Python within the Nim process complicates packaging, GIL management, and conflicts with the existing external-process model used for other languages.
- **Ship separate Python-only bundles:** Rejected; it increases cognitive load and contradicts the goal of a unified `ct` CLI regardless of installation method.

## Consequences

- **Positive:** One recorder path across install surfaces, easier support and docs, leverage db-backend import tooling (diffs, uploads, cache), and users keep their existing interpreter/virtualenv semantics when invoking `ct record`. Avoiding bundled wheels simplifies desktop packaging and reduces installer size.
- **Negative:** We now depend on developers to install or update `codetracer_python_recorder` themselves, making documentation and diagnostics critical. Interpreter discovery still adds complexity when respecting arbitrary `python` shims (`uv run`, pyenv, poetry).
- **Risks & Mitigations:** Missing or outdated wheels become user-facing errors—mitigate with preflight checks, actionable documentation, and automated tests that exercise typical package-manager flows. Interpreter mismatch remains the user’s responsibility; we provide clear diagnostics and docs on supported Python versions.

## Key locations

- `src/common/common_lang.nim` – add `LangPythonDb`, update `IS_DB_BASED`, and adapt language detection.
- `src/ct/trace/record.nim` – route Python recordings to `dbBackendRecordExe` and pass through recorder-specific arguments.
- `src/ct/db_backend_record.nim` – add a `LangPythonDb` branch that launches the user’s interpreter against `codetracer_python_recorder` and imports the generated trace.
- `src/db-backend/src` – adjust import logic if additional metadata fields are required for Python traces.
- `libs/codetracer-python-recorder/**` – build configuration, PyO3 module entry points, and CLI wrappers that will be invoked by `ct record`.
- `docs/**` & CLI help – explain installation prerequisites, environment discovery, and troubleshooting guidance for Python recordings.
- `CI workflows` – exercise `ct record` inside virtual environments where the wheel is installed through normal package managers.

## Implementation Notes

1. Publish and verify `codetracer_python_recorder` wheels for the platforms we support, ensuring they remain installable from PyPI (or our internal index).
2. Extend `recordDb` with a Python branch that discovers the interpreter (`env["PYTHON"]`, `which python`, activated `sys.executable` within wrappers) and invokes the module with activation paths, output directories, and user arguments. If discovery fails, return an error mirroring `python`’s behaviour (e.g., “command not found”).
3. Add a preflight import check for `codetracer_python_recorder` so we can emit actionable remediation guidance before launching the recording process.
4. Update trace import tests to cover Python recordings end-to-end, ensuring sqlite metadata matches expectations.
5. Modify CLI help (`ct record --help`), docs, and release notes to note the external dependency and explain interpreter parity expectations.

## Status & Next Steps

- Draft ADR for feedback (this document).
- Validate the user-managed wheel flow by recording sample scripts inside virtual environments on each platform.
- Once validated, mark this ADR **Accepted** and schedule the code changes behind a feature flag for phased rollout.
