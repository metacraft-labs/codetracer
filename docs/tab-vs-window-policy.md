# Tab-vs-Window Policy for `ct run` / `ct replay`

## Problem

When `ct run` or `ct replay` is invoked and a CodeTracer window already
exists, the current behavior always spawns a new Electron window. This
is wasteful and confusing when the user wants to compare traces
side-by-side in tabs within a single window.

## Solution

A configurable policy controls whether a new trace opens as a tab in the
existing window or as a new Electron window.

### Policy values

| Value      | Behavior                                               |
|------------|--------------------------------------------------------|
| `"tab"`    | Open the trace as a new session tab in the existing window (default) |
| `"window"` | Open a new Electron window (legacy behavior)          |

### Configuration

The policy is set in the user's config YAML
(`~/.config/codetracer/.config.yaml`):

```yaml
newTracePolicy: "tab"   # or "window"
```

The default config (`src/config/default_config.yaml`) ships with `"tab"`.

### CLI override

Both `ct run` and `ct replay` accept flags that override the config:

```
ct replay --new-tab --id=42     # Force tab policy
ct replay --new-window --id=42  # Force window policy
ct run --new-tab my_program.py  # Force tab policy
ct run --new-window my_program  # Force window policy
```

If neither flag is given, the config value is used. If both are given,
`--new-tab` takes precedence (confutils parses left-to-right and the
flag set last wins, but the launch code checks `--new-tab` first).

## Implementation

### Flow for `"tab"` policy

1. `ct run`/`ct replay` resolves the effective policy from CLI flags
   and config.
2. The policy is passed through `run()` -> `runWithRestart()` ->
   `replay()` -> `runRecordedTrace()` -> `launchElectron()`.
3. `launchElectron()` sets `CODETRACER_NEW_TRACE_POLICY` env var
   before exec-ing the Electron binary.
4. In `src/frontend/index.nim`, if the policy is `"tab"`:
   - The first Electron instance acquires
     `app.requestSingleInstanceLock()`.
   - When a second instance starts, the lock fails. The second
     instance quits immediately.
   - The first instance receives the `"second-instance"` event with
     the second instance's argv (which contains the trace ID).
   - The first instance sends `"CODETRACER::open-trace-in-tab-ready"`
     to the renderer with the trace ID.
5. The renderer's `onOpenTraceInTabReady` handler:
   - Creates a new session tab (`createNewSession(data)`).
   - Sends `"CODETRACER::load-recent-trace"` back to the main process.
6. The main process's `onLoadRecentTrace` handler starts the replay
   backend and loads the trace into the new session.

### Caption tab layout

Session tabs are part of the caption bar flex row with the menu,
debug controls, omnibox, new-tab button, overflow chevron, and window
controls. These controls must not overlap.

The tab strip may only render as many visible tabs as can fit at the
tab minimum width. When there is not enough caption space for another
minimum-width tab, additional sessions remain available through the
overflow chevron menu. Selecting a session from that menu must switch
the active tab.

### Flow for `"window"` policy

When the policy is `"window"`, or when no policy env var is set and the
code falls back to `"window"`:
- `requestSingleInstanceLock()` is **not** called.
- Each `ct run`/`ct replay` spawns its own Electron process as before.

### IPC messages

| Message                                    | Direction         | Payload                |
|--------------------------------------------|-------------------|------------------------|
| `CODETRACER::open-trace-in-tab-ready`      | main -> renderer  | `{ traceId: int }`     |
| `CODETRACER::open-trace-in-tab`            | renderer -> main  | `{ traceId: int }`     |
| `CODETRACER::load-recent-trace`            | renderer -> main  | `{ traceId: int }`     |

### Files changed

- `src/common/config.nim` -- `newTracePolicy` field on `ConfigObject`
- `src/frontend/types.nim` -- `newTracePolicy` field on `Config`
- `src/config/default_config.yaml` -- default value
- `src/ct/codetracerconf.nim` -- `--new-tab`/`--new-window` CLI flags
- `src/ct/launch/electron.nim` -- pass policy via env var
- `src/ct/launch/launch.nim` -- resolve policy from flags, pass to commands
- `src/ct/trace/run.nim` -- accept and propagate `newTracePolicy`
- `src/ct/trace/replay.nim` -- accept and propagate `newTracePolicy`
- `src/frontend/index.nim` -- single-instance lock + second-instance handler
- `src/frontend/index/traces.nim` -- `onOpenTraceInTab` IPC handler
- `src/frontend/index/ipc_utils.nim` -- register `open-trace-in-tab` IPC
- `src/frontend/ui_js.nim` -- `onOpenTraceInTabReady` renderer handler + registration

### Known limitations

- The single-instance lock is process-wide. If two traces are launched
  simultaneously with `"tab"` policy, only one second-instance event
  fires at a time. Rapid launches may queue.
- The `"window"` policy does not use `requestSingleInstanceLock()`,
  so it does not interfere with existing multi-window workflows.
- The second instance's env var `CODETRACER_NEW_TRACE_POLICY` is
  inherited from the first `ct` process. If the user changes the
  config between launches, the env var from the first launch wins
  for the lock decision.
