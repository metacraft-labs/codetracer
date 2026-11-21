## plugins_cli.nim — `ct plugins [status]` (Extensibility-Model.md §11.6.5):
## what the Plugins pane shows, from outside a session.
##
## A running session's live state (a breaker's state, strikes, latency) lives
## in that session; this command reads what is on disk: every installed
## package and its plugins, each plugin's switch (`plugins.<id>.enabled`) and
## grant decisions, why a package did not load, and the faults the most recent
## session wrote to its plugin log. The terminal's `:plugins` is the live
## version of the same report.
##
## It reads; it changes nothing (no grant, no setting, no ledger sweep), and it
## starts no plugin process.

import std/[algorithm, json, os, strutils, times]

import ../common/plugin_model
import ./launch/[grant_store, plugin_components]

const PluginsUsage* = "usage: ct plugins [status]"

proc latestPluginLog(): string =
  ## The most recently written session plugin log, or "".
  let stateHome = getEnv("XDG_STATE_HOME", getHomeDir() / ".local" / "state")
  let root = stateHome / "codetracer" / "plugin-logs"
  if not dirExists(root): return ""
  var best: tuple[t: Time, p: string]
  for kind, dir in walkDir(root):
    if kind != pcDir: continue
    let f = dir / "plugins.log"
    if fileExists(f):
      let t = getLastModificationTime(f)
      if best.p.len == 0 or t > best.t:
        best = (t, f)
  best.p

proc pluginsStatus*(startDir = getCurrentDir(); launcherRoot = ""): string =
  ## The report `ct plugins status` prints.
  var lines: seq[string]
  let load = loadPluginPackages(discoverInstalledPlugins(startDir))
  var settings = newJObject()
  try:
    let path = pluginSettingsPath(launcherRoot)
    if fileExists(path): settings = parseJson(readFile(path))
  except CatchableError:
    discard
  let ledger = loadGrantLedger(launcherRoot).ledger
  if load.packages.len == 0:
    lines.add "No plugin packages are installed."
  for lp in load.packages:
    let pkg = lp.package
    lines.add "package " & pkg.name & " " & $lp.installed.component.version &
      "  (" & lp.installed.level & ")  " & lp.installed.dir
    lines.add "  runs " & (lp.installed.dir / pkg.executable)
    for pp in pkg.plugins:
      let m = pp.parsed.manifest
      let entry = settings{"plugins"}{m.id}
      let enabled = entry.isNil or entry{"enabled"}.getBool(true)
      var undecided, refused: seq[string]
      for cap in m.capabilities:
        case ledger.stateOf(m.id, cap)
        of gsUndecided: undecided.add $cap
        of gsRevoked: refused.add $cap
        of gsGranted: discard
      let state =
        if not enabled: "disabled"
        elif refused.len > 0: "refused (" & refused.join(", ") & ")"
        elif undecided.len > 0: "waiting for consent (" & undecided.join(", ") &
          "): open a session and run :plugins review " & m.id
        else: "enabled"
      lines.add "  " & m.id & " " & $m.version & "  " & state
  for e in load.problems:
    lines.add "load error: " & render(e)
  let log = latestPluginLog()
  if log.len > 0:
    var faults: seq[string]
    for l in readFile(log).splitLines:
      if "fault: " in l: faults.add l.split("fault: ", 1)[1]
    lines.add ""
    if faults.len == 0:
      lines.add "The last session (" & log.parentDir.extractFilename &
        ") recorded no plugin fault."
    else:
      lines.add "Faults in the last session (" & log.parentDir.extractFilename & "):"
      for f in faults: lines.add "  " & f
    lines.add "Plugin log: " & log
  lines.join("\n")

proc pluginsCommand*(action: string): int =
  case action
  of "", "status":
    echo pluginsStatus()
    0
  else:
    stderr.writeLine PluginsUsage
    2
