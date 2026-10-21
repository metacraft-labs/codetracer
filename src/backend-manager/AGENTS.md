# Backend Manager Development Guide

## Building and Testing

Build:

```bash
cargo build
```

Run tests:

```bash
cargo nextest run
```

Run a single test:

```bash
cargo nextest run --profile single <test_name>
```

Lint:

```bash
cargo clippy
```

## MCP Server Setup

The MCP server exposes CodeTracer trace querying as tools for LLM agents.
It communicates via JSON-RPC 2.0 over stdin/stdout (Model Context Protocol).

### Claude Code Configuration

Add to `.claude/mcp.json` in your project root:

```json
{
  "mcpServers": {
    "codetracer": {
      "command": "backend-manager",
      "args": ["trace", "mcp"],
      "env": {
        "CODETRACER_PYTHON_API_PATH": "/path/to/codetracer/python-api"
      }
    }
  }
}
```

If `backend-manager` is not on your PATH, use the full path to the binary.

### Other MCP Clients

Any MCP-compatible client can connect by spawning `backend-manager trace mcp`
and communicating via stdin/stdout with newline-delimited JSON-RPC 2.0.

### Environment Variables

- `CODETRACER_PYTHON_API_PATH` - The `python-api` directory holding the
  `codetracer` package that `exec_script` imports. When set it is the only
  place used and is trusted as given; a directory without
  `codetracer/__init__.py` is refused before Python starts. When unset, the
  daemon looks only at these layouts (`script_executor::resolve_python_api_path`),
  with `<bin>` the symlink-resolved directory of its executable:
  `<bin>/../share/codetracer/python-api` (install prefix);
  `<repo>/python-api` from `<repo>/src/backend-manager/target/[<triple>/]<profile>/`
  or `<repo>/src/build-{debug,release}/bin/`; and, in debug builds only, the
  checkout it was compiled from (a `CARGO_TARGET_DIR` build). There is no walk
  up the ancestors. A copy found there is used only if every entry in its
  tree (modules, `__pycache__` and bytecode included), the copy itself, and
  every directory up to the prefix or checkout are owned by root or the
  current user and not group- or world-writable, symbolic links followed; a
  refused copy is logged and named on the script's stderr. Otherwise the
  script relies on a `codetracer` package installed in the interpreter's own
  site-packages and, failing that, names
  the places searched. The Nix packages and the AppImage do not ship
  `python-api`.
- The script process runs in the daemon's working directory but never
  imports from it. The daemon starts `python3 -I -B`: isolated mode ignores
  every `PYTHON*` variable (`PYTHONPATH`, `PYTHONHOME`, `PYTHONSTARTUP`, ...)
  and the user's site-packages, and keeps the working directory off
  `sys.path`, so nothing planted there (a `sitecustomize.py`, a `json.py`)
  runs, not even at interpreter start-up. `-B` keeps `__pycache__` out of the
  python-api tree. The daemon also drops `NIX_PYTHONPATH`, which Nixpkgs'
  interpreters read in their own `sitecustomize`, and the wrapper's first
  statement removes any `sys.path` entry naming the working directory as a
  second line of defence. Scripts can import the standard library, the
  interpreter's own site-packages, and the `codetracer` package added from
  `CODETRACER_PYTHON_API_PATH` or the layouts above; `PYTHONPATH` is not a
  way to add more.
- `python3` is looked up only in the absolute entries of `PATH` (in order);
  an empty or relative entry such as `.` is resolved against the daemon's
  working directory and is skipped. There is no override variable: put the wanted
  interpreter's directory earlier in `PATH`. On Windows the same lookup
  looks for `python3.exe`.
- `CODETRACER_CI_BASE_URL` - The codetracer-ci origin (`scheme://host[:port]`)
  that a dive-in URL given as `trace_path` may be fetched from. A URL whose
  host, or whose `gatewayBaseUrl` parameter, names any other origin is
  refused before a connection is opened; unset, every dive-in URL is refused.
- `CODETRACER_GATEWAY_TOKEN` - The bearer token for that gateway, when the
  dive-in URL carries none (`authToken`). It is sent to the configured origin
  only.
- `CODETRACER_GATEWAY_SHARE_TOKEN` - A codetracer-ci share token (the token
  of a Trace share link with download permission), sent as `X-Share-Token`
  when the dive-in URL carries none (`shareToken`). The gateway reads a
  recording for an authenticated caller only with it (or as a signed-in
  member of the recording's tenant). Both tokens must be RFC 6750
  b64tokens.
- `CODETRACER_DAEMON_SOCKET` - Override the daemon socket path (the PID file
  becomes `<socket>.pid`; `socket_path` in the daemon config file does the
  same). The daemon and every client (the `trace` verbs, `daemon
  stop`/`status`/`connect`, the MCP server) resolve it through one function,
  `DaemonConfig::daemon_paths`, so it moves both sides or neither. The Python
  API (`python-api/codetracer/connection.py`, `default_daemon_socket_path`)
  cannot call it and mirrors it instead; `python_daemon_socket_agreement_test`
  fails when the two disagree, so change both together.
- `CODETRACER_DAEMON_SOCK` - The MCP server: connect to the daemon at this
  socket and never auto-start one (used in tests). The daemon also sets it
  for `exec_script`'s Python process, and the Python API connects to it
  ahead of any other resolution.
- `CODETRACER_TMP_PATH`, else `$CODETRACER_HOME/tmp`, else the per-OS default
  (`TMPDIR`-based on Linux) - where the daemon socket and PID file go without
  an override.

### Trace Paths

A local `trace_path` given to an MCP tool (a trace directory, a `.ct`
container or a `--split` slice) may be relative: the MCP server resolves it
against its own working directory before passing it to the daemon, which runs
in a different one.

### Available MCP Tools

- `exec_script` - Execute a Python script against a trace.
- `trace_info` - Get metadata about a trace.
- `list_source_files` - List source files in a trace.
- `read_source_file` - Read a source file from a trace.

### Available MCP Prompts

- `trace_query_api` - Returns the Python Trace Query API reference for LLM context.

### Available MCP Resources

After loading a trace (via `exec_script` or `trace_info`), resources become available:

- `trace:///<trace_path>/info` - Trace metadata (JSON)
- `trace:///<trace_path>/source/<file_path>` - Source file content (text)
