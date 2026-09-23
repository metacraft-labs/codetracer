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

- `CODETRACER_PYTHON_API_PATH` - Path to the Python API package (required for
  `exec_script` tool to import `codetracer`).
- `CODETRACER_DAEMON_SOCK` - Override the daemon socket path (used in tests).
- `TMPDIR` - Affects where the daemon socket and PID files are created.

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
