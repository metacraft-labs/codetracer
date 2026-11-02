# CodeTracer Extension for Agent Harbor

`extension.toml` packages CodeTracer's MCP server (`session-manager trace mcp`,
see `docs/book/src/reference/mcp-tools.md`) as an Agent Harbor Extension named
`codetracer`. A task that attaches it (`extras.with: ["codetracer"]`) gets the
server under the name `codetracer`, so a tool allow-list names its tools
`mcp__codetracer__trace_info`, `mcp__codetracer__exec_script`, and so on.

## Installing

```sh
ah extras install codetracer --from packaging/agent-harbor/codetracer --yes
ah extras remove codetracer   # only from the default set; the copy stays installed
ah extras options codetracer --scope org \
  --set session_manager=/abs/path/to/session-manager \
  --set replay_server=/abs/path/to/replay-server
```

`install` also adds the Extension to the default set, which attaches it to
every session of that Agent Harbor home. `remove` without `--purge` takes it
out of that set again, so only a task that names it gets it.

The two options name the binaries the agent's session starts; their defaults
are the bare names `session-manager` and `replay-server`, found on the agent's
`PATH`. Agent Harbor keeps one installed copy per Extension name and resolves
a session's request to it by name, so a session relaunched later runs
whatever copy is installed then: install once per environment, from the build
that environment runs.

## What the server is started with

The server is started with no option. It is never given
`--allow-unconfined-scripts` or `--allow-host-source-reads`: without them,
`exec_script` runs scripts confined (and is refused on a host that cannot
confine them; `session-manager trace check-confinement` says whether this host
can), and source reads serve only a recording's own copies of its files.
