# Windows DAP Transport Migration Checklist

## Milestones

- [x] Add cross-platform endpoint type and endpoint-name helper for `ct_dap_socket` + pid.
- [x] Refactor `db-backend` DAP server startup to use transport-agnostic byte streams.
- [x] Implement Windows named-pipe connector path in `src/db-backend/crates/db-backend-core/src/dap_server.rs`.
- [x] Make `src/tui/src/dap_client.rs` compile on non-Unix via platform gating and explicit unsupported transport errors.
- [x] Implement Windows named-pipe listener/accept in `src/tui/src/dap_client.rs`.
- [x] Make `src/db-backend/tests/test_harness/mod.rs` and `src/db-backend/tests/dap_backend_server.rs` transport-platform-aware.
- [x] Add Windows integration coverage for initialize/launch/configurationDone handshake over named pipes.
  Implemented in `src/tui/src/dap_client.rs` via `windows_named_pipe_start_initialize_launch_sends_configuration_done`, which starts `DapClient::start(...)` against a spawned executable mock backend and validates `initialize()`, `launch(...)`, and `configurationDone` request emission over a real Windows named pipe.
- [x] Validate disconnect/error paths and verify `--stdio` fallback still works unchanged.
  Implemented coverage:
  - `src/tui/src/dap_client.rs` Windows-only tests:
  `windows_named_pipe_start_reports_spawn_error_for_missing_backend_binary` validates backend spawn failure reporting,
  `windows_named_pipe_accept_times_out_without_client_connection` validates listener accept timeout behavior,
  `windows_named_pipe_single_instance_rejects_second_client_while_first_active` validates single-instance/second-client rejection semantics while one client is connected,
  and `windows_named_pipe_start_reconnect_after_clean_teardown_succeeds` validates reconnect-like reuse by running two full start/initialize/launch sessions back-to-back in one process.
  - `src/db-backend/tests/dap_backend_stdio.rs` stdio fallback tests:
  `dap_server_stdio_initialize_handshake_works` validates the initialize response + initialized event path, and
  `dap_server_stdio_disconnect_acknowledges_and_exits` validates a disconnect request/response round-trip plus process termination after disconnect.
  Local execution of these Rust tests in this workspace is currently blocked by missing native build prerequisites (`capnp` and `libs/tree-sitter-nim/src/parser.c`).
- [x] Run Windows named-pipe transport tests in CI.
  Implemented in `.github/workflows/codetracer.yml` as `windows-named-pipe-tests` on `windows-latest`, executing `cargo test --bin simple-tui windows_named_pipe -- --nocapture` in `src/tui`.
