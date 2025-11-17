# ADR 0006: Make `ct host` Survive Browser Reloads and Reconnects

- **Status:** Proposed
- **Date:** 2025-11-17
- **Deciders:** Codetracer Runtime & UI Leads
- **Consulted:** Developer Experience, QA Automation
- **Informed:** Support, Release Engineering

## Context

- In server mode we start an Express + socket.io server and set `ipc.socket = client` inside the first `connection` callback (`src/frontend/index/server_config.nim:93-100`). The IPC handler table is registered exactly once during `ready()` (`src/frontend/index/ipc_utils.nim:75-150`) when that first socket is present.
- Handler registration is not resilient: `FrontendIPC.on` binds each handler directly to the current socket instance (`src/frontend/index/base_handlers.nim:16-58`), so the bindings remain attached to the original client object.
- The browser reconnects with a fresh socket every time the user hits Reload or closes/reopens the tab. The UI happily reinitializes and emits events (`src/frontend/ui_js.nim:1789-1834`), but the backend never reattaches its listeners to the new socket, so every request vanishes and the UI appears dead until the host process is restarted.
- Because `ready()` is only invoked for the first client (it is gated by `readyVar` in `setupServer`), later connections never go through the initialization path that would have bound handlers, so we have no natural place to resubscribe.

## Decision

Introduce a connection-aware IPC bridge for `ct host` that keeps handler registration independent from any single socket and automatically rebinds on reconnect:

1. Extend `FrontendIPC` with a registry of handlers and lifecycle methods like `attachSocket`/`detachSocket`. `indexIpcHandlers` should record handlers into this registry and (re)bind them to the currently attached socket instead of wiring them once during the initial connection.
2. On every `socket.io` `connection` event, call `attachSocket` to (a) unregister listeners from the previous socket, (b) bind the full handler registry to the new client, and (c) update outbound senders so `mainWindow.webContents.send` targets the fresh socket without races.
3. Add a small reconnect bootstrap so the next client can obtain state without restarting the host: either re-run the minimal UI bootstrap (config/layout/helpers) when a new socket attaches or respond to the first `CODETRACER::started` from the client by resending the cached state.
4. Surface lifecycle logging/metrics for attach/detach to make reload issues diagnosable in CI and during manual runs.

## Alternatives Considered

- **Tell users not to reload or always restart `ct host`:** Rejected because it is fragile, breaks UI debugging, and makes cloud/browser integrations unusable.
- **Force the browser to reuse the same socket via sticky service workers:** Rejected as brittle and still fails when the tab is closed or network blips occur.
- **Re-run `ready()` wholesale on every connection:** Rejected because it would respawn backend-manager and duplicate state; we only need to rebind IPC, not rebuild the entire process tree.

## Consequences

- **Positive:** Browser reloads and reconnects become first-class; UI tests and manual debugging can refresh without killing the host; clearer observability around connection lifecycle.
- **Negative:** Slightly more complexity in the IPC layer and the need to manage listener teardown to avoid leaks or double-handling.
- **Risks & Mitigations:** Mismanaged rebinding could drop messages or double-handle events; mitigate with explicit detach logic, idempotent bootstrap messaging, and automated tests that cover reload and reconnection flows.
