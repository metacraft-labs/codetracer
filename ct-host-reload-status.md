# `ct host` reload resilience – status

## References
- ADR: `0006-ct-host-reload-resilience.md`
- Plan: `ct-host-reload-resilience-implementation-plan.md`
- Testing overview: see “Automated coverage”/“Manual verification” sections in the plan for suite placement.

## Key files (Part 1 focus)
- `src/frontend/index/server_config.nim` — Express/socket.io server wiring; sets `ipc.socket` on connection.
- `src/frontend/index/base_handlers.nim` — IPC plumbing; `FrontendIPC` type and `indexIpcHandlers` macro that currently binds handlers to a single socket.
- `src/frontend/index/ipc_utils.nim` — `ready()` registers handlers and defines the `mainWindow.webContents.send` shim for server mode.
- `src/frontend/ui_js.nim` — Browser-side socket bootstrap; reconnect path that currently creates a fresh socket on reload.
- `src/frontend/index/electron_vars.nim`/`window.nim` — Globals and send/recv setup that will need to route through the new registry.

## Progress
- Established root cause (handlers pinned to first socket) and documented solution in ADR/plan.
- Added TDD scenarios to the plan for registry/rebind behavior.
- Added headless test scaffold for registry attach/detach (`src/frontend/tests/ipc_registry_test.nim`) and implemented `ipc_registry` with attach/detach bindings; test now passes via `nim js -r src/frontend/tests/ipc_registry_test.nim`.
- Updated `FrontendIPC` to use the new registry, hooked socket attach/detach in `server_config.nim`, and guarded server-side sends via `ipc.emit` when no socket is attached.

## Next tasks (Part 1)
- Align remaining server-mode send/receive paths with the registry (audit any direct `ipc.socket` uses and ensure reconnect safety where needed).
- Add headless Nim test in `tester ui` set that exercises disconnect/reconnect (`CODETRACER::open-tab`/`load-recent-trace` style) to validate rebinding (current unit-level registry test passes; still need end-to-end UI harness scenario).
