## plugin_host_probe.nim — prints the `ct-plugin-host` a front-end running
## from this executable's directory would use: `plugin_host_path.findPluginHost`,
## the same call the terminal and GPUI make (`host/plugin_processes.nim`).
## `test_plugin_host_wasm.nim` installs it as a release-layout component's
## binary to ask where that layout's host is.
import ../../../../../common/plugin_host_path
echo findPluginHost()
