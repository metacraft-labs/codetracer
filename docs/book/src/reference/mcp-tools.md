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

Returns the canonical `OriginChain` for a queried variable at a chosen
step. This is a one-shot fallback for callers that only want a single
chain — the **preferred** multi-step path is to send a Python script
through the existing `exec_script` tool and call
`trace.value_origin("<variable>", step=..., frame=..., max_hops=...)`
inside it. The Python binding composes with `trace.locals()`,
`trace.history()`, breakpoints and watchpoints, and reuses the loaded
trace + classifier pattern set across calls.

#### Input schema

| Field         | Type      | Required | Description                                                                                                                                                                  |
| ------------- | --------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `trace_path`  | `string`  | yes      | Either a local path to a `.ct` trace folder or an observability dive-in URL (see `exec_script` for URL format).                                                              |
| `variable`    | `string`  | yes      | Variable identifier to query. V1 is identifier-only; dotted paths are reserved for a future milestone.                                                                       |
| `step`        | `integer` | no       | Optional step id. Defaults to the current execution point of the session.                                                                                                    |
| `frame`       | `integer` | no       | Optional DAP frame id. Defaults to the topmost frame.                                                                                                                        |
| `max_hops`    | `integer` | no       | Maximum hops in this batch (default 16). Prefer `lazy` + `continuation_token` over bumping this above ~32.                                                                   |
| `lazy`        | `boolean` | no       | When `true`, the backend may return early with a `continuationToken`. Default `false`.                                                                                       |
| `session_id`  | `string`  | no       | Optional session identifier — when reused across calls the trace and classifier pattern set stay loaded, avoiding a re-load. Same semantics as `exec_script.session_id`.    |

#### Output shape

The tool returns the canonical `OriginChain` JSON pretty-printed in the
MCP text content envelope. The body matches the wire shape from spec
§4.1:

```json
{
  "hops": [
    {
      "kind": "TrivialCopy",
      "stepId": 41,
      "location": { "path": "main.py", "line": 6, "column": 0 },
      "source": "b = helper(a)",
      "frameTransition": { "kind": "ParameterPass", "from": "main", "to": "helper" }
    },
    { "kind": "TrivialCopy", "stepId": 38, "location": { "path": "main.py", "line": 5 }, "source": "a = 10" }
  ],
  "terminator": {
    "kind": "Literal",
    "expression": "10",
    "location": { "path": "main.py", "line": 5 }
  },
  "truncated": false,
  "continuationToken": null,
  "metrics": { "elapsedMs": 12, "hopsWalked": 2 },
  "confidence": 1.0
}
```

When `truncated` is `true`, pass `continuationToken` back as the
`continuationToken` argument on the next call to resume the walk.

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
      "variable": "total",
      "step": 137,
      "max_hops": 8
    }
  }
}
```

### `resolve_variable_step`

Returns the most recent step id at which `variable` was assigned in the
trace. Pair it with `get_value_origin` when you want the chain at the
assignment site rather than the caller's current step.

#### Input schema

| Field        | Type      | Required | Description                                                |
| ------------ | --------- | -------- | ---------------------------------------------------------- |
| `trace_path` | `string`  | yes      | Path to the trace folder (or dive-in URL).                 |
| `variable`   | `string`  | yes      | Variable identifier to look up.                            |
| `frame`      | `integer` | no       | Optional DAP frame id (scopes the search to that frame).   |
| `session_id` | `string`  | no       | Optional session identifier; same semantics as above.      |

#### Output shape

```json
{
  "stepId": 138,
  "variable": "total",
  "location": { "path": "main.py", "line": 53, "column": 4 }
}
```

The formatter scans `ct/load-history` updates in reverse and returns the
first match. When no assignment is found the call fails with the
backend's error message.

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
      "variable": "total"
    }
  }
}
```

### Implementation references

| Item                                       | Location                                                              |
| ------------------------------------------ | --------------------------------------------------------------------- |
| Tool registration                          | `src/backend-manager/src/mcp_server.rs::get_value_origin_tool`        |
|                                            | `src/backend-manager/src/mcp_server.rs::resolve_variable_step_tool`   |
| Tool handlers                              | `src/backend-manager/src/mcp_server.rs::handle_get_value_origin`      |
|                                            | `src/backend-manager/src/mcp_server.rs::handle_resolve_variable_step` |
| Response formatters                        | `src/backend-manager/src/python_bridge.rs`                            |
| Wire-shape definitions                     | `src/db-backend/src/task.rs` (Rust) / `python-api/codetracer/origin.py` (Python) |

For the user-facing walkthrough, see
[Value Origin Tracking](../usage_guide/value-origin-tracking.md).
