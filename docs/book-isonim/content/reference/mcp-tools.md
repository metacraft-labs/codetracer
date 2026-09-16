---
title: MCP Tool Reference
order: 102
---
## MCP Tool Reference

CodeTracer ships an **MCP (Model Context Protocol) server** that exposes
trace querying as tools for LLM agents. The server is part of the
`backend-manager` binary and communicates over stdio using JSON-RPC 2.0.

Start it with:

```
backend-manager trace mcp
```

Any MCP-compatible client can spawn the process and exchange
newline-delimited JSON-RPC messages on stdin/stdout. See the
`backend-manager` setup guide for Claude Code / Claude Desktop wiring.

This page documents the **value-origin** tools registered by the M8
milestone. For the full tool list see the tool registration in
`src/backend-manager/src/mcp_server.rs`.

### `get_value_origin`

Returns the canonical `OriginChain` for a variable at a chosen source
location: where the value came from, hop by hop, down to the literal,
computation, or parameter that produced it.

The query is anchored at a **source location**, not at a step id. An MCP
call is stateless and `ct/open-trace` rewinds the replay to the program
entry, where no interesting variable is live yet; the tool therefore sets
a breakpoint at `path`:`line`, runs to it, and queries the step it
stopped on — the same sequence the per-language `origin_*_dap_test.rs`
suites use. If the line is never reached, the call fails rather than
answering about whatever step the replay ended on.

For multi-query sessions that reuse one loaded trace, prefer sending a
Python script through the `exec_script` tool and calling
`trace.value_origin("<variable>", step=..., frame=..., max_hops=...)`
inside it. The Python binding composes with `trace.locals()`,
`trace.history()`, breakpoints and watchpoints, and keeps the trace and
classifier pattern set loaded across calls.

#### Input schema

| Field        | Type      | Required | Description                                                                                                                                  |
| ------------ | --------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `trace_path` | `string`  | yes      | Either a local path to a `.ct` trace folder or an observability dive-in URL (see `exec_script` for URL format).                              |
| `path`       | `string`  | yes      | Source file of the query line. May be a suffix of the recorded path (`main.py`); it is resolved against the trace's source file list, and an ambiguous suffix is an error. |
| `line`       | `number`  | yes      | 1-based line to run to before querying. The variable must be live there.                                                                     |
| `variable`   | `string`  | yes      | Variable identifier to query. V1 is identifier-only; dotted paths are reserved for a future milestone.                                        |
| `max_hops`   | `number`  | no       | Maximum hops in this batch (default 16). Backends clamp it to their own tier limit.                                                          |

#### Output shape

The tool returns the spec §3.2 text rendering of the chain followed by
the canonical `OriginChain` JSON (spec §4.1) under a
`Canonical OriginChain JSON:` heading, so an agent can either read it or
parse it:

```
Origin chain for 'c' @ step=7
  hops=3 terminator=literal truncated=no

  0. [=] main.py:12
     c = b
  1. [=] main.py:11
     b = a
  2. [L] main.py:10
     a = 10
  [lit] 10
      @ main
```

Note that a recorded step carries the program state on *entering* a
line, so each hop's `location` is the step at which the value first
becomes observable — one step after the assignment named by that hop's
`sourceText`.

#### Example call

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "tools/call",
  "params": {
    "name": "get_value_origin",
    "arguments": {
      "trace_path": "/traces/my-bug.ct",
      "path": "main.py",
      "line": 12,
      "variable": "c",
      "max_hops": 8
    }
  }
}
```

### `resolve_variable_step`

The first hop of the same chain: where the value a variable holds at
`path`:`line` came from, without walking the rest of the way back. Pair
it with `get_value_origin` when you want the full provenance.

#### Input schema

| Field        | Type     | Required | Description                                            |
| ------------ | -------- | -------- | ------------------------------------------------------ |
| `trace_path` | `string` | yes      | Path to the trace folder (or dive-in URL).             |
| `path`       | `string` | yes      | Source file of the query line (suffix match allowed).  |
| `line`       | `number` | yes      | 1-based line to run to before querying.                |
| `variable`   | `string` | yes      | Variable identifier to resolve.                        |

#### Output shape

```json
{
  "variable": "a",
  "stepId": 5,
  "location": { "path": "main.py", "line": 10, "functionName": "main" },
  "assignment": "    a = 10",
  "originKind": "literal",
  "sourceVariable": null
}
```

`stepId` / `location` are the earliest step at which the variable is
observed holding this value; `assignment` is the statement that produced
it. Because of the entering-a-line step semantics above, `location.line`
is the line *after* the assignment statement — both are reported so the
answer is not ambiguous.

When no assignment can be resolved the call fails with an explicit
message naming the variable. It never answers with an empty success: an
empty answer would be indistinguishable from an unimplemented tool.

#### Example call

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "tools/call",
  "params": {
    "name": "resolve_variable_step",
    "arguments": {
      "trace_path": "/traces/my-bug.ct",
      "path": "main.py",
      "line": 12,
      "variable": "a"
    }
  }
}
```

### Implementation references

| Item                                       | Location                                                              |
| ------------------------------------------ | --------------------------------------------------------------------- |
| Tool table (schemas **and** dispatch)      | `src/backend-manager/src/mcp_server.rs::TOOLS`                        |
| Tool schemas                               | `src/backend-manager/src/mcp_server.rs::get_value_origin_tool`        |
|                                            | `src/backend-manager/src/mcp_server.rs::resolve_variable_step_tool`   |
| Tool handlers                              | `src/backend-manager/src/mcp_server.rs::handle_get_value_origin`      |
|                                            | `src/backend-manager/src/mcp_server.rs::handle_resolve_variable_step` |
| Shared origin query (open / break / walk)  | `src/backend-manager/src/mcp_server.rs::run_origin_query`             |
| Python bridge route (`trace.value_origin`) | `src/backend-manager/src/backend_manager.rs::handle_py_origin_chain`  |
| Response formatters                        | `src/backend-manager/src/python_bridge.rs`                            |
| Wire-shape definitions                     | `src/db-backend/src/task.rs` (Rust) / `python-api/codetracer/origin.py` (Python) |
| End-to-end tests                           | `src/backend-manager/tests/mcp_origin_test.rs`                        |
| Advertise/dispatch divergence check        | `src/backend-manager/tests/mcp_tool_surface_test.rs`                  |

`TOOLS` is the single source of truth for the tool surface: `tools/list`
advertises from it and `tools/call` dispatches from it, so a tool cannot
be advertised without being callable. Add new tools there, never to a
separate list.

For the user-facing walkthrough, see
[Value Origin Tracking](../usage_guide/value-origin-tracking.md).
