# `ct host` Heartbeats & Idle Shutdown – Implementation Plan

This plan tracks the work required to implement ADR 0007 (“Heartbeats and Idle Shutdown for `ct host`”).

---

## Part 1 – Configuration & plumbing

1. **Idle timeout option**
   - Add `--idle-timeout=<duration>` CLI flag to `ct host` plus `CODETRACER_HOST_IDLE_TIMEOUT` env override. Parse human-friendly durations (e.g., seconds/minutes) and default to 10 minutes.
   - Support a sentinel (`0` or `never`) to disable auto-exit for debugging.
   - Tests:
     - Given `ct host --idle-timeout=5s` with no connections, when the timeout elapses, then the process exits with code `0`.
     - Given `ct host --idle-timeout=0`, when no connections arrive, then the process keeps running past the default window.

2. **Liveness tracking scaffolding**
   - Add an idle watchdog component (server build) that tracks last-connection and last-activity instants, plus a repeating timer that triggers shutdown when both exceed the configured threshold.
   - Ensure the watchdog is resilient to multiple connections: reset last-connection on each new socket and last-activity on any inbound event (including heartbeat).
   - Tests:
     - Given a socket connects and sends a message, when the watchdog is queried, then last-activity reflects that message time.
     - Given multiple reconnects occur, when the watchdog runs, then the most recent attach time is used for the no-connection window.

---

## Part 2 – Frontend heartbeats

1. **Emit periodic heartbeats**
   - In browser/server UI (`ui_js.nim`), send a lightweight `CODETRACER::heartbeat` event every N seconds (configurable findable constant, likely 30–60s) while connected.
   - Include timestamp and optional metadata (tab id / trace id) to aid debugging; avoid heavy payloads.
   - Tests:
     - Given the browser connects to `ct host`, when the heartbeat interval elapses, then the backend receives `CODETRACER::heartbeat` without needing user interaction.
     - Given the tab loses visibility (backgrounded), when timers resume, then a heartbeat is sent within the next interval (guard against total pause in common browsers).

2. **Backend handling**
   - Register a handler for `CODETRACER::heartbeat` that updates last-activity and logs at debug level only.
   - Consider tolerating minor jitter; do not treat late heartbeats alone as fatal—the watchdog covers the exit decision.
   - Tests:
     - Given heartbeats arrive steadily, when the idle watchdog runs, then no exit is triggered.
     - Given heartbeats stop, when the timeout elapses, then the host exits with code `0`.

---

## Part 3 – Silent/absent connection handling

1. **No-connection timeout**
   - Start the watchdog immediately on process launch; if no socket ever attaches within the timeout window, exit cleanly with code `0` and a clear log.
   - Tests:
     - Given `ct host` starts with a 30s timeout and no client connects, when 30s pass, then the process exits with code `0`.

2. **Silent connection timeout**
   - Reset last-activity on every inbound IPC event (not just heartbeats) to tolerate chatty clients.
   - On timeout, emit a final log describing whether we exited due to “no connection” or “no activity”.
   - Tests:
     - Given a client connects and sends one message, when no further messages arrive and the timeout elapses, then the process exits with code `0`.
     - Given a client continues sending any IPC events, when the watchdog runs, then the process remains alive.

---

## Part 4 – Integration & regression coverage

1. **Headless server tests**
   - Add Nim-level integration tests that launch `ct host` in server mode with short timeouts, connect via socket.io (or mimic with JS harness), and assert exits for both no-connection and silent-connection cases.
   - Use TDD: land failing tests first, then implement until passing.
   - Tests:
     - No connection → exit within configured window (assert exit code `0`).
     - Connected + heartbeats → stays alive past window.
     - Connected + silence → exits after window.

2. **Browser/E2E coverage**
   - Add Playwright/WDIO scenarios (or extend existing UI tests) that (a) verify heartbeats are emitted over socket and (b) confirm the host shuts down after intentional silence with a short timeout.
   - Ensure tests run with `CODETRACER_TEST_IN_BROWSER=1` and headless host launch, mirroring existing reload test setup.
   - Tests:
     - Given the browser connects, when observing network traffic, then heartbeat frames appear at the configured cadence.
     - Given a short idle timeout and an intentional pause (no messages), then the host process terminates and the test asserts exit code `0`.

3. **Observability & docs**
   - Add concise logging around heartbeat receipt and idle shutdown decisions to aid debugging without spamming normal runs.
   - Document the new flag/env, defaults, and opt-out behavior in README/cli help.
   - Manual checklist: start host with short timeout, observe auto-exit, and verify disabling timeout keeps it running.

---

## Part 5 – User-facing disconnected state

1. **Detect inactive connection**
   - Propagate socket detach/replace events to the UI layer; when the current socket is superseded or the host exits, raise a “disconnected” state in the frontend model and stop issuing IPC commands.
   - Include the idle-timeout exit path: when the socket closes because the host shut down, surface the same disconnected state.
   - Tests:
     - Given a second client connects (first socket superseded), when the first tab issues an action, then it is blocked and a “connection inactive” indicator is shown.
     - Given the host exits after idle timeout, when the tab is still open, then the UI shows the disconnected indicator/prompt and does not attempt further sends.

2. **User guidance**
   - Render a clear banner/toast/status element explaining the disconnection and suggesting restart/reconnect. Avoid interrupting flow with modal dialogs in automated runs.
   - Tests:
     - UI snapshot/assertion verifies the indicator text appears after disconnect.

3. **UX details**
   - Reuse the existing `NotificationWarning` UI to render a persistent warning near the top of the workspace; include reason text (“Host timed out after inactivity” or “Connection superseded by another tab”) and a primary “Reconnect” action that reloads the page/socket.
   - Add a lightweight “Disconnected” badge in the status bar using current status styles (no new component family).
   - Keep actions that require an active socket disabled or visibly inactive while the warning is present; guard IPC sends with the notification system to avoid silent drops.
   - Ensure focus order and keyboard activation for the warning controls; add aria labels for accessibility.
