# `ct host` reload resilience – status

## References
- ADR: `0006-ct-host-reload-resilience.md`
- Plan: `ct-host-reload-resilience-implementation-plan.md`
- Testing overview: see “Automated coverage”/“Manual verification” sections in the plan for suite placement.

## Key files
- `src/frontend/index/server_config.nim` — Express/socket.io server wiring; sets `ipc.socket` on connection.
- `src/frontend/index/base_handlers.nim` — IPC plumbing; `FrontendIPC` type and `indexIpcHandlers` macro that currently binds handlers to a single socket.
- `src/frontend/index/ipc_utils.nim` — `ready()` registers handlers and defines the `mainWindow.webContents.send` shim for server mode.
- `src/frontend/index/bootstrap_cache.nim` — cached bootstrap payloads for reconnects with replay ordering helpers.
- `src/frontend/ui_js.nim` — Browser-side socket bootstrap; reconnect path that currently creates a fresh socket on reload.
- `src/frontend/index/electron_vars.nim`/`window.nim` — Globals and send/recv setup that will need to route through the new registry.

## Progress
- Established root cause (handlers pinned to first socket) and documented solution in ADR/plan.
- Added TDD scenarios to the plan for registry/rebind behavior.
- Added headless test scaffold for registry attach/detach (`src/frontend/tests/ipc_registry_test.nim`) and implemented `ipc_registry` with attach/detach bindings; test now passes via `nim js -r src/frontend/tests/ipc_registry_test.nim`.
- Updated `FrontendIPC` to use the new registry, hooked socket attach/detach in `server_config.nim`, and guarded server-side sends via `ipc.emit` when no socket is attached.
- Audited direct socket usage (`rg "ipc.socket"` shows none): all server-mode sends now flow through the registry-aware `emit`.
- Unblocked harness wiring by adding a Tup build rule to emit `tests/ipc_registry_test.js`, so `tester ui` can pick it up once the JS is included in the test set.
- Strengthened the headless unit test to assert handlers fire across reconnects and the old socket is unbound (`src/frontend/tests/ipc_registry_test.nim`).
- Expanded the headless reconnect suite (`src/frontend/tests/test_suites/reload_reconnect.nim`) to cover the remaining Part 1 TDD cases:
  - Attach/detach events are logged during rebinds and `CODETRACER::started` only reaches the latest socket.
  - A mid-request disconnect drops emits gracefully and the next request after reconnect is handled once without panic.
  - Tup emits `tests/reload_reconnect.js`; passes via `nim js -r src/frontend/tests/test_suites/reload_reconnect.nim` and `node src/frontend/tests/test_suites/reload_reconnect.js`.
- Added a browser-level Playwright reload test exercising `ct host` reconnection (`tsc-ui-tests/tests/page-objects-tests/reload_reconnect.spec.ts`); depends on `CODETRACER_TEST_IN_BROWSER=1` to drive browser mode.
- Fixed the runtime `_events` error by binding/unbinding handlers with the socket as `self` in the registry (`frontend/index/ipc_registry.nim`).
- Added a reconnect bootstrap cache: the server send shim now records handshake/init/trace payloads (see `bootstrap_cache.nim`), and `ipc.replayBootstrap` replays the cached messages in handshake-first order when a new socket attaches.
- Extended the headless reconnect suite with a bootstrap replay check to guarantee the latest cached payload is emitted exactly once; still runnable via `nim js -r src/frontend/tests/test_suites/reload_reconnect.nim`.

## Next tasks (Part 2)
- Smoke-test `ct host` reloads to confirm the cached bootstrap whitelist (`started/init/welcome/no-trace/trace-loaded/...`) covers welcome/edit/shell flows; extend caching if any initial UI state is still missing after a reload.
- Wire the cached bootstrap replay into broader automation once stable (tester ui harness pickup + Playwright reload flow) so reconnect coverage runs in CI.
