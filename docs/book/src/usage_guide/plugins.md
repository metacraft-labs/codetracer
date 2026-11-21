# Plugins

CodeTracer plugins run in their own processes, never inside CodeTracer. A
plugin package ships a native program that hosts one or more plugins;
CodeTracer starts it beside your debugging session when the first of its
plugins is needed, and stops it when the session ends.

## Installing is not accepting

A package is installed with `ct install <name>`. The first time a session sees
it, CodeTracer does **not** start it. The status line says which plugin waits:

    plugin acme-tools.metrics waits for your consent: :plugins review acme-tools.metrics

`:plugins review <id>` shows what the plugin may do. A native package runs a
program with your full authority, and the review says so and lists every
plugin that program hosts. `:plugins grant <id>` records your decision and
starts it; `:plugins disable <id>` keeps it off. Decisions are kept in your
user directory and are removed when the package is uninstalled.

## In the terminal

| Command | What it does |
|---|---|
| `:plugins` | Each plugin's state, strikes, last fault and key-acknowledgement latency |
| `:plugins show <plugin>/<pane>` | A pane a plugin contributes |
| `:plugins run <plugin> <command>` | Run a plugin command (also in the palette) |
| `:plugins enable <id>` / `:plugins disable <id>` | Turn one plugin on or off; its siblings keep running |
| `:plugins re-enable <id>` | Give a stopped plugin another chance |
| `:plugins disable-all` | Stop every plugin for this session |
| `:plugins recover` | Take the keyboard back from every plugin (as triple Escape does) |
| `:plugins bisect`, then `:plugins bisect yes` or `no` | Find the plugin causing a problem |
| `:plugins log` | The plugin log for this session |

The palette lists every plugin command and pane, and four entries no plugin can
shadow: *Plugins: Show status*, *Plugins: Recover input*, *Plugins: Disable all
for this session* and *Plugins: Find the plugin causing a problem*.

Each plugin has its own settings and its own switch, in
`plugin-settings.json` in your CodeTracer user directory:

```json
{ "plugins": { "acme-tools.flame": { "enabled": true, "settings": { "mode": "normal" } } } }
```

## When a plugin misbehaves

A plugin cannot make CodeTracer wait. Keys are decided from what plugins told
CodeTracer earlier; a key routed to a plugin is answered later.

- **A key a plugin does not answer** within half a second is dropped, never
  replayed, and the status line says so:
  `` `j` went to acme-tools.vimish, which did not answer``. Until the plugin
  answers again its key bindings and modal layers are transparent: your next
  key goes where it would have gone without the plugin.
- **Three faults within a minute** (a missed key, an error, a flood of
  messages), or one crash or hang while the plugin held the keyboard, stop the
  plugin: everything it showed or bound is removed, and it is tried again after
  30 seconds, then two minutes, and so on. After its third stop it stays off
  until you re-enable it.
- **A plugin that crashes or hangs** is named: *"Plugin 'acme-tools.flame' was
  stopped: it stopped answering (busy for 5200 ms). Its siblings were
  restarted."* The other plugins of its package are restarted without it. When
  CodeTracer cannot tell which plugin of a package is at fault, it runs each of
  them in a process of its own for the rest of the session.
- **Escape three times within a second** always takes the keyboard back: every
  plugin's modal layer is removed and a dialog lists the plugins that held the
  keyboard. No plugin can bind it, nor the key that opens the palette.
- **Safe mode**: `--no-extensions` (or `CODETRACER_NO_EXTENSIONS=1`) starts no
  plugin process at all.

The plugin's status line label, for example `FLAME MODE (acme-tools.flame)`,
always names the plugin holding the keyboard.
