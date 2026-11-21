## plugins_cli_test.nim — `ct plugins status` (Extensibility-Model.md §11.6.5)
## over a real components root, a real grant ledger, a real settings file and
## a real session plugin log, laid out on disk the way `ct install`, the
## terminal and the supervisor write them.
##
## No mocks. The package's executable is an empty file: this command reads
## what is installed and never starts a plugin, which the last case asserts.

import std/[json, os, strutils, tempfiles, unittest]

import ../common/plugin_model
import ./launch/grant_store
import ./plugins_cli

var checks = 0
template ck(cond: untyped) =
  inc checks
  check cond

const Package = """{
  "package": "acme-tools",
  "host": { "kind": "native", "executable": "bin/acme-tools-plugins" },
  "plugins": [
    { "id": "acme-tools.metrics", "version": "1.0.0", "capabilities": ["process"],
      "traceEgress": { "acknowledged": true,
        "statement": "a native plugin process runs with your authority; this one keeps what it reads here" } },
    { "id": "acme-tools.flame", "version": "1.0.0", "capabilities": ["process"],
      "traceEgress": { "acknowledged": true,
        "statement": "a native plugin process runs with your authority; this one keeps what it reads here" } }
  ]
}"""

proc layout(): tuple[root, components, user, state: string] =
  let root = createTempDir("ct-plugins-status-", "")
  result = (root, root / "components", root / "user", root / "state")
  createDir(result.components / "acme-tools@1.0.0" / "bin")
  writeFile(result.components / "acme-tools@1.0.0" / "plugin.json", Package)
  writeFile(result.components / "acme-tools@1.0.0" / "bin" / "acme-tools-plugins", "")
  createDir(result.user)
  putEnv("CODETRACER_COMPONENTS_ROOT", result.components)
  putEnv("XDG_STATE_HOME", result.state)

suite "ct plugins status":

  test "each plugin with its package, switch and grants; a waiting plugin says how to decide":
    let l = layout()
    writeFile(pluginSettingsPath(l.user),
              $(%*{"plugins": {"acme-tools.flame": {"enabled": false}}}))
    discard updateGrantLedger(l.user, proc(g: var GrantLedger) =
      discard g.grantDeclared("acme-tools.metrics", {capProcess},
                              "2026-11-21T00:00:00Z", "test"))
    let r = pluginsStatus(getCurrentDir(), l.user)
    ck "package acme-tools 1.0.0" in r
    ck "runs " & (l.components / "acme-tools@1.0.0" / "bin" / "acme-tools-plugins") in r
    ck "acme-tools.metrics 1.0.0  enabled" in r
    ck "acme-tools.flame 1.0.0  disabled" in r
    removeDir(l.root)

  test "an undecided capability: waiting for consent, naming the command":
    let l = layout()
    let r = pluginsStatus(getCurrentDir(), l.user)
    ck "acme-tools.metrics 1.0.0  waiting for consent (process)" in r
    ck ":plugins review acme-tools.metrics" in r
    removeDir(l.root)

  test "a package that does not load is reported by plugin, not dropped":
    let l = layout()
    var doc = parseJson(Package)
    doc["plugins"][1]["capabilities"] = %*[]
    doc["plugins"][1].delete("traceEgress")
    writeFile(l.components / "acme-tools@1.0.0" / "plugin.json", $doc)
    let r = pluginsStatus(getCurrentDir(), l.user)
    ck "load error: plugin 'acme-tools.flame'" in r
    ck "process" in r
    removeDir(l.root)

  test "the last session's faults, from its plugin log":
    let l = layout()
    let old = l.state / "codetracer" / "plugin-logs" / "tui-1-1"
    let last = l.state / "codetracer" / "plugin-logs" / "tui-2-2"
    createDir(old)
    createDir(last)
    writeFile(old / "plugins.log", "[1] fault: an older session's fault\n")
    sleep(1100)   # file times are compared; one second apart is unambiguous
    writeFile(last / "plugins.log",
      "[2] start acme-tools pid 7\n" &
      "[3] fault: Plugin 'acme-tools.flame' was stopped: it crashed (the process was killed by signal 11 (SIGSEGV)). Its siblings were restarted.\n")
    let r = pluginsStatus(getCurrentDir(), l.user)
    ck "Faults in the last session (tui-2-2):" in r
    ck "Plugin 'acme-tools.flame' was stopped: it crashed" in r
    ck "an older session's fault" notin r
    removeDir(l.root)

  test "it changes nothing on disk":
    let l = layout()
    let before = readFile(l.components / "acme-tools@1.0.0" / "plugin.json")
    discard pluginsStatus(getCurrentDir(), l.user)
    ck not fileExists(grantLedgerPath(l.user))
    ck not fileExists(pluginSettingsPath(l.user))
    ck readFile(l.components / "acme-tools@1.0.0" / "plugin.json") == before
    removeDir(l.root)

  test "an unknown verb is a usage error":
    ck pluginsCommand("frobnicate") == 2

echo "CHECKS: ", checks
