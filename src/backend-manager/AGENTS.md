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
- `CODETRACER_DAEMON_SOCK` - Override the daemon socket path (used in tests).
- `TMPDIR` - Affects where the daemon socket and PID files are created.

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
