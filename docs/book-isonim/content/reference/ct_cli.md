---
title: ct CLI Reference
order: 101
---
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

#### DeepReview

| Command                      | Description                                                          |
| ---------------------------- | -------------------------------------------------------------------- |
| `ct review <PATH>`           | Open a review over an exported review dataset                        |
| `ct review collect [options]`| Produce a review dataset from recordings + a diff                    |
| `ct review inspect <PATH>`   | Summarise a dataset without opening a GUI                            |
| `ct agent evidence <PATH>`   | Hand a review dataset to CodeTracer from inside an agent session     |
| `ct agent end-of-turn`       | Run `ct review collect` then `ct agent evidence`, for a project hook |
| `ct agent prompt`            | Print the prompt text that teaches an agent the pair                 |

See the [DeepReview](/deep_review) section for the workflow.

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

:::note
Blockchain-specific languages (Circom, Cairo, Aiken, Cadence, Move, Sway, Miden, PolkaVM, Leo, Tolk) use their own recorder binaries. See the [Getting Started](/getting_started) guides for each language.
:::

:::note
Visual recordings for native graphics programs are MCR `.ct` traces produced with `ct record --use-interpose`. CodeTracer opens these traces in the GUI and starts the visual replay player automatically. See [Visual recordings](../usage_guide/visual_recordings.md).
:::

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

### ct review

Opens a review over an exported review dataset — the diff, its recorded
executions, coverage and flow. See
[Reading a review](/deep_review/reading).

```
ct review <PATH>
```

| Argument | Description                                                                            |
| -------- | --------------------------------------------------------------------------------------- |
| `<PATH>` | A `review.json` file, or the directory `ct review collect` wrote it into. Required.     |

`ct review` is an ordinary `ct` command, so `ct`'s global options (`--cwd`,
`--inspect`, `--remote-debugging-port`, the `--env-file` family) work with it.
A path that does not exist is diagnosed by `ct` rather than by the renderer.

`ct review` on its own — and `ct review --help` — prints the whole group's
usage, not just the launch form.

:::note
`ct --deepreview <PATH>` and the `ct-native-replay deepreview
{collect,export,inspect}` subcommands are retired. They fail with a message
naming the `ct review` replacement rather than being kept as aliases.
:::

### ct review collect

Produces a review dataset from a set of recordings and a diff. The collector is
chosen by **inspecting the recordings** — native/rr recordings go to the native
replay backend, materialized traces (Python, Ruby, JavaScript, Noir, …) go to
the db-backend collector. There is no `--backend` flag.

```
ct review collect (--repo <DIR> --diff <BASE..HEAD> | --diff-file <PATH>) \
                  --recordings <DIR> --output <DIR> \
                  [--preset <NAME>] [--progress]
```

**Options:**

| Flag                   | Required                       | Default   | Description                                                                      |
| ---------------------- | ------------------------------ | --------- | ---------------------------------------------------------------------------------- |
| `--repo <DIR>`         | Yes (unless `--diff-file`)     | —         | Git repository the diff is read from                                             |
| `--diff <BASE..HEAD>`  | Yes (unless `--diff-file`)     | —         | Diff specification, e.g. `main..HEAD`. Must contain `..`                         |
| `--diff-file <PATH>`   | Yes (unless `--repo`+`--diff`) | —         | A unified diff file instead of `--repo`/`--diff`. Cannot be combined with either |
| `--recordings <DIR>`   | Yes                            | —         | Directory holding the recordings, one subdirectory per run                       |
| `--output <DIR>`, `-o` | Yes                            | —         | Directory the dataset is written to                                              |
| `--preset <NAME>`      | No                             | `default` | Collection preset: `default`, `minimal` or `comprehensive`                       |
| `--progress`           | No                             | off       | Emit JSON Lines progress events on stderr                                        |

Both `--output DIR` and `--output=DIR` are accepted. `collect` takes no
positional arguments.

`collect` writes `review.json` into `--output` beside the collector's own
chunks, so `ct review <the same DIR>` opens exactly what it produced. If the
export half fails, the command says so and exits non-zero rather than reporting
a partial success.

**Presets** differ in sampling intensity only: `minimal` keeps one sample per
line and one execution per function (fastest, smallest); `default` keeps 3 and
10; `comprehensive` keeps 10 and 50 with a deeper value limit.

**Progress events** (`--progress`) are one JSON object per line on stderr:

```
{"fileCount":1,"recordingCount":2,"type":"collection_started"}
{"percentage":0.0,"recordingIndex":0,"recordingTotal":2,"type":"recording_progress"}
{"percentage":50.0,"recordingIndex":1,"recordingTotal":2,"type":"recording_progress"}
{"coverageLines":8,"flowSteps":42,"path":"src/main.nr","symbols":1,"type":"file_collected"}
{"elapsedMs":68,"fileCount":1,"totalFlowSteps":42,"type":"collection_completed"}
```

One `recording_progress` is emitted per recording, before that recording is
collected, so the stream is as long as `--recordings` is deep.

**Diagnostics.** A recordings directory that mixes native and materialized
recordings is refused with a message naming both kinds. An empty directory, a
directory holding no recordings, and a `--recordings` path that does not exist
each get their own message and a non-zero status — never a silently empty
dataset.

### ct review inspect

Reads a dataset and prints summary statistics without opening a GUI.

```
ct review inspect <PATH> [--format text|json]
```

| Flag                | Default | Description                            |
| ------------------- | ------- | -------------------------------------- |
| `<PATH>`            | —       | The dataset directory. Required.       |
| `--format <FORMAT>` | `text`  | `text` (human-readable) or `json`      |

:::note
`inspect` reads the **native** collector's dataset layout (the directory
containing `manifest.dr`) and delegates to the native replay backend. A dataset
produced from a materialized trace is a single `review.json` with no chunks, so
`inspect` reports the missing `manifest.dr`; open it with `ct review`, or read
the JSON directly.
:::

### ct agent evidence

Hands a review dataset to CodeTracer from inside an agent session.

```
ct agent evidence <PATH> [--session <ID>] [--task <ID>] [--workspace <DIR>]
```

| Flag                | Description                                                                         |
| ------------------- | ------------------------------------------------------------------------------------- |
| `<PATH>`            | The dataset: a directory from `ct review collect`, or the `review.json` in it. Required. |
| `--session <ID>`    | The agent session this evidence belongs to                                          |
| `--task <ID>`       | The task the session is working on                                                  |
| `--workspace <DIR>` | The workspace the session is working in                                             |

All three are read from `CODETRACER_AGENT_SESSION_ID`,
`CODETRACER_AGENT_TASK_ID` and `CODETRACER_AGENT_WORKSPACE` — the variables the
agent harness already exports — and the flags override them. The session falls
back to the reference `ct review collect` stamped into the dataset. If none of
the three names a session, the command exits non-zero and says which to supply;
it never invents an id.

The changeset, the recordings and the status the notification carries are read
from the dataset, not restated by the agent.

### ct agent end-of-turn

Runs the two ordinary commands, in order, printing each as it runs it — for use
as a project's end-of-turn hook.

```
ct agent end-of-turn [collect options] [--session <ID>] [--task <ID>] [--workspace <DIR>]
```

It accepts all of `ct review collect`'s options (`--repo`, `--diff`,
`--diff-file`, `--recordings`, `--output`/`-o`, `--preset`, `--progress`) plus
the three above, and fills unset ones from the environment so a hook line can be
bare:

| Variable                       | Fills in       | Default        |
| ------------------------------ | -------------- | -------------- |
| `CODETRACER_REVIEW_REPO`       | `--repo`       | the workspace  |
| `CODETRACER_REVIEW_DIFF`       | `--diff`       | —              |
| `CODETRACER_REVIEW_DIFF_FILE`  | `--diff-file`  | —              |
| `CODETRACER_REVIEW_RECORDINGS` | `--recordings` | `.ct/runs`     |
| `CODETRACER_REVIEW_OUTPUT`     | `--output`     | `.ct/review`   |

### ct agent prompt

Prints the prompt text that teaches an agent the collect-then-hand-over pair.
Install it into a project's agent instructions with:

```bash
ct agent prompt >> AGENTS.md
```

The text describes only commands that ship. In particular it does not mention
test certificates, which `ct test` does not yet issue.

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
| `CODETRACER_NATIVE_REPLAY_PATH` | Path to the `ct-native-replay` binary used by native `ct review collect` / `ct review inspect` |
| `CODETRACER_AGENT_SESSION_ID`   | Agent session `ct agent evidence` and `ct review collect` attribute a review to |
| `CODETRACER_AGENT_TASK_ID`      | Task the agent session is working on                                    |
| `CODETRACER_AGENT_WORKSPACE`    | Workspace the agent session is working in                               |
| `CODETRACER_REVIEW_REPO`        | `ct agent end-of-turn` default for `--repo`                             |
| `CODETRACER_REVIEW_DIFF`        | `ct agent end-of-turn` default for `--diff`                             |
| `CODETRACER_REVIEW_DIFF_FILE`   | `ct agent end-of-turn` default for `--diff-file`                        |
| `CODETRACER_REVIEW_RECORDINGS`  | `ct agent end-of-turn` default for `--recordings` (falls back to `.ct/runs`) |
| `CODETRACER_REVIEW_OUTPUT`      | `ct agent end-of-turn` default for `--output` (falls back to `.ct/review`) |

### Output Format

All recordings produce a trace directory containing:

| File                        | Description                                             |
| --------------------------- | ------------------------------------------------------- |
| `trace.bin` or `trace.json` | The trace data (binary or JSON format)                  |
| `trace_metadata.json`       | Metadata about the trace (language, program, timestamp) |
| `trace_paths.json`          | Source file paths referenced in the trace               |
| `symbols.json`              | Extracted symbols (for Noir and some languages)         |
