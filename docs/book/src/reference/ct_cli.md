## ct CLI Reference

The `ct` command is the main CodeTracer CLI. It records program executions, replays traces, and manages the CodeTracer environment.

### Synopsis

```
ct <command> [options] [<program>] [<args>]
```

### Commands

#### Recording and Replay

| Command                                       | Description                                                          |
| --------------------------------------------- | -------------------------------------------------------------------- |
| `ct run <program> [args]`                     | Record and immediately open in the GUI                               |
| `ct record <program> [args]`                  | Record a trace to disk                                               |
| `ct replay`                                   | Open a trace in the GUI                                              |
| `ct import <trace-folder>`                    | Import a trace from a folder                                         |
| `ct trace extract-gfx -o <dir> <trace>`       | Extract the graphics stream from a `.ct` container                   |
| `ct trace export --portable -o <out> <trace>` | Export a portable trace (embeds binaries and debug symbols)          |
| `ct gfx-replay --gfx-stream <dir>`            | Replay an extracted graphics stream (used by the visual replay GUI)  |

#### Stylus / EVM

| Command           | Description                                       |
| ----------------- | ------------------------------------------------- |
| `ct arb deploy`   | Deploy a Stylus contract to a local devnode       |
| `ct arb explorer` | Open the transaction explorer for recorded traces |
| `ct arb record`   | Record a Stylus contract execution                |
| `ct arb replay`   | Replay a Stylus trace                             |

#### CI Integration

| Command        | Description                           |
| -------------- | ------------------------------------- |
| `ct ci start`  | Start a CI recording session          |
| `ct ci attach` | Attach to a running CI session        |
| `ct ci exec`   | Execute a command within a CI session |
| `ct ci finish` | Finalize a CI session                 |
| `ct ci run`    | Run a command with CI recording       |
| `ct ci log`    | View CI session logs                  |
| `ct ci status` | Check CI session status               |
| `ct ci cancel` | Cancel a CI session                   |

#### Utility

| Command               | Description                                                                       |
| --------------------- | --------------------------------------------------------------------------------- |
| `ct install`          | Install the CLI tools                                                             |
| `ct version`          | Print the CodeTracer version                                                      |
| `ct help`             | Display help information                                                          |
| `ct list`             | List recorded traces                                                              |
| `ct console`          | Open the interactive console                                                      |
| `ct doctor <lang>`    | Probe recorder-readiness for a language (currently `python`; more languages soon) |

#### Online Sharing

| Command       | Description                           |
| ------------- | ------------------------------------- |
| `ct upload`   | Upload a trace                        |
| `ct download` | Download a trace                      |
| `ct login`    | Authenticate with the sharing service |

### ct record

Records the execution of a program into a trace.

```
ct record [options] <program> [-- <program-args>]
```

**Options:**

| Flag                          | Description                                                  |
| ----------------------------- | ------------------------------------------------------------ |
| `--lang <LANG>`               | Override language detection (e.g., `noir`, `python`, `ruby`) |
| `-o, --output-folder <DIR>`   | Output directory for trace files                             |
| `--backend <BACKEND>`         | Recording backend (e.g., `plonky2` for Noir)                 |
| `-e, --export <ZIP>`          | Export trace as a zip archive                                |
| `-c, --cleanup-output-folder` | Remove the output folder after export                        |
| `--trace-kind <KIND>`         | Trace kind: `db` (default), `rr`, or `ttd`                   |
| `--rr-support-path <PATH>`    | (internal) Override path for the RR-backend DAP binary       |
| `--python-interpreter <PATH>` | Path to the Python interpreter to use                        |
| `--pytest [ARGS]`             | Run pytest with the given arguments                          |
| `--unittest [ARGS]`           | Run unittest with the given arguments                        |
| `-t, --stylus-trace <PATH>`   | Path to a Stylus trace file                                  |
| `-a, --address <ADDR>`        | Contract address (Stylus)                                    |
| `--socket <PATH>`             | Unix socket path for event reporting                         |
| `--use-interpose`             | Record graphics API calls for visual replay (MCR backend only) |

**Language detection:** When `--lang` is not provided, `ct` detects the language from the file extension or project structure:

| Extension / Marker              | Language                  |
| ------------------------------- | ------------------------- |
| `.py`                           | Python                    |
| `.rb`                           | Ruby                      |
| `.nr` or `Nargo.toml`           | Noir                      |
| `.wasm`                         | WASM                      |
| `.small`                        | Small                     |
| `Cargo.toml` with wasm32 target | Rust WASM                 |
| `Cargo.toml`                    | Rust (native, via rr/TTD) |

> **Note:** Blockchain-specific languages (Circom, Cairo, Aiken, Cadence, Move, Sway, Miden, PolkaVM, Leo, Tolk) use their own recorder binaries. See the [Getting Started](../getting_started/overview.md) guides for each language.

> **Note:** Visual recordings for native graphics programs are MCR `.ct` traces produced with `ct record --use-interpose`. CodeTracer opens these traces in the GUI and starts the visual replay player automatically. See [Visual recordings](../usage_guide/visual_recordings.md).

### ct replay

Opens a previously recorded trace in the CodeTracer GUI.

```
ct replay [options] [<program-name>]
```

**Options:**

| Flag                   | Description                                 |
| ---------------------- | ------------------------------------------- |
| `<program-name>`       | Open the most recent trace for this program |
| `--id=<TRACE_ID>`      | Open a trace by its numeric ID              |
| `--trace-folder=<DIR>` | Open a trace from a specific directory      |

When called without arguments, `ct replay` opens an interactive dialog to choose from recent traces.

### ct run

Records a program and immediately opens the trace in the GUI. Equivalent to `ct record` followed by `ct replay`.

```
ct run [options] <program> [-- <program-args>]
```

Accepts the same options as `ct record`.

### ct trace origin

Prints the backward dataflow chain (an "origin chain") for a variable.
Walks assignments / parameter passes / return captures / field-or-index
accesses backward from the queried `(variable, step, frame)` until a
terminator (computational expression, literal, parameter at the
recording boundary, etc.) is reached. Drives the same `ct/originChain`
DAP request as the `Trace.value_origin(...)` Python binding and the
`get_value_origin` MCP tool.

```
ct trace origin <trace-path> --variable <NAME> [options]
```

**Options:**

| Flag                              | Description                                                                                       |
| --------------------------------- | ------------------------------------------------------------------------------------------------- |
| `<trace-path>`                    | Path to the trace directory (required positional argument).                                       |
| `--variable <NAME>`               | Variable identifier to query. V1 is identifier-only; dotted paths are reserved. **Required.**     |
| `--step <N>`                      | Step id at which to query. Defaults to the trace's current execution point.                       |
| `--frame <N>`                     | DAP frame id at which to query. Defaults to the topmost frame.                                    |
| `--max-hops <N>`                  | Maximum hops in this batch. Default: `16`.                                                        |
| `--format <json\|markdown\|text>` | Output renderer. Default: `text`.                                                                 |
| `--lazy`                          | Allow the backend to return a `continuationToken` instead of walking the full chain in one shot.  |

**Formats:**

- `text` — ASCII layout matching spec §3.2 (newest hop first, terminator
  at the bottom, frame-transition glyphs inline). Good for terminal
  copy-paste.
- `markdown` — fenced chain with classification badges and a per-hop
  table. Paste straight into a bug report.
- `json` — canonical `OriginChain` wire schema, pretty-printed. Use for
  scripting or downstream tooling.

**Example:**

```bash
ct trace origin /traces/my-bug.ct --variable total --step 137 --format text
```

For multi-step agent workflows that need to compose origin lookups with
locals/history/breakpoints, prefer `ct trace exec --script <file.py>
<trace-path>` and call `trace.value_origin(...)` inside the script — the
trace stays loaded across calls and the classifier's pattern cache is
reused.

See [Value Origin Tracking](../usage_guide/value-origin-tracking.md) for
the user-facing walkthrough.

### ct trace extract-gfx

Extracts the graphics stream from a `.ct` trace container into a directory the visual replay player can consume.

```
ct trace extract-gfx -o <output-dir> <trace>
```

**Options:**

| Flag                       | Description                                                            |
| -------------------------- | ---------------------------------------------------------------------- |
| `<trace>`                  | Path to the `.ct` trace container to extract (required positional).    |
| `-o, --output-dir <DIR>`   | Directory to extract the graphics stream into. Required.               |

See [Visual recordings](../usage_guide/visual_recordings.md) for the full workflow.

### ct trace export

Exports a recorded trace to a single file, optionally producing a portable bundle with embedded binaries and debug symbols.

```
ct trace export [--portable] -o <output> <trace>
```

**Options:**

| Flag                  | Description                                                        |
| --------------------- | ------------------------------------------------------------------ |
| `<trace>`             | Path to the source trace to export (required positional).          |
| `--portable`          | Produce a portable export with embedded binaries and debug symbols.|
| `-o, --output <PATH>` | Output path for the exported trace (required).                     |

### ct gfx-replay

Replays an extracted graphics stream. The CodeTracer GUI launches this automatically when opening a visual `.ct` trace; running it directly is useful for diagnostics.

```
ct gfx-replay --gfx-stream <dir> [--http --port <N>] [--backend <BACKEND>]
```

**Options:**

| Flag                  | Description                                                                |
| --------------------- | -------------------------------------------------------------------------- |
| `--gfx-stream <DIR>`  | Path to the extracted graphics-stream directory (required).                |
| `--http`              | Start the player as an HTTP server (used by the GUI).                      |
| `--port <N>`          | Port for the HTTP player (only meaningful with `--http`).                  |
| `--backend <BACKEND>` | Rendering backend selector — e.g. `software` or `hardware`.                |

### ct doctor

Probes recorder-readiness for a language: reports the interpreter or runtime that would be used and whether the matching recorder package is installed and importable.

```
ct doctor <language>
```

**Arguments:**

| Argument     | Description                                                                                  |
| ------------ | -------------------------------------------------------------------------------------------- |
| `<language>` | Recorder to probe. Currently `python` is wired; more recorders will land in future releases. |

Run this when `ct record` fails with a recorder import error to confirm which interpreter `ct` is targeting and whether the recorder package is present.

### ct trace exec

Runs a Python replay-script against a recording. The script body is the
same one consumed by the MCP `exec_script` tool, so the same logic runs
from a terminal session and from an agent workflow.

```
ct trace exec --script <file.py> <trace-path>
```

Inside the script a `trace` object is pre-bound to the loaded recording.
Methods include `trace.locals()`, `trace.history()`, navigation
(`trace.step_over()` etc.), and `trace.value_origin(...)` for origin
chains. See the
[Python API reference](https://github.com/metacraft-labs/codetracer/tree/main/python-api)
for the full surface.

### Environment Variables

| Variable                        | Description                                                             |
| ------------------------------- | ----------------------------------------------------------------------- |
| `CODETRACER_PYTHON_INTERPRETER` | Path to the Python interpreter for recording                            |
| `CODETRACER_NOIR_EXE_PATH`      | Path to the Noir tracer binary                                          |
| `CODETRACER_WASM_VM_PATH`       | Path to the WASM VM binary (wazero)                                     |
| `CODETRACER_RECORDING`          | Set to `1` during recording                                             |
| `CODETRACER_CALLTRACE_MODE`     | Call trace mode: `FullRecord`, `RawRecordNoValues`, `NoInstrumentation` |
| `CODETRACER_SHELL_ID`           | Shell session ID (for CodeTracer Shell)                                 |
| `CODETRACER_CT_MCR_CMD`         | Override the internal MCR binary that `ct trace extract-gfx` invokes     |
| `CODETRACER_CT_GFX_PLAYER_CMD`  | Override the internal player binary that `ct gfx-replay` launches        |
| `CODETRACER_CT_GFX_PLAYER_BACKEND` | Default backend for `ct gfx-replay` (equivalent to `--backend`), for example `software` |

### Output Format

All recordings produce a trace directory containing:

| File                        | Description                                             |
| --------------------------- | ------------------------------------------------------- |
| `trace.bin` or `trace.json` | The trace data (binary or JSON format)                  |
| `trace_metadata.json`       | Metadata about the trace (language, program, timestamp) |
| `trace_paths.json`          | Source file paths referenced in the trace               |
| `symbols.json`              | Extracted symbols (for Noir and some languages)         |
