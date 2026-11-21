## host/plugin_processes.nim — a native front-end session's plugins
## (Extensibility-Model.md §11): discovered from the installed components,
## resolved, held to the user's grants and settings, and run as native plugin
## processes beside the session by `plugin_host/supervisor`.
##
## The runtime (`app/`) reaches this module only through `PluginsService`'s
## closures, the way it reaches the project definitions: the app half is the
## SDK-consuming half and must not own processes.
##
## ## WHAT HAPPENS AT OPEN
##
## 1. `--no-extensions` (or `CODETRACER_NO_EXTENSIONS`) is read FIRST, by the
##    binary (`extension_selection.planExtensions`): with it off, nothing below
##    runs and no process starts; `:plugins` says why.
## 2. Discovery (`discoverInstalledPlugins`) and the package read
##    (`loadPluginPackages`), which refuses — naming the plugin — a package
##    whose ids are not its component's, a native plugin without `process`,
##    and a third-party native view.
## 3. The grant ledger is swept of plugins no longer installed (so
##    `ct uninstall` leaves no decision behind for a plugin a later install of
##    the same name would inherit), then attached.
## 4. A plugin with a capability nobody has decided is NOT started:
##    installing is not accepting. The status line says which plugin waits,
##    `:plugins review <id>` shows the grant screen, and `:plugins grant <id>`
##    records the user's decision and starts it.
## 5. Every other enabled plugin is activated on `trace-opened`, lazily: its
##    package's process starts when the first of its plugins is activated.

import std/[json, os, sequtils, strutils, tables, times]

import ../../../common/plugin_model
import ../../../ct/launch/[grant_store, plugin_components]
import ../../viewmodel/session_vm
import ../../viewmodel/plugin_host/[host, supervisor]
import ../../../common/view_vocabulary/vocabulary

type
  SessionPlugins* = ref object
    sup*: Supervisor
    host*: PluginHost
    load*: PackageLoad
    settingsPath*: string
    settings*: JsonNode
    awaitingConsent*: seq[string]
    bisect*: Bisect
    problems*: seq[string]
    launcherRoot: string

proc readSettings(path: string): JsonNode =
  try:
    if fileExists(path):
      let j = parseJson(readFile(path))
      if j.kind == JObject: return j
  except CatchableError:
    discard
  %*{"plugins": {}}

proc writeSettings(p: SessionPlugins) =
  try:
    createDir(p.settingsPath.parentDir)
    writeFile(p.settingsPath, p.settings.pretty)
  except CatchableError as e:
    p.problems.add "could not save " & p.settingsPath & ": " & e.msg

proc entryFor(p: SessionPlugins; id: string): JsonNode =
  if p.settings{"plugins"}.isNil or p.settings["plugins"].kind != JObject:
    p.settings["plugins"] = newJObject()
  if not p.settings["plugins"].hasKey(id):
    p.settings["plugins"][id] = newJObject()
  p.settings["plugins"][id]

proc needsConsent(p: SessionPlugins; id: string): bool =
  let s = p.sup.slot(id)
  if s.isNil: return false
  for cap in s.spec.parsed.manifest.capabilities:
    if p.host.grantStateOf(id, cap) == gsUndecided:
      return true
  false

proc refused(p: SessionPlugins; id: string): bool =
  let s = p.sup.slot(id)
  for cap in s.spec.parsed.manifest.capabilities:
    if p.host.grantStateOf(id, cap) == gsRevoked:
      return true
  false

proc nowStamp(): string = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc openSessionPlugins*(session: SessionViewModel; sessionId: string;
                         extensionsEnabled: bool; startDir = getCurrentDir();
                         launcherRoot = ""; frontEnd = "tui";
                         surfaces = feTerminal): SessionPlugins =
  ## The plugins of one primary session (§11.2.1: one plugin-host process per
  ## session, per package). `frontEnd` is what the handshake tells a plugin;
  ## `surfaces` is which front-end's views §6.3 resolves against.
  result = SessionPlugins()
  let p = result
  p.sup = newSupervisor(frontEnd, "1.0.0", extensionsEnabled)
  p.host = newPluginHost(semver(1, 0, 0), frontEnd = surfaces,
                         extensionsEnabled = extensionsEnabled)
  p.launcherRoot = launcherRoot
  p.settingsPath = pluginSettingsPath(launcherRoot)
  p.settings = readSettings(p.settingsPath)
  let stateHome = getEnv("XDG_STATE_HOME", getHomeDir() / ".local" / "state")
  p.sup.logDir = stateHome / "codetracer" / "plugin-logs" /
    (sessionId & "-" & $getCurrentProcessId())
  p.sup.onDisable = proc(id: string; enabled: bool) =
    p.entryFor(id)["enabled"] = %enabled
    p.writeSettings()
  if not extensionsEnabled:
    return
  p.load = loadPluginPackages(discoverInstalledPlugins(startDir))
  for e in p.load.problems:
    p.problems.add render(e)
  var installed: seq[string]
  for lp in p.load.packages:
    p.sup.addPackage(lp.installed.dir, lp.package)
    for pp in lp.package.plugins:
      let id = pp.parsed.manifest.id
      installed.add id
      let sup = p.sup
      p.host.register(pp.text, lp.installed.manifestPath,
        proc(ctx: PluginContext) =
          sup.activate(id)
          ctx.onPluginCleanup(proc() = sup.deactivate(id)))
  for e in p.sup.bindingConflicts():
    p.problems.add render(e)
  # The ledger: swept of uninstalled plugins, then in force.
  let parse = loadGrantLedger(launcherRoot)
  var ledger = parse.ledger
  var swept = false
  for id in ledger.plugins:
    if id notin installed:
      discard ledger.forget(id)
      swept = true
  if swept:
    discard updateGrantLedger(launcherRoot, proc(l: var GrantLedger) =
      for id in l.plugins:
        if id notin installed: discard l.forget(id))
  p.host.attachGrantLedger(ledger)
  p.host.resolveAll()
  for e in p.host.loadErrors():
    p.problems.add render(e)
  for id in installed:
    let entry = p.settings{"plugins"}{id}
    let enabled = entry.isNil or entry{"enabled"}.getBool(true)
    p.sup.configure(id, enabled and not p.refused(id),
                    if entry.isNil: nil else: entry{"settings"})
    if p.needsConsent(id):
      p.awaitingConsent.add id
      p.sup.slot(id).sessionDisabled = true

proc attach*(p: SessionPlugins; session: SessionViewModel; sessionId: string) =
  ## Mirror the session to the plugins and activate those `trace-opened`
  ## reaches (§4.2).
  if p.isNil or not p.sup.extensionsEnabled: return
  p.sup.attachSession(session, sessionId)
  discard p.host.activateFor(ActivationEvent(kind: aeTraceOpened))

proc pump*(p: SessionPlugins): bool =
  ## The idle tick. True when something a front-end shows changed.
  if p.isNil: return false
  var changed = false
  p.sup.onChange = proc() = changed = true
  p.sup.poll()
  changed

proc close*(p: SessionPlugins) =
  if not p.isNil:
    p.sup.shutdown()

# ---------------------------------------------------------------------------
# What the terminal shows
# ---------------------------------------------------------------------------

proc viewLines*(n: ViewNode; indent = 0): seq[string] =
  ## A plugin's view tree as lines of text, for the terminal's content
  ## overlay. Every vocabulary entry has a reading; none is dropped.
  if n.isNil: return
  let pad = repeat(' ', indent)
  case n.kind
  of pkText: result.add pad & n.text
  of pkMarkdown: result.add pad & n.text
  of pkButton: result.add pad & "[ " & n.label & " ]"
  of pkCheckbox, pkToggle:
    result.add pad & (if n.checked: "[x] " else: "[ ] ") & n.label
  of pkInput: result.add pad & n.label & ": " & n.text
  of pkProgressIndicator:
    result.add pad & (if n.progress < 0: "…" else: $n.progress & "%")
  of pkImage: result.add pad & "<" & n.mediaType & ", " & $n.mediaBytes &
    " bytes> " & n.alt
  of pkSelect, pkList, pkMenu, pkTabs:
    for i, o in n.options:
      let mark = if i == n.highlight or i == n.selected: "> " else: "  "
      result.add pad & mark & o.label
  of pkTable:
    if n.columns.len > 0: result.add pad & n.columns.join("  |  ")
    for r in n.rows: result.add pad & r.join("  |  ")
  of pkTree, pkCollapsible, pkModal:
    if n.label.len > 0:
      result.add pad & (if n.children.len > 0:
        (if n.expanded: "▾ " else: "▸ ") else: "  ") & n.label
    if n.expanded or n.kind == pkModal or n.label.len == 0:
      for c in n.children:
        result.add viewLines(c, indent + 2)

proc statusText*(p: SessionPlugins): string =
  ## The plugins' status items, the top plugin layer and its plugin, and the
  ## last sentence about a dropped key, for the status line.
  if p.isNil: return ""
  var parts: seq[string]
  for it in p.sup.statusItems:
    let lines = viewLines(it.tree)
    if lines.len > 0: parts.add lines[0].strip
  if p.awaitingConsent.len > 0:
    parts.add "plugin " & p.awaitingConsent[0] &
      " waits for your consent: :plugins review " & p.awaitingConsent[0]
  parts.join("  ")

proc grantScreen*(p: SessionPlugins; id: string): string =
  ## §11.3's grant screen: what the plugin may do, said plainly, and for a
  ## native package that it runs a program with your authority and every
  ## plugin that program hosts.
  let s = p.sup.slot(id)
  if s.isNil: return "no plugin '" & id & "' is installed"
  let pkg = p.sup.packages[s.package]
  var lines: seq[string]
  lines.add "Plugin " & id & " (package " & pkg.name & ")"
  lines.add ""
  lines.add "This package runs the native program " & pkg.executable &
    " with your full authority: it can read and write your files, run other " &
    "programs and use the network, whatever it says it needs. CodeTracer " &
    "decides only what it sends the program, not what the program does."
  lines.add "The program hosts: " & pkg.plugins.join(", ")
  lines.add ""
  lines.add describeGrants(id, s.spec.parsed.manifest.grants)
  if s.spec.capturesWindowInput:
    lines.add "It may capture the keyboard for the whole window: " &
      s.spec.capturesWindowInputReason
  lines.add ""
  lines.add ":plugins grant " & id & " to allow it, :plugins disable " & id &
    " to keep it off"
  lines.join("\n")

proc grantNow*(p: SessionPlugins; id: string): string =
  if id notin p.awaitingConsent:
    return "plugin '" & id & "' is not waiting for a decision"
  let at = nowStamp()
  let outcome = p.host.acceptDeclaredGrants(id, at, "granted at :plugins grant")
  discard updateGrantLedger(p.launcherRoot, proc(l: var GrantLedger) =
    discard l.grantDeclared(id, p.sup.slot(id).spec.parsed.manifest.capabilities,
                            at, "granted at :plugins grant"))
  p.awaitingConsent.keepItIf(it != id)
  p.sup.slot(id).sessionDisabled = false
  p.sup.activate(id)
  "granted " & id & " (" & $outcome.outcome & ")"

proc control*(p: SessionPlugins; words: seq[string]): tuple[title, body: string] =
  ## `:plugins …`. Answers what to show: a title and a body for the content
  ## overlay, or "" and a one-line note.
  if p.isNil:
    return ("", "plugins are not available in this session")
  let verb = if words.len > 0: words[0] else: ""
  let arg = if words.len > 1: words[1] else: ""
  case verb
  of "", "status":
    var body = p.sup.report()
    for id in p.awaitingConsent:
      body = "Waiting for your consent: " & id & " — :plugins review " & id &
        "\n" & body
    if p.problems.len > 0:
      body.add "\n\nProblems:\n" & p.problems.join("\n")
    if p.sup.notifications.len > 0:
      body.add "\n\nFaults:"
      for n in p.sup.notifications:
        body.add "\n" & n.text & "  [" & n.actions.join("] [") & "]"
    ("PLUGINS", body)
  of "show":
    let tree = p.sup.renderSurface(arg)
    var body = viewLines(tree).join("\n")
    if p.sup.isStale(arg): body = "(stale: computed at an earlier stop)\n" & body
    (arg, body)
  of "run":
    let op = if words.len > 2: words[2] else: ""
    let (enabled, reason) = p.sup.enablementOf(arg, op)
    if not enabled:
      return ("", op & " is unavailable: " & reason)
    let id = p.sup.invoke(arg, op)
    ("", if id.len > 0: "ran " & op else: arg & " is not running")
  of "review":
    ("GRANT " & arg & "?", p.grantScreen(arg))
  of "grant":
    ("", p.grantNow(arg))
  of "disable":
    p.sup.setEnabled(arg, false)
    ("", "disabled " & arg)
  of "enable":
    p.sup.setEnabled(arg, true)
    ("", "enabled " & arg)
  of "re-enable":
    p.sup.reEnable(arg)
    ("", "re-enabled " & arg & " (on probation)")
  of "disable-session":
    p.sup.disableForSession(arg)
    ("", "disabled " & arg & " for this session")
  of "disable-all":
    p.sup.disableAllForSession()
    ("", "all plugins are disabled for this session")
  of "log":
    let path = p.sup.logDir / "plugins.log"
    ("PLUGIN LOG", (if fileExists(path): readFile(path) else: "(empty)"))
  of "recover", "recovery-dialog":
    if verb == "recover":
      # *Plugins: Recover input*: the chord's effect, from the palette.
      for _ in 1 .. RecoveryChordCount: discard p.sup.observeEscape()
    ("RECOVER INPUT", "The plugins that held the keyboard: " &
      (if p.sup.recoveryPlugins.len == 0: "none"
       else: p.sup.recoveryPlugins.join(", ")) &
      "\n\n:plugins disable-session <id>   :plugins disable <id>   " &
      ":plugins disable-all")
  of "bisect":
    if arg in ["yes", "no"]:
      if p.bisect.isNil: return ("", "no bisect is running: :plugins bisect")
      p.sup.answerBisect(p.bisect, problemRemains = arg == "yes")
      if p.bisect.candidates.len <= 1:
        let c = p.bisect.culprit
        p.bisect = nil
        return ("", if c.len > 0: "the plugin causing the problem is " & c
                    else: "no single plugin causes the problem")
    else:
      p.bisect = p.sup.startBisect()
    ("", "step " & $p.bisect.steps & ": disabled " & p.bisect.disabled.join(", ") &
      ". Does the problem remain? :plugins bisect yes|no")
  else:
    ("", ":plugins takes status, show, run, review, grant, enable, disable, " &
         "re-enable, disable-session, disable-all, log, recover or bisect")
