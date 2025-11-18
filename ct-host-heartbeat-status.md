# `ct host` heartbeats & idle timeout – status

## References
- ADR: `0007-ct-host-heartbeat-and-idle-timeout.md`
- Plan: `ct-host-heartbeat-and-idle-timeout-implementation-plan.md`

## Key files (targets)
- `src/ct/trace/host.nim` — CLI parsing for `ct host`; place `--idle-timeout`/env plumbing and process exit.
- `src/frontend/index/server_config.nim` — socket.io server; hook connection/activity timestamps and idle watchdog.
- `src/frontend/index/base_handlers.nim` / `ipc_utils.nim` — IPC attach/detach, emit handling; update activity timestamps on inbound events.
- `src/frontend/ui_js.nim` — browser socket bootstrap; reconnect UX and entry point for disconnected-state UI (no dedicated heartbeat channel).
- `src/frontend/event_helpers.nim` / `ui/status.nim` — existing notification/status components to surface “Disconnected” warning and badge.

## Progress
- ADR defined for heartbeats, idle timeout (default 10m), clean exit on inactivity, and user-facing disconnected state.
- Implementation plan drafted, including UX reuse of `NotificationWarning` and status-bar badge for inactive connections.
- Scoped out a browser → backend heartbeat channel: plan now targets server-side activity tracking (socket `onAny`/`__activity__` ping) instead of new frontend emits.
- Added CLI/config plumbing for `ct host --idle-timeout` (env override `CODETRACER_HOST_IDLE_TIMEOUT`) with human-friendly parsing (ms/s/m/h), default 10m, and `0/never` disabling auto-exit.
- Server mode now receives `--idle-timeout-ms`, tracks connection/activity timestamps, and schedules an idle watchdog that exits with code 0 on “no connection” or “no activity” expiration.
- Server socket now refreshes `lastActivity` on every inbound socket.io event via `onAny`, keeps `__activity__` as a minimal testing hook, and resets the “no connection” timer when the socket disconnects to avoid early exits.
- Introduced shared idle-timeout helpers (`idle_timeout.nim`) and unit tests covering duration parsing, interval clamping, and idle-exit decisions (`src/ct/trace/host_idle_timeout_test.nim`, `src/frontend/tests/idle_timeout_test.nim`).
- Added integration coverage that launches `server_index.js` with short/disabled timeouts to assert exit-on-no-connection and persistence when disabled (`src/frontend/tests/idle_timeout_integration_test.nim`).
- Expanded integration suite to cover silent-connection idle exit, normal IPC traffic keeping the host alive, reconnect resetting the idle timer, and disconnect-driven idle windows (`idle_timeout_integration_test.nim`).

## Next steps
- Stabilize the updated integration suite in CI (JS backend build currently required for coverage) and keep `onAny` activity resets guarded by tests.
- Implement disconnected UX: persistent warning via `NotificationWarning`, status-bar “Disconnected” badge, block/guard IPC sends; verify accessibility.
- Land TDD coverage: unit/integration for the watchdog and idle exits plus a browser/Playwright scenario asserting warning/banner and exit behavior with short timeouts.
