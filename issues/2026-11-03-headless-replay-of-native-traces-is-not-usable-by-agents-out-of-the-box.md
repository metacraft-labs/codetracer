# Headless replay of native traces is not usable by agents out of the box

| field       | value |
| ----------- | ----- |
| Status      | open |
| Recorded    | 2026-11-03 |
| Observed in | codetracer `agents` @ `8b62a7103` (`repro exec . -- just build-once`); codetracer-native-backend `agents` @ `088a849f9` (`just build`) |
| Area        | `docs/book/src/reference/ct_cli.md`, `docs/book/src/reference/mcp-tools.md`, `src/ct/codetracerconf.nim` (`TraceCommand`), `src/backend-manager/src/backend_manager.rs`, `src/db-backend/src/recreator_session.rs` (`replay_query_timeout`), target recognition in `ct record` and `db-backend-record` |
| Found by    | CodeTracer-on-Agent-Harbor evaluation (fleet session `ct-ah-eval`) |

The scenario: a fleet agent recorded `ah session list` (Agent Harbor's CLI,
a 2.6 GB debug Rust binary) with `ct record --backend rr`, then tried to
answer questions about it headlessly, as the docs tell an agent to. Each
problem below cost a failed run. Together they mean no agent gets a first
answer without reading the source.

## 1. `ct trace exec` and `ct trace origin` do not exist

The CLI reference and the `session-manager` help both document
`ct trace exec --script <file.py> <trace>`. `ct` rejects it:

```text
$ ct trace exec --script probe.py traces/rr-sl
The subcommand 'trace' does not accept arguments
```

`TraceCommand` in `src/ct/codetracerconf.nim` only has `extract-gfx`,
`export` and `omniscient-prep`. The command lives in the Rust binary as
`trace exec`, `trace query` and `trace mcp`. The MCP docs call that binary
`backend-manager`, but the crate and the binary are now named
`session-manager`. `just build-once` does put it in `src/build-debug/bin/`.

## 2. `replay-server` and `python3` are looked up only on `PATH`

With `src/build-debug/bin` not on `PATH`, `trace exec` fails with
`failed to spawn backend: No such file or directory (os error 2)`. The
daemon log only says `Can't start replay: No such file or directory`, and
never names the program (`backend_manager.rs:2638`). The default is the bare
name `replay-server` (`backend_manager.rs:7053`), not the binary beside
`session-manager`. `python3` must also be on `PATH`
(`python3 was not found in any absolute PATH directory`). The dev shell has
it; a fleet host's tool shell does not.

## 3. The default replay query timeout of 10 s is too short

```text
DAP initialization failed: launch error: "dispatch_replay_query timed out (10s) waiting for worker response to: {\"kind\":\"RunToEntry\"}"
```

LLDB needs about 30 s here just to load the binary.
`CODETRACER_REPLAY_QUERY_TIMEOUT_SECS=600` fixed it, but that variable is
not in the environment table of `ct_cli.md`.

## 4. A script that runs out of time loses all of its output

`session-manager trace exec` returns stdout only on success, and `--timeout`
is capped at 600 s. One slow `trace.step_back()` (see the native-backend
issue `2026-11-03-rr-backend-on-agent-harbor-processes.md`) cost the answers
to every earlier query in the same script. The only error was
`Error: "EOF while reading DAP header"`. The replay worker kept running
afterwards. Workaround: the script writes each answer to a file as soon as it
has it.

## 5. The trace daemon socket is a fixed path shared by all users

`open_trace(..., daemon_socket="/tmp/codetracer/daemon.sock")`. A stale
daemon, started with an older environment, kept serving later runs with that
environment until it was killed. Two agents on one host would share and kill
each other's daemons. The socket belongs under `$XDG_RUNTIME_DIR`.

## 6. Recording a large Rust binary takes 33 to 43 minutes

Measured with `ct record --backend rr -o <dir> ah -- session list`. The
program itself runs in 0.6 s, or 1.2 s under bare `rr record`.

| phase | time |
| ----- | ---- |
| `ct-native-replay recognize` started by `ct` | about 3.5 min |
| `ct-native-replay recognize` again, by `db-backend-record` | 3.5 to 5 min |
| `rr record -n` (the recording itself) | seconds |
| DWARF and source pass in `ct-native-replay record` | about 20 min |
| `rr pack` (copies the 2.6 GB binary into the trace) | minutes |
| total | 33:09 and 42:56 in two runs |

Target recognition runs twice on the same binary. The trace is 3.1 GB
apparent (1.1 GB on ZFS), almost all of it the packed binary and its
libraries.

## 7. `processes()` is unsupported for rr traces

`trace.processes()` fails with `command ct/list-processes not supported
here` on an rr trace, although the worker answers `GetProcessInfo`. An rr
trace of a real service is usually multi-process.

## 8. The DAP init step timeout is hard-coded at 120 s

`backend_manager.rs` sets `let dap_timeout = Duration::from_secs(120);` for
each DAP init step, with no override. Replaying the recorded Agent Harbor
daemon, LLDB took 96 s just to place the entry breakpoint on the 2.6 GB
binary. Under host load the run to entry then passed 120 s and the trace
failed to open with `DAP init timed out at step: stopped-event`. Unlike
`CODETRACER_REPLAY_QUERY_TIMEOUT_SECS`, nothing raises it. (The evaluation
patched it locally to read `CODETRACER_DAP_INIT_TIMEOUT_SECS`.)

## 9. A failed replay deletes its own logs

The worker and rr logs live in `$XDG_RUNTIME_DIR/codetracer/run-<pid>/`. That
directory is removed when the replay-server exits, so after a failed
`trace exec` the only remaining text is the one-line DAP error. The run
directory of a crashed worker survived; that of one that timed out did not.
Keep the run directory, or copy its logs, when the replay fails.

## Suggested direction

- Wire `ct trace exec|query|mcp|origin` through to `session-manager`, or fix
  the docs.
- Resolve `replay-server` beside the running binary first.
- Scale the default query timeout, or make it per trace.
- Stream script output, or return partial output on timeout, and stop the
  worker.
- Put the daemon socket under `$XDG_RUNTIME_DIR`.
- Reuse the recognition result between `ct` and `db-backend-record`.
