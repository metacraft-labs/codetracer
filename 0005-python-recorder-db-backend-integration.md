# ADR 0005: Wire the Rust/PyO3 Python Recorder into the Codetracer DB Backend

- **Status:** Proposed
- **Date:** 2025-10-09
- **Deciders:** Codetracer Runtime & Tooling Leads
- **Consulted:** Desktop Packaging, Python Platform WG, Release Engineering
- **Informed:** Developer Experience, Support, Product Management

## Context

We now have a Rust-based `codetracer_python_recorder` PyO3 extension that captures Python execution through `sys.monitoring` and emits the `runtime_tracing` event stream (`libs/codetracer-python-recorder/codetracer-python-recorder/src/lib.rs`). The module ships with a thin Python façade (`codetracer_python_recorder/session.py`) and is intended to become the canonical recorder for Python users.

Inside the desktop Codetracer distribution, the `ct record` workflow still routes Python scripts through the legacy rr-based backend. That path is not portable across platforms, diverges from the new recorder API, and prevents us from delivering a unified CLI experience. Today only Ruby/Noir/WASM go through the self-contained db-backend (`src/ct/db_backend_record.nim`), so Python recordings inside the desktop app do not benefit from the same trace schema, caching, or upload flow. More importantly, developers expect `ct record foo.py` to behave exactly like `python foo.py` (or inside wrappers such as `uv run python foo.py`), reusing the same interpreter, virtual environment, and installed dependencies.

To ship a single CLI/UI (`ct record`, `ct upload`) regardless of installation method, we must integrate the Rust-backed Python recorder into the db-backend flow used by other languages. The integration needs to ensure the recorder lives inside the desktop bundle (AppImage, DMG, upcoming Windows installer), the CLI resolves it without virtualenvs, and traces are imported via the same sqlite pipeline as Ruby.

## Decision

We will treat Python as a db-backend language inside Codetracer by adding a Python-specific launcher that invokes the PyO3 module, streams traces into the standard `trace.json`/`trace_metadata.json` format, and imports the results via `importDbTrace`.

1. **Introduce `LangPythonDb`:** Extend `Lang` to include a db-backed variant for Python (`LangPythonDb`), mark it as db-based, and update language detection so `.py` scripts resolve to this enum when the bundled recorder is available.
2. **Bundle the Recorder Wheel:** During desktop builds (AppImage, DMG, future Windows installer) compile the `codetracer_python_recorder` wheel via maturin and ship it inside the distribution alongside its Python shims. Provide a small launcher script (`ct-python-recorder`) that lives next to the CLI binaries.
3. **CLI Invocation & Environment Parity:** Update `recordDb` so when `lang == LangPythonDb` it launches the *same* Python that the user’s shell would resolve for `python`/`python3` (or whatever interpreter is on `$PATH` inside wrappers such as `uv run`). The command will execute `-m codetracer_python_recorder` (or an equivalent entry point) inside the caller’s environment so that site-packages, virtualenvs, and tool-managed setups behave identically. If no interpreter is available, we surface the same error the user would see when running `python`, rather than falling back to a bundled runtime.
4. **Configuration Parity:** Respect the same flags (`--with-diff`, activation scopes, environment auto-start) by translating CLI options into recorder arguments/env vars, and inherit all user environment variables untouched. The db backend will continue to populate sqlite indices and cached metadata as it does for Ruby.
5. **Installer Hooks:** Ensure the bundled CLI exposes the recorder module without overriding interpreter discovery. Wrapper scripts should add our wheel to `PYTHONPATH` (or `CODERTRACER_RECORDER_PATH`) while deferring to the interpreter already active in the user’s shell (`uv`, `pipx`, virtualenv). On macOS/Linux this happens via scripts created by `installCodetracerOnPath`; the Windows installer will register similar shims. We will not ship a backup interpreter for unmatched environments.
6. **Failure Behaviour:** When interpreter discovery or module import fails, surface a structured error that matches what the user would experience running `python myscript.py`. The expectation is parity—if their environment cannot run the script, neither can `ct record`.

This decision establishes the db-backend as the single ingestion interface for Codetracer traces, simplifying future features such as diff attachment, uploads, and analytics.

## Alternatives Considered

- **Keep Python on the rr backend:** Rejected because rr is not available on Windows/macOS ARM, adds heavyweight dependencies, and diverges from the new recorder capabilities (sys.monitoring, value capture).
- **Call the PyO3 recorder directly from Nim:** Rejected; embedding Python within the Nim process complicates packaging, GIL management, and conflicts with the existing external-process model used for other languages.
- **Ship separate Python-only bundles:** Rejected; it increases cognitive load and contradicts the goal of a unified `ct` CLI regardless of installation method.

## Consequences

- **Positive:** One recorder path across install surfaces, easier support and docs, leverage db-backend import tooling (diffs, uploads, cache), and users keep their existing interpreter/virtualenv semantics when invoking `ct record`. Packaging the wheel centralizes updates and keeps the CLI consistent with the pip experience.
- **Negative:** Desktop builds gain a maturin build step (longer CI), and we assume responsibility for distributing the PyO3 wheel across platforms. Interpreter discovery adds complexity when respecting arbitrary `python` shims (`uv run`, pyenv, poetry). Without a bundled fallback interpreter, misconfigured environments will fail fast and require user fixes.
- **Risks & Mitigations:** Wheel build failures will block installer pipelines—mitigate with cached artifacts and CI smoke tests. Interpreter mismatch remains the user’s responsibility; we provide clear diagnostics and docs on supported Python versions.

## Key locations

- `src/common/common_lang.nim` – add `LangPythonDb`, update `IS_DB_BASED`, and adapt language detection.
- `src/ct/trace/record.nim` – route Python recordings to `dbBackendRecordExe` and pass through recorder-specific arguments.
- `src/ct/db_backend_record.nim` – add a `LangPythonDb` branch that launches the embedded Python recorder CLI and imports the generated trace.
- `src/db-backend/src` – adjust import logic if additional metadata fields are required for Python traces.
- `libs/codetracer-python-recorder/**` – build configuration, PyO3 module entry points, and CLI wrappers that will be invoked by `ct record`.
- `appimage-scripts/` & `non-nix-build/` – package the Python recorder wheel into Linux/macOS distributions and expose the runner.
- `nix/**` & CI workflows – ensure development shells and pipelines can build the wheel and make it available to the desktop bundle.

## Implementation Notes

1. Create a maturin build step in installer pipelines that outputs wheels for the target platform and stage them under `resources/python/`.
2. Add a tiny launcher script (e.g., `bin/ct-python-recorder`) that amends `PYTHONPATH` to include the bundled wheel but defers to the interpreter in `$PATH` so wrappers like `uv run` or virtualenv activation continue to work—no backup interpreter is provided.
3. Extend `recordDb` with a Python branch that discovers the interpreter (`env["PYTHON"]`, `which python`, activated `sys.executable` within wrappers) and invokes the launcher with activation paths, output directories, and user arguments. If discovery fails, return an error mirroring `python`’s behaviour (e.g., “command not found”).
4. Update trace import tests to cover Python recordings end-to-end, ensuring sqlite metadata matches expectations.
5. Modify CLI help (`ct record --help`) and docs to note that Python recordings are now first-class within the desktop app.

## Status & Next Steps

- Draft ADR for feedback (this document).
- Spike installer support by building the wheel inside the AppImage pipeline and confirming it runs `ct record` on sample scripts.
- Once validated, mark this ADR **Accepted** and schedule the code changes behind a feature flag for phased rollout.
