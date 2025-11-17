# `ct host` Reload Resilience – Implementation Plan

This plan tracks the work required to implement ADR 0006 (“Make `ct host` Survive Browser Reloads and Reconnects”).

---

## Part 1 – IPC infrastructure refactor

1. **Handler registry in `FrontendIPC`**
   - Extend `FrontendIPC` with a handler table and `attachSocket`/`detachSocket` helpers that can (re)bind all registered listeners to a given socket.io client.
   - Update `indexIpcHandlers` (and any direct `ipc.on` usages) to store handlers in the registry and delegate binding through `attachSocket` rather than wiring listeners only once during the first connection.
   - Ensure outbound sends (`mainWindow.webContents.send`) check the currently attached socket and no-op or buffer if none is available to avoid crashes during reconnect windows.
   - Tests:
     - Given `ct host` is running and a first socket connects, when the server receives `CODETRACER::open-tab`, then the handler is invoked and a response is emitted through the registry-managed socket.
     - Given `ct host` has an attached socket, when that socket disconnects and a new socket connects, then the registry rebinds handlers and `CODETRACER::open-tab` succeeds without restarting the host.

2. **Lifecycle-safe binding**
   - On `socket.io` `connection`, invoke `attachSocket` to install handlers on the new client and tear down listeners on the previous one to prevent double-handling.
   - Handle `disconnect` by clearing the attached socket, logging the event, and making subsequent sends tolerant until the next client arrives.
   - Tests:
     - Given two consecutive socket connections, when the second attaches, then the server logs detach/attach events and only the new socket receives `CODETRACER::started` responses (no duplicate handling).
     - Given a socket disconnects mid-request, when the next request arrives after reconnect, then it is handled once and no panic occurs from a missing socket.

---

## Part 2 – Reconnect bootstrap

1. **Bootstrap replay**
   - Capture the minimal bootstrap payloads (config, layout, helpers, and initial trace selections) needed by the UI and expose a helper that can resend them to a newly attached socket.
   - Trigger this replay either automatically from `attachSocket` or in response to the first `CODETRACER::started` emitted by the reconnecting client.
   - Tests:
     - Given the UI has loaded layout/config via the first socket, when the page reloads and reconnects, then the server replays layout/config/helpers and the client reaches the same initial screen without manual reload of state.

2. **State idempotency**
   - Audit handlers that mutate shared state to ensure they tolerate multiple invocations or stale/in-flight requests during reconnects.
   - Add logging/metrics around attach/replay to help diagnose broken reload paths in CI.
   - Tests:
     - Given a handler updates shared trace state, when the same request is replayed after reconnect, then the state remains coherent (no duplicate tabs or duplicated trace entries).
     - Given attach/replay runs multiple times, when inspecting logs, then attach/detach/replay entries appear once per connection cycle.

---

## Part 3 – Validation & rollout

1. **Automated coverage**
   - Add a headless test (Nim/JS harness) that launches `ct host`, opens a socket, exercises a representative IPC action (e.g., `CODETRACER::load-recent-trace`), forces a disconnect/reconnect, and asserts the same action still succeeds.
   - Extend UI/browser tests (Playwright/WDIO) with a reload scenario that verifies the UI continues to function and data continues to flow after refreshing the page.
   - Tests:
     - Given the headless harness connects to `ct host`, when it disconnects/reconnects and sends `CODETRACER::load-recent-trace`, then the response arrives both before and after reconnect.
     - Given a browser test loads the host UI, when the page is refreshed, then core interactions (open recent trace, navigate tabs) still succeed and socket reconnects without manual host restart.
   - Implementation notes:
     - Add fast headless coverage under the Nim `tester ui` suite; wire the scenario into the `ui` set so `just test` exercises it (`tester ui reload` for focused runs).
     - Add Playwright coverage under `tsc-ui-tests/tests/` (or C# under `ui-tests/Tests` if preferred); run locally with `just test-e2e -- <filter>` or `direnv exec . dotnet test` for the C# suite.

2. **Manual verification & docs**
   - Document the new reload-safe behavior and any operator-visible logs; include a short reproduction script in `docs/` for manual QA.
   - Perform smoke tests on both Electron-disabled host runs and typical `ct host --port` invocations to confirm attach/detach behavior across platforms.
   - Tests (manual/QA scripts):
     - Given a running host, when following the reproduction script to reload the browser twice, then the UI keeps responding without restarting `ct host`.
     - Given platform smoke tests on macOS/Linux/Windows, when running `ct host --port` and triggering reloads, then attach/detach logs appear and UI actions continue to work.
