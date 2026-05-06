## ct CLI Reference

The `ct` command is the main CodeTracer CLI. It records program executions, replays traces, and manages the CodeTracer environment.

### Synopsis

```
ct <command> [options] [<program>] [<args>]
```

### Commands

#### Recording and Replay

| Command                      | Description                            |
| ---------------------------- | -------------------------------------- |
| `ct run <program> [args]`    | Record and immediately open in the GUI |
| `ct record <program> [args]` | Record a trace to disk                 |
| `ct replay`                  | Open a trace in the GUI                |
| `ct import <trace-folder>`   | Import a trace from a folder           |

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

| Command      | Description                  |
| ------------ | ---------------------------- |
| `ct install` | Install the CLI tools        |
| `ct version` | Print the CodeTracer version |
| `ct help`    | Display help information     |
| `ct list`    | List recorded traces         |
| `ct console` | Open the interactive console |

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
| `--rr-support-path <PATH>`    | Path to `ct-rr-support` binary                               |
| `--python-interpreter <PATH>` | Path to the Python interpreter to use                        |
| `--pytest [ARGS]`             | Run pytest with the given arguments                          |
| `--unittest [ARGS]`           | Run unittest with the given arguments                        |
| `-t, --stylus-trace <PATH>`   | Path to a Stylus trace file                                  |
| `-a, --address <ADDR>`        | Contract address (Stylus)                                    |
| `--socket <PATH>`             | Unix socket path for event reporting                         |

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

> **Note:** Visual recordings for native graphics programs are MCR `.ct` traces produced with `ct-mcr record --use-interpose`. CodeTracer opens these traces in the GUI and starts the visual replay player automatically. See [Visual recordings](../usage_guide/visual_recordings.md).

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

### Environment Variables

| Variable                        | Description                                                             |
| ------------------------------- | ----------------------------------------------------------------------- |
| `CODETRACER_PYTHON_INTERPRETER` | Path to the Python interpreter for recording                            |
| `CODETRACER_NOIR_EXE_PATH`      | Path to the Noir tracer binary                                          |
| `CODETRACER_WASM_VM_PATH`       | Path to the WASM VM binary (wazero)                                     |
| `CODETRACER_RECORDING`          | Set to `1` during recording                                             |
| `CODETRACER_CALLTRACE_MODE`     | Call trace mode: `FullRecord`, `RawRecordNoValues`, `NoInstrumentation` |
| `CODETRACER_SHELL_ID`           | Shell session ID (for CodeTracer Shell)                                 |
| `CODETRACER_CT_MCR_CMD`         | Override the MCR command used for visual replay graphics extraction      |
| `CODETRACER_CT_GFX_PLAYER_CMD`  | Override the visual replay player binary                                |
| `CODETRACER_CT_GFX_PLAYER_BACKEND` | Override the visual replay player backend, for example `software`     |

### Output Format

All recordings produce a trace directory containing:

| File                        | Description                                             |
| --------------------------- | ------------------------------------------------------- |
| `trace.bin` or `trace.json` | The trace data (binary or JSON format)                  |
| `trace_metadata.json`       | Metadata about the trace (language, program, timestamp) |
| `trace_paths.json`          | Source file paths referenced in the trace               |
| `symbols.json`              | Extracted symbols (for Noir and some languages)         |
