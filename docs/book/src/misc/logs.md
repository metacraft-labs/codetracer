# Logs and Diagnostics

CodeTracer consists of several components that each produce their own log
files. When reporting a bug or asking for help, attaching the relevant logs
helps us diagnose the problem quickly.

## Log locations

All runtime logs are written under a temporary directory:

| OS | Base path |
|----|-----------|
| Linux | `/tmp/codetracer/` |
| macOS | `~/Library/Caches/com.codetracer.CodeTracer/` |
| Windows | `%TEMP%\codetracer\` |

Each CodeTracer session creates a `run-<PID>/` subdirectory containing logs
for that session. The most recent session has the highest PID number.

### Log files per component

| File | Component | Contents |
|------|-----------|----------|
| `run-<PID>/replay-server.log` | Replay server (trace loading, DAP handling) | Trace metadata, event loading, DAP request/response |
| `ct-native-replay-stable-0.log` | Native replay worker (main thread) | RR/MCR replay queries, register/memory reads |
| `ct-native-replay-flow-0.log` | Native replay worker (flow preloader) | Flow data preloading |
| `ct-native-replay-tracepoint-0.log` | Native replay worker (tracepoint evaluator) | Event loading, tracepoint evaluation |
| `rr-stderr-stable-0.log` | RR replay engine stderr | RR process output |
| `run-<PID>/session-manager.log` | Session manager (backend coordinator) | Session lifecycle, worker spawning |

### Finding the most recent logs

```bash
# Linux/macOS: list the most recent session directory
ls -td /tmp/codetracer/run-* | head -1

# Show all logs from the last session
ls -la $(ls -td /tmp/codetracer/run-* | head -1)

# View the replay server log
cat $(ls -td /tmp/codetracer/run-* | head -1)/replay-server.log
```

On Windows (PowerShell):
```powershell
$latest = Get-ChildItem "$env:TEMP\codetracer\run-*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-ChildItem $latest
Get-Content "$latest\replay-server.log"
```

## Enabling debug logs

By default, CodeTracer logs at the `info` level — only high-level progress
messages and errors. To get detailed diagnostic output for troubleshooting,
enable debug logging:

### Environment variable (recommended)

```bash
# Linux/macOS
RUST_LOG=debug ct replay my-trace

# Or for maximum detail
RUST_LOG=trace ct replay my-trace
```

On Windows:
```powershell
$env:RUST_LOG = "debug"
ct replay my-trace
```

### Selective component logging

You can enable debug logs for specific components:

```bash
# Only the replay server
RUST_LOG=replay_server=debug ct replay my-trace

# Only the session manager
RUST_LOG=session_manager=debug ct replay my-trace

# Both
RUST_LOG=replay_server=debug,session_manager=debug ct replay my-trace
```

## Collecting logs for a bug report

When filing a bug report, include:

1. **The replay server log** from the failing session:
   ```bash
   cat $(ls -td /tmp/codetracer/run-* | head -1)/replay-server.log
   ```

2. **The native replay worker log** (if the issue involves trace replay):
   ```bash
   cat /tmp/codetracer/ct-native-replay-stable-0.log
   ```

3. **Steps to reproduce** — what commands you ran, what you clicked

4. **The trace file** (if possible) — smaller traces are better. You can
   export a portable trace with:
   ```bash
   ct-mcr export --portable -o trace-portable.ct /path/to/trace.ct
   ```

### Quick log bundle

Collect all logs from the last session into a zip:

```bash
# Linux/macOS
LOGDIR=$(ls -td /tmp/codetracer/run-* | head -1)
zip -j codetracer-logs.zip \
  "$LOGDIR"/*.log \
  /tmp/codetracer/ct-native-replay-*.log \
  2>/dev/null
echo "Logs saved to codetracer-logs.zip"
```

## Frontend logs

The CodeTracer frontend (the GUI) logs to the browser/Electron console.
These logs are visible in the browser's Developer Tools (F12).

### Desktop (Electron)

Open the Developer Tools console:

- **Menu**: View → Toggle Developer Tools
- **Keyboard**: `Ctrl+Shift+I` (Linux/Windows) or `Cmd+Option+I` (macOS)

The console shows frontend log messages with timestamps, log levels
(DEBUG/WARN/ERROR), file locations, and task IDs.

To capture Electron console output to a file, launch CodeTracer with
the `--enable-logging` flag:

```bash
ct replay my-trace -- --enable-logging --log-file=/tmp/ct-frontend.log
```

### Browser mode (ct host)

Open the browser's Developer Tools (F12) and switch to the Console tab.
Frontend log messages appear with the same format as in Electron.

To filter CodeTracer messages from other page output, type `ct` or
`codetracer` in the console filter box.

### Index/server process (ct host)

The `ct host` process logs to stdout. When running `ct host` from a
terminal, these messages appear directly. In the Playwright test
infrastructure, they are captured via the process's stdout pipe.

## Configuration file

CodeTracer's configuration is stored at:

| OS | Path |
|----|------|
| Linux | `~/.config/codetracer/.config.yaml` |
| macOS | `~/Library/Application Support/codetracer/.config.yaml` |
| Windows | `%APPDATA%\codetracer\.config.yaml` |

Include this file in bug reports when the issue might be configuration-related.

## Trace database

The local trace database is stored at:

| OS | Path |
|----|------|
| Linux | `~/.local/share/codetracer/` |
| macOS | `~/Library/Application Support/codetracer/` |
| Windows | `%LOCALAPPDATA%\codetracer\` |

Each trace is stored in a `trace-<ID>/` subdirectory. To reset the database:

```bash
just reset-db
just clear-local-traces
```
