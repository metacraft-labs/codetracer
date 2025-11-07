# Launching CodeTracer for Multi-Instance Testing

This document captures the current best-practices for starting multiple CodeTracer instances (Electron and `ct host`) in parallel. The former `ui-tests-startup-example/` project has been removed; its behaviour is now documented here for direct reuse inside `ui-tests-v3/`.

## Prerequisites

1. **Enter the Nix dev shell**
   ```bash
   nix develop
   ```
   or rely on `direnv allow` at repository root. The shell provisions Playwright, Electron, Nim, and records the runtime library path in `ct_paths.json`.

2. **Build the Electron bundle once**
   ```bash
   just build-once
   ```
   Use this recipe instead of `just build`; the latter leaves `tup monitor` running indefinitely.

## Launching Workflow

1. **Record or locate a trace**  
   The startup example records the Noir Space Ship program on demand. If you need a custom trace, set `CODETRACER_TRACE_PATH` before running the harness.

2. **Run the harness with the correct library path**
   ```bash
   LD_LIBRARY_PATH=$(jq -r '.LD_LIBRARY_PATH' ct_paths.json) \
     dotnet run --project <your-ui-tests-v3-harness>
   ```
   Replace `<your-ui-tests-v3-harness>` with whichever project currently drives the experimental runner.

3. **Socket allocation**
   - Reserve a free TCP port for the HTTP host (`GetFreeTcpPort()`).
   - Reserve a second port and **assign the same value** to both `--backend-socket-port` and `--frontend-socket`. `ct host` exposes a single socket.io listener; using different values or space-delimited flags falls back to port `5000`, causing collisions.

4. **Electron launch**
   - Use CDP (`--remote-debugging-port`) and remove `ELECTRON_RUN_AS_NODE`.
   - Detect monitor geometry with `xrandr`, apply `--window-position/--window-size`, and reset zoom to 100%.

5. **Web launch**
   - Wait for the HTTP endpoint (poll `http://localhost:<port>`).
   - After Playwright connects, fire a `window.dispatchEvent(new Event('resize'))` so the CodeTracer UI fills the window.

6. **Cleanup**
   - Wrap Playwright contexts, browsers, and sessions in `await using`.
   - Kill lingering `ct`, Electron, and Node processes via `ProcessUtilities` to avoid interference across parallel runs.

## Troubleshooting Checklist

- `Error while processing the port= parameter: invalid integer:`  
  You passed `--flag value`. Switch to `--flag=value`.

- `Error: listen EADDRINUSE`  
  Reusing a socket. Ensure the backend and frontend socket ports are identical and genuinely free before each run.

- UI not fullscreen or zoomed incorrectly  
  Confirm the resize event executes and that monitor detection returned sensible values.

- Timeouts waiting for `#eventLog-0-dense-table-0`  
  Check that `ct host` is still running. Inspect `[ct host:<label>]` logs for early exits and review socket arguments.

## Next Steps for `ui-tests-v3/`

- Mirror the helper layout described here (ProcessUtilities, MonitorUtilities, CtHostLauncher, NetworkUtilities) inside the V3 harness so every scenario shares the same startup contract.
- Keep this document updated whenever the V3 launcher evolves and log the changes in `docs/progress.md`.
