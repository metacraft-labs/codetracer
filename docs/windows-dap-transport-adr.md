# ADR: DAP Transport Migration from Unix Domain Sockets to Windows Named Pipes

Date: 2026-02-09
Status: Proposed
Owner: Codetracer engineering

## Problem Statement

The current DAP transport path is Unix-domain-socket-first in multiple Rust modules:

- `db-backend` connects through `std::os::unix::net::UnixStream` in `src/db-backend/crates/db-backend-core/src/dap_server.rs`.
- `tui` uses `UnixStream` and a Unix socket path (`ct_dap_socket_<pid>`) in `src/tui/src/dap_client.rs`.
- DAP integration tests bind `UnixListener` and accept `UnixStream` in `src/db-backend/tests/test_harness/mod.rs` and `src/db-backend/tests/dap_backend_server.rs`.
- `backend-manager` also binds `.sock` paths with `tokio::net::UnixListener` in `src/backend-manager/src/backend_manager.rs`.

This blocks a native Windows transport path, because these modules are compiled against Unix-only socket APIs.

## Constraints

- Keep DAP wire compatibility: DAP messages must remain `Content-Length` framed JSON (`src/db-backend/src/transport.rs`, `src/db-backend/src/dap.rs`, `src/tui/src/dap_client.rs`).
- Preserve existing topology for DAP startup: client-side code creates a listening endpoint and `db-backend dap-server` connects to it (evidence in `src/tui/src/dap_client.rs` and test harness listener setup).
- Maintain current `--stdio` fallback in `db-backend` (`src/db-backend/src/main.rs`).
- Keep naming continuity with existing `ct_dap_socket` base (`src/db-backend/crates/db-backend-core/src/dap_server.rs`, `src/common/common_types/debugger_features/debugger.nim`).

## Affected Components

Primary DAP scope (this ADR):

- `src/db-backend/crates/db-backend-core/src/dap_server.rs`
- `src/db-backend/src/main.rs`
- `src/tui/src/dap_client.rs`
- `src/db-backend/tests/test_harness/mod.rs`
- `src/db-backend/tests/dap_backend_server.rs`
- `src/common/common_types/debugger_features/debugger.nim` (socket-name base used by surrounding tooling)

Adjacent socket scope (separate follow-up ADR/task):

- `src/backend-manager/src/backend_manager.rs` (also UnixListener-based, but not required to unblock first DAP Windows path)
- `src/tui/src/main.rs` / `src/tui/src/core.rs` (`ct_socket` core path, not DAP)

## Proposed Interface Boundary

Introduce a transport endpoint abstraction at the connection layer (separate from message serialization):

```rust
pub enum DapEndpoint {
    UnixSocket(std::path::PathBuf),
    WindowsNamedPipe(String),
    Stdio,
}

pub trait DapByteStream: std::io::Read + std::io::Write + Send {}
```

Planned boundaries:

- Add a new endpoint-resolution module in `db-backend` that turns an endpoint into a connected byte stream.
- Refactor `dap_server::run` to call a transport-agnostic `run_with_stream(reader, writer)` routine.
- Keep existing message framing in `dap::read_dap_message_from_reader` and `DapTransport::send` unchanged.
- Add matching endpoint creation/accept helpers for `tui` and test harness so they can create a listener endpoint on both Unix and Windows.

## Windows Named Pipe Design

### Naming

- Canonical pipe name format: `\\\\.\\pipe\\codetracer-ct-dap-socket-{pid}`.
- The `{pid}` suffix preserves current single-session isolation semantics used by `ct_dap_socket_{pid}`.
- Keep a shared helper that maps `(base_name, pid)` to:
  - Unix: filesystem socket path.
  - Windows: named pipe path string.

### Security Defaults

- Default policy: local-machine only and current-user-only client access.
- Reject remote clients by default.
- Do not use world-writable/default-open ACL behavior for production paths.
- Provide an explicit debug override only through an opt-in env var for local debugging.

### Lifecycle

- Listener side (today: `tui` and tests) creates the named pipe endpoint before spawning `db-backend`.
- Connector side (`db-backend dap-server`) retries connection with bounded backoff (matching current retry semantics in `tui` startup behavior).
- On shutdown, close handles explicitly and ensure next start can recreate first pipe instance.

### Error Handling

- Normalize transport errors to actionable categories:
  - endpoint unavailable
  - permission denied
  - timeout waiting for peer
  - broken pipe/disconnect
- Keep stderr logging for diagnostics, and keep stdout clean for stdio DAP mode.

### Reconnect Semantics

- Preserve the current behavior where startup tolerates short races while listener comes up.
- For broken connections, fail the current session cleanly and require session restart (same as current process/session coupling).

## Framing and Protocol Compatibility Requirements

- DAP serialization/parsing logic remains unchanged:
  - outbound `Content-Length: <n>\r\n\r\n<json>`
  - inbound strict `Content-Length` parsing and exact-byte payload read
- No changes to command handling (`initialize`, `launch`, `configurationDone`, etc.) are required by transport migration.
- Regression criteria: same request/response/event ordering observed by existing tests after transport substitution.

## Rollout Plan

### Phase 1: Abstraction + Path Mapping

- Add endpoint abstraction and path/pipe-name helper.
- Refactor db-backend DAP server entry to consume generic byte streams.
- Keep Unix sockets as default on Unix and stdio untouched.

### Phase 2: Windows Named Pipe Wiring (DAP path)

- Implement named-pipe listener/accept in `tui` DAP client path and test harness.
- Implement named-pipe connect path in `db-backend dap_server`.
- Add platform-gated CLI handling where needed (`socket_path` argument semantics become endpoint path/name semantics).

### Phase 3: Tests and CI

- Add Windows-targeted integration tests for connect/startup and launch/configurationDone handshake.
- Add reconnect race test (listener late by small delay) to verify bounded retry behavior.
- Keep Unix tests running unchanged on Linux/macOS.

## Test Strategy

- Unit tests:
  - endpoint mapping (`ct_dap_socket` base + pid -> Unix path / pipe name).
  - transport error classification mapping.
- Integration tests:
  - adapt `src/db-backend/tests/test_harness/mod.rs` to compile and run on Windows with named pipes.
  - keep `src/db-backend/tests/dap_backend_server.rs` protocol assertions and make transport endpoint platform-aware.
- CI:
  - add Windows job that runs DAP transport integration tests (or a focused subset if rr-dependent tests remain Linux-only).

## Risks

- Cross-platform divergence if endpoint logic is duplicated across `tui`, tests, and `db-backend`.
- Named pipe ACL misconfiguration could expose local debug endpoints.
- Startup race regressions if retry/backoff is changed unintentionally.
- Adjacent Unix-socket users (`backend-manager`, non-DAP core sockets) remain unported until follow-up work.

## Fallback Plan

- Keep `--stdio` mode available as an immediate operational fallback.
- Gate named-pipe transport behind platform detection and a temporary feature flag during rollout.
- If Windows named pipes regress, keep Unix/Linux behavior unchanged and temporarily route Windows to stdio while fixing pipe implementation.
