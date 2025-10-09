# Python Recorder DB Backend Integration – Implementation Plan

This plan tracks the work required to implement ADR 0005 (“Wire the Rust/PyO3 Python Recorder into the Codetracer DB Backend”).

---

## Part 1 – Modifications to `codetracer-python-recorder`

1. **Recorder CLI parity**
   - Expose an explicit CLI entry point (e.g., `codetracer_python_recorder.__main__` / `cli.py`) that accepts trace directory, format, activation path, and diff flags mirroring `ct record`.
   - Map CLI arguments to existing `start_tracing` API and ensure environment variables propagate unchanged.
   - Add integration tests that execute the module via `python -m codetracer_python_recorder` to confirm argument handling and trace emission.

2. **Trace artifact compatibility**
   - Verify the recorder produces `trace.json`, `trace_paths.json`, and `trace_metadata.json` aligned with db-backend expectations (field names, metadata schema).
   - Introduce fixtures or golden files if additional metadata (e.g., tool identifiers) must be appended.

3. **Wheel packaging & layout**
   - Update `pyproject.toml` / `Cargo.toml` to tag the wheel for the platforms we ship and to include the new CLI module in the distribution.
   - Provide a tiny shim script (e.g., `bin/codetracer-python-recorder`) that simply invokes `python -m codetracer_python_recorder`.
   - Extend the `Justfile`/CI workflow to build release wheels and run smoke tests against the CLI entry point.

4. **Documentation & tooling**
   - Add recorder CLI usage examples to `README` / design docs.
   - Document expected environment variables (PYTHONPATH additions, activation behaviour) for installer integration.

Deliverable: a new release of the `codetracer_python_recorder` wheel that the desktop bundle can consume without additional patches.

---

## Part 2 – Modifications to the broader Codetracer codebase

1. **Language detection & enums**
   - Add `LangPythonDb` to `src/common/common_lang.nim`, set `IS_DB_BASED[LangPythonDb] = true`, and update `detectLang` to return the new enum when `.py` files are encountered.

2. **`ct record` wiring**
   - Extend `src/ct/trace/record.nim` to treat `LangPythonDb` like other db-backed languages, passing through user arguments, diff flags, and activation paths.
   - Capture interpreter discovery (respect `$PYTHON`, current shell PATH, `sys.executable` inside wrappers) and surface clear errors when the executable is missing.

3. **db-backend invocation**
   - In `src/ct/db_backend_record.nim`, add a Python branch that launches the user’s interpreter with the packaged launcher (e.g., `python -m codetracer_python_recorder --trace-dir ...`).
   - Ensure the subprocess inherits the current environment, including virtualenv variables, without modification.
   - Reuse the existing import pipeline (`importDbTrace`) to ingest the generated trace artifacts.

4. **Installer & packaging updates**
   - Hook maturin wheel builds into AppImage / DMG / (future) Windows pipelines, staging the wheel and launcher under `resources/python/`.
   - Update PATH-install scripts (`install_utils.nim`, installer shell scripts) to expose the launcher while deferring interpreter selection to the user’s environment.
   - Add CI smoke tests that run `ct record examples/python_script.py` on each platform build artifact.

5. **CLI UX & documentation**
   - Update `ct record --help`, docs (`docs/book/src/installation.md`, CLI guides) and release notes to communicate Python parity expectations (“matches `python script.py` in the caller’s environment”).

6. **Validation**
   - Add end-to-end tests: record + upload a Python trace via the CLI inside a virtual environment and confirm trace metadata matches expectations.
   - Ensure failure modes (missing interpreter, import errors) surface actionable messages.

Deliverable: desktop Codetracer builds where `ct record` for Python scripts behaves identically to invoking `python` directly, using the user’s interpreter, while storing traces through the db-backend workflow.

---

**Milestones**
1. Ship updated `codetracer_python_recorder` wheel with CLI parity (Part 1).
2. Land Codetracer integration (Part 2) behind a feature flag.
3. Remove the flag after cross-platform packaging and smoke tests succeed.
