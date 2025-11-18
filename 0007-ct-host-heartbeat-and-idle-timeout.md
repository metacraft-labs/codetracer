# ADR 0007: Heartbeats and Idle Shutdown for `ct host`

- **Status:** Proposed
- **Date:** 2025-11-18
- **Deciders:** Codetracer Runtime & UI Leads
- **Consulted:** Developer Experience, QA Automation
- **Informed:** Support, Release Engineering

## Context

- `ct host` starts an Express + socket.io server (`src/ct/trace/host.nim`, `src/frontend/index/server_config.nim`) and waits indefinitely; there is no watchdog for initial connections or ongoing activity, so orphaned hosts linger until manually killed.
- The backend only invokes `ready()` after the first socket connects (`readyVar` gate in `server_config.nim`), but if no browser attaches the host still runs forever. Once a socket is attached, no liveness is tracked—silent or disconnected clients do not cause the process to exit.
- Only one socket is active at a time; when a second client attaches the first loses its handlers. Today the UI receives no indication that its connection has been superseded.
- CI/cloud environments that spawn hosts headlessly can leak long-lived Node processes when a browser crashes, a tunnel drops, or a test aborts mid-run. Operators currently rely on external supervisors to reclaim them.

## Decision

Introduce a built-in liveness contract between frontend and backend and automatically shut down idle hosts:

1. **Frontend heartbeats:** The web UI (non-Electron/browser mode) emits periodic heartbeat messages over its socket.io connection. Heartbeats carry a monotonic timestamp and lightweight metadata (e.g., tab id, optional trace id) to avoid heavy payloads.
2. **Backend idle timers:** The host tracks (a) time since the last client connection and (b) time since the last inbound message (any event, including heartbeat). If no client connects within the window, or the active connection goes silent, the host exits with status code `0`.
3. **Configurable timeout (default 10 minutes):** Expose a `--idle-timeout=<duration>` flag (and env override) that sets both “no connection” and “no activity” thresholds. The default is 10 minutes; passing `0` or `never` disables auto-exit for debugging runs.
4. **TDD-first coverage:** All new behaviors land with unit and integration tests that drive the heartbeat cadence, silence detection, and exit code semantics before implementation. Browser/Playwright coverage ensures the UI emits heartbeats and the host exits after inactivity in server mode.
5. **User-visible disconnected state:** The frontend surfaces a clear “connection inactive” indicator when (a) the host exits due to idle timeout or (b) the socket is superseded by a newer client/connection. The UI should stop sending commands while disconnected and prompt the user to reconnect/restart as appropriate.

## UX

- Reuse the existing notification system (`NotificationWarning`) for a persistent, top-of-workspace warning when the connection is inactive. The content includes a concise reason (“Host timed out after inactivity” or “Another browser tab took over the connection”) and next steps (“Reload to reconnect”, “Close other tabs or restart `ct host`”). Provide an inline “Reconnect” button wired to reload/reconnect the socket.
- Surface a secondary status badge in the status bar (“Disconnected”) while the socket is inactive, using existing status styling rather than introducing a new component family.
- While the warning is active, disable or gray out actions that require an active socket; guard IPC sends with the familiar inline notification toast to avoid silent drops. Keep controls keyboard accessible and do not auto-dismiss until the connection is restored (successful reconnect clears the warning).

## Alternatives Considered

- **Rely on external supervisors (systemd/k8s) for idle cleanup:** Rejected because we need predictable behavior for local runs, CI agents, and ad hoc `ct host` launches without extra infrastructure.
- **Only watch socket disconnects (no heartbeats):** Rejected; a connected-but-stalled socket would keep the host alive indefinitely, missing the “silent connection” case.
- **Force a hard error exit on timeout:** Rejected; timeouts reflect normal lifecycle (e.g., browser closed), so a clean exit (`0`) is clearer and avoids alarming operators.

## Consequences

- **Positive:** Hosts self-terminate when abandoned, reducing leaked processes and port collisions; operators gain a single knob for liveness policy; browser clients establish an explicit health signal.
- **Negative:** Long-running debugging sessions need to opt out or send heartbeats; misconfigured timeouts could end sessions unexpectedly; users will see explicit disconnected banners when a second client takes over.
- **Risks & Mitigations:** Clock skew or paused tabs could trigger false positives—mitigate with heartbeat jitter tolerance, forgiving grace periods, and clear logs before exit. Thorough TDD coverage and integration tests will pin the behavior to prevent regressions.
