# Writing a plugin

A CodeTracer plugin is a native program you build against the plugin SDK. It
runs in its own process beside the debugging session: CodeTracer starts it,
sends it the session's state, and draws what it sends back. One program can
host several plugins; they share the process, and each one is still enabled,
configured and blamed on its own.

This page walks through the `ct-lens` package in `src/plugins/ct-lens/`, which
hosts three plugins:

- **Line history** (`ct-lens.history`) runs `git log -L` on the function the
  debugger is stopped in and shows the commits that changed it, in a pane, on
  the status line, and as a decoration on the function's first line.
- **Changed values** (`ct-lens.watch`) shows what the last step changed, old
  value and new, and binds `F7` to add those values as watches in the
  Variables pane. It also shows Python's `None` as `None`.
- **Jump to call** (`ct-lens.jump`) lists the calls around the current one in
  its pane, where Enter on one jumps to it, and binds `Shift+F7` to a mode that
  numbers them on the status line; a digit jumps and `q` leaves the mode.

What users see of plugins (consent, the `:plugins` commands, what happens when
a plugin misbehaves) is in the [usage guide](../usage_guide/plugins.md).

## The package

A package is a directory with a `plugin.json` and the program:

```text
ct-lens@0.1.0/
  plugin.json
  bin/ct-lens-plugins
```

`plugin.json` names the package, the program, and every plugin the program
hosts:

```json
{
  "package": "ct-lens",
  "host": { "kind": "native", "executable": "bin/ct-lens-plugins" },
  "plugins": [
    { "id": "ct-lens.history", "version": "0.1.0", "capabilities": ["process"], "...": "..." },
    { "id": "ct-lens.watch",   "version": "0.1.0", "capabilities": ["process"], "...": "..." }
  ]
}
```

Rules CodeTracer enforces when it reads the file:

- A plugin's `id` is the package name, or `<package>.<name>`.
- Every plugin of a native package declares the `process` capability, and a
  `traceEgress` entry with `"acknowledged": true` and a `statement`. A native
  program runs with the user's full authority, and the grant screen says so.
- The program's plugin list must equal the manifest's. A plugin listed in one
  and not the other stops the package from loading.
- Each contribution names the views it draws (`"views": ["Tree", "Table",
  "Text"]`). An unknown name is refused, and the error lists the valid ones.
- `settings` is a JSON schema. CodeTracer validates the user's settings
  against it and sends them with `activate` and `settings-changed`.

The contributions a plugin can declare:

| Contribution | What it is | How the plugin fills it |
|---|---|---|
| `pane` | A pane, docked as a tab in the terminal's layout; `:plugins show <plugin>/<pane>` focuses it. Keys and clicks on a list, checkbox, button or tab in it reach the plugin | `pushView(pane, tree)`; `onViewEvent` |
| `command` | An operation, in the palette and `:plugins run <plugin> <op>` | `onInvoke(op, handler)`, plus `pushEnablement` |
| `statusItem` | An entry on the status line (its first line of text) | `pushStatus(item, tree)` |
| `viewModel` `visualisers` | Per-type value summaries, at the plugin tier | `publish("visualisers", rows)` |
| `keybindings` | Keys bound to the plugin's operations, with a `when` clause | the `when` reads context keys you push with `pushContext` |

A plugin whose modal layer takes the whole window's keys declares
`"capturesWindowInput": {"reason": "…"}`. The grant screen shows the reason,
and CodeTracer runs that plugin in a process of its own, apart from the rest
of its package, so its latency and its faults are its own.

## The program

```nim
import codetracer_plugin_sdk

let sdk = newPluginSdk("ct-lens")
let h = sdk.addPlugin("ct-lens.history", "0.1.0")
h.onActivate = proc(p: Plugin) =
  p.pushView("history", viewText("history.message", "waiting for a stop"))
h.onSignals = proc(p: Plugin) =
  let d = p.session.store.debugger.val    # the mirrored debugger state
  p.pushView("history", viewText("history.message",
             "stopped at " & d.location.file & ":" & $d.location.line))
h.onInvoke("history.refresh", proc(p: Plugin; args: JsonNode; req: Request) =
  p.done(req))
sdk.run()
```

What the SDK gives each plugin:

- **`p.session`**: a mirror of the debugging session, the same
  `SessionViewModel` the front-ends use, filled by the host. Read its signals
  (`store.debugger`, `store.stop`, `store.locals.locals`,
  `stateVM.valueChanges`, `stateVM.watchExpressions`, …) in `onSignals`, or in
  effects created in `onActivate`, which are released when the plugin is
  deactivated.
- **`p.relay(vm, action, args)`**: runs an action on the real session, the way
  a click in a front-end does. `ct-lens.watch` calls
  `p.relay("state", "addWatch", %*{"expression": path})`. The actions a
  plugin can relay are the ones `src/frontend/viewmodel/sync/action_relay.nim`
  lists. In the terminal, the six step and continue moves run as the
  terminal's own commands; other actions reach the session but are shown at
  the next stop (a relayed watch's row, a relayed calltrace jump).
- **`pushView`, `pushStatus`, `pushEnablement`, `pushContext`, `publish`,
  `pushLayer`/`popLayer`**: everything a plugin shows or binds is pushed.
  CodeTracer never waits for a plugin to decide what a key does or what a pane
  shows; it uses the last thing you pushed.
- **`p.settings`**, **`p.epoch`** (the position your answer is for), and
  **`p.log(message)`**, which reaches the plugin log.

### Commands, keys and enablement

A command's handler is called with a `Request`. By default the SDK
acknowledges the request before the handler runs, so the user's key is never
reported as unanswered. Finish with `p.done(req)`, `p.answer(req, value)` or
`p.fail(req, message)`.

Until you push enablement for an operation it is disabled ("plugin
starting"). Push it whenever it changes, with a reason when it is off:

```nim
p.pushEnablement("watch.add-changed", pending.len > 0,
                 if pending.len == 0: "every changed value is already watched" else: "")
p.pushContext("hasChanges", %(pending.len > 0))
```

A binding's `when` clause can read your context keys as
`plugin.<plugin id>.<key>`:

```json
"keybindings": [
  { "key": "f7", "command": "watch.add-changed", "scope": "window",
    "when": "plugin.ct-lens.watch.hasChanges" }
]
```

Choose keys the terminal can deliver and the user's keymap leaves free.
`:keys check` shows how a key arrives and what it is bound to. Two traps, as
of this writing: a terminal sends Ctrl+Alt+letter as Escape plus a control
byte, which arrives as Ctrl+letter, so such a binding never fires; and key
names are compared without case, so a binding of `J` also takes `j`.
Function keys avoid both.

### Modal layers

`pushLayer("window", bindings, "jump")` gives the plugin every key its
bindings name until it pops the layer; the mode indicator then reads
`JUMP MODE (ct-lens.jump)`. Pop it as soon as the mode is done, and handle
`onLayerPopped`: CodeTracer pops it too, when the user presses Escape three
times, when the plugin stops answering, and when it is disabled. Leave Escape
unbound if you can: the user's three Escapes are delivered to your layer
first.

If a key you took is not acknowledged within half a second, CodeTracer drops
it and makes your layer transparent until you answer again. With `autoAck`
(the default) the SDK acknowledges before your handler runs, so this happens
only when the whole process stops answering.

Push only when a value changes. `onSignals` runs after every batch of session
state, and a plugin that pushes more than 500 messages a second for five
seconds is stopped for flooding. `ct-lens` keeps a fingerprint of what it last
pushed and returns early when nothing moved.

### Running another program

Handlers run one at a time, on one thread, for every plugin of the package. A
handler that waits for a child process holds every plugin in the program, and
after five seconds CodeTracer stops the process as hung. So start the program
in a handler and collect its output from the SDK's idle loop:

```nim
let runner = newToolRunner()            # src/plugins/ct-lens/lens_tools.nim
sdk.idle.add proc() = runner.pump()
...
let run = runner.start("ct-lens.history", @["git", "-C", dir, "log", ...],
                       dir, timeoutMs = 15_000, proc(r: ToolRun) =
  if r.exitCode == 0: p.pushView("history", treeOf(r.output)))
```

`lens_tools` passes arguments as a list, with no shell; gives the child its own
pipes (a child that inherited the plugin's stdout would write into the protocol
channel); kills a run past its deadline or when you cancel it; and caps the
output. Copy it, or use it as a model. The SDK does not offer these primitives
to a native plugin yet, and an `sdk.idle` hook is not attributed to a plugin:
catch every error in it yourself, or one raised there ends the process and
every plugin in it takes the blame.

**Never write to stdout yourself.** It is the protocol channel: an `echo`
in a plugin is a malformed frame, and the host counts it as a protocol
violation. Write diagnostics with `p.log`, or to stderr, which goes to the
plugin log.

### Panes that answer keys and clicks

A docked pane runs the view vocabulary's own key handling: Enter or a click
on a list row, a checkbox, a button or a tab changes the view, and the
transition reaches the plugin as `onViewEvent(p, surface, event)`.
`event{"transition"}` is `trActivate`, `trSelect` and so on, and
`event{"index"}` names the row. `ct-lens.jump` lists calls in its pane, and a
row activated there is a jump:

```nim
jp.onViewEvent = proc(p: Plugin; surface: string; event: JsonNode) =
  if surface == "calls" and event{"transition"}.getStr("") == "trActivate":
    let at = event{"index"}.getInt(-1)
    if at in 0 ..< listed.len:
      p.relay("calltrace", "doubleClickEntry", %*{"lineIndex": listed[at].lineIndex})
```

### Editor decorations

`pushDecorations(document, items)` sets the plugin's decorations for one
source file (the path the mirrored session names); each item is
`{"line", "glyph", "text", "kind": "marker"}`. The terminal draws the glyph
and text on that line of the source pane, and repeats the one on the current
line on the status line. Push an empty array to clear a document; line
history clears the file it decorated when the debugger moves to another.

### Visualisers

A plugin can publish per-type value summaries as data. The host applies them,
below a project's own visualisers and above the built-in rendering, with no
plugin code running while a pane draws:

```nim
p.publish("visualisers", %*[
  {"id": "function", "typeMatch": "function", "matchKind": "typeName",
   "language": "python", "summary": "function (ct-lens)", "rank": 1}])
```

`summary` is a template over the value's field names (`"{rows}x{cols}"`). The
plugin must declare `{"viewModel": [{"id": "visualisers", "version": "1.0.0"}]}`
in its contributions, or the rows are ignored.

## Building

The SDK is `src/plugin_sdk/codetracer_plugin_sdk.nim`. From the root of a
CodeTracer checkout, whose `config.nims` puts the SDK's own dependencies on the
path:

```bash
nim c --threads:on --mm:orc -d:release \
  --path:src/plugin_sdk \
  -o:build/plugins/ct-lens@0.1.0/bin/ct-lens-plugins \
  src/plugins/ct-lens/ct_lens_plugins.nim
cp src/plugins/ct-lens/plugin.json build/plugins/ct-lens@0.1.0/
```

`--threads:on` is required: the SDK answers the host's liveness pings from a
second thread, so that a plugin stuck in a handler can still be named.

## Installing

Add a directory of components to the search to try a package without
installing it:

```bash
CODETRACER_COMPONENTS_PATH=$PWD/build/plugins ct replay --ui=tui --trace-folder <recording>
```

To install it the way users will, publish it to a mirror that
`ct install` reads, as `<mirror>/<name>/<version>/<name>-<version>-<platform>.tar.gz`
with a `.sha256` beside it, and run `ct install ct-lens` with
`CODETRACER_REGISTRY_PATH` and `CODETRACER_BOOTSTRAP_MIRROR` pointing at the
mirror. `src/ct/launch/plugin_distribution_e2e_test.nim` builds such a mirror
with `tar` and `sha256sum`.

The first session that sees the package asks for consent: `:plugins review
ct-lens.history`, then `:plugins grant ct-lens.history`, once per plugin.

## Debugging

- `:plugins` shows each plugin's state, strikes, last fault and
  acknowledgement latency.
- `:plugins log` shows the plugin log: the program's stderr, every `p.log`,
  and every fault. It is kept under
  `$XDG_STATE_HOME/codetracer/plugin-logs/<session>-<pid>/`.
- A `CatchableError` a handler raises is reported as that plugin's error and
  counts as a strike; three in a minute stop the plugin. The SDK does not catch
  errors raised in an `sdk.idle` hook: catch them yourself, as
  `lens_tools.ToolRunner.onError` does, or they end the process.
- `:plugins disable <id>` turns one plugin off; its siblings keep running in
  the same process.
- After three Escapes, a plugin that held a layer reads `not responding`
  until its watchdog next answers with no handler running, usually within a
  second or two; `:plugins re-enable <id>` does it at once.

## Testing

`src/frontend/viewmodel/tests/unit/test_ct_lens_plugins.nim` starts the real
package under the real supervisor, with a session the suite drives, and checks
what the host received. `src/frontend/tui/tests/real_terminal/test_ct_lens_plugins_pty.nim`
installs it for the shipped terminal and drives it over a pty on a real
recording. Both wait on state rather than time: plugins answer later than the
key that asked, by design.

## Building a WebAssembly plugin

The same SDK builds a plugin to WebAssembly. A WASM package carries one
`plugin.wasm` that every platform runs, and CodeTracer's own `ct-plugin-host`
loads it: one host process per session for every WASM package installed, each
plugin in an instance of its own. A plugin that loops, runs past its deadline or
exhausts its memory loses its instance and nothing else; the host and the other
plugins keep running, and the fault names the plugin.

`ct-lens.watch` is built this way from the same `lens_watch.nim` the native
package uses (`src/plugins/ct-lens/ct_lens_watch_wasm.nim`):

```bash
src/plugin_sdk/build-wasm-plugin.sh src/plugins/ct-lens/ct_lens_watch_wasm.nim \
  build/plugins/ct-lens@0.1.0/plugin.wasm --path:src/plugins/ct-lens
cp src/plugins/ct-lens/wasm/plugin.json build/plugins/ct-lens@0.1.0/
```

Its `plugin.json` names the module instead of an executable:

```json
{
  "package": "ct-lens",
  "host": { "kind": "wasm", "module": "plugin.wasm" },
  "plugins": [ { "id": "ct-lens.watch", "capabilities": ["trace"], "...": "..." } ]
}
```

What changes for the author:

- **Grants are what the plugin uses, possibly none.** A native plugin must
  declare `process`, because it runs with your authority. A WASM plugin
  reaches only what the host's imports offer, so it declares only `fs:read`,
  `fs:write`, `socket:local`, `socket:remote`, `process` or `trace` when it
  needs them.
- **I/O goes through the host.** `import wasm_io` and call `p.readPath`,
  `p.writePath`, `p.runProcess`, `p.connectTcp` or `p.connectUnixSocket`; each
  returns a `Future`, and a refused request completes with `ioRefused` and
  the reason. The module can import nothing else: a module that imports
  anything outside the host's list is refused when it is activated, and the
  refusal names the import.
- **No threads, no signals.** The host answers liveness pings itself, and an
  overrun is cut off by the engine, so a WASM plugin needs neither.
- **`run` returns.** The host calls into the module with each message, so
  the top level builds the SDK, adds the plugins and calls `sdk.run()` as a
  native plugin does, and the call returns at once.

Build `ct-plugin-host` itself with `just build-plugin-host`.

To publish a WASM package, publish one archive,
`<name>-<version>-any.tar.gz`: `ct install` takes the platform's archive when
there is one and the shared `-any` archive otherwise.
