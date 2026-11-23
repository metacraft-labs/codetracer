## plugin_host/supervisor.nim — plugins run out of process
## (Extensibility-Model.md §11). The host-side half of the plugin protocol:
## it starts each package's native plugin process when the first of its
## plugins is activated, speaks `protocol.nim` to it, keeps what each plugin
## PUSHED (views, status items, decorations, enablement, context keys, layers),
## and supervises the process.
##
## ## NO PLUGIN CODE RUNS HERE
##
## Everything a front-end asks of this module — a surface's tree, a key's
## owner, an operation's enablement — is answered from data the plugin pushed
## earlier. `renderSurface` reads the last tree; `resolveLayerKey` and
## `resolveStaticKey` read the last bindings, enablement and context values.
## Nothing waits for a plugin (§11.7.1). What reaches a plugin afterwards is an
## `invoke` or a `query`, which it may answer late without delaying the next
## key or frame.
##
## ## SUPERVISION (§11.8)
##
## `one_for_one`: each process restarts on its own. `transient`: a process
## that exits after `shutdown`, or after its last plugin was deactivated, is
## not restarted. At most `restartIntensity` restarts in `restartWindowMs`,
## with full-jitter backoff from `restartBaseMs` to `restartCapMs`. Past the
## intensity the process stays stopped and its plugins' breakers latch open,
## unless quarantine can still separate them.
##
## ## FAULTS, ATTRIBUTION AND QUARANTINE (§11.6)
##
## Every fault is attributed to one plugin when the evidence allows — the
## SDK's crash record on stderr, the watchdog's `busy` in the last `pong`, the
## plugin a message named — and otherwise counts against every plugin active in
## the process. Two unattributed faults in one session quarantine the package:
## each of its plugins then runs in its own instance of the executable, so the
## next fault is attributed by construction.
##
## ## THE WASM HOST (§11.9)
##
## Every package whose `host.kind` is `wasm` is served by ONE process, the
## CodeTracer-supplied `ct-plugin-host` (`wasmHost`), started with every such
## package (`--package <dir>`). Its record is `wasmGroup`: one more entry of
## `packages`, named `ct-plugin-host`, whose plugins are the WASM plugins of
## every package. Inside it each plugin has an instance of its own, so a trap,
## an overrun or a memory-limit hit faults that plugin alone: the host reports
## it as a `fault` message (the `instance-faults` feature), the plugin takes a
## strike and loses what it pushed, and the process and its other plugins go
## on. A crash of the host process itself is a process fault, charged to the
## plugin that was executing; a plugin charged with two of them runs in a
## `ct-plugin-host` of its own for the rest of the session, so its neighbours
## are not restarted for it again.
##
## ## INPUT DEFENCES (§11.7)
##
## A key routed to a plugin starts a timer. An `ack` within `ackBudgetMs` is on
## time; later is recorded as slow. No `ack` within `inputDeadlineMs` drops the
## key (never replayed), puts a sentence on the status line, gives a strike,
## and makes the plugin SUSPECT: its layers and bindings are transparent and
## its enablement reads as disabled until its next `ack`.
##
## Each plugin has a circuit breaker (closed / open / half-open). Opening it
## removes everything the plugin pushed, which is what makes "a plugin that
## fails cannot make CodeTracer unusable" hold. Three `Escape`s within a second
## (`observeEscape`, called by a front-end's router BEFORE resolution) pop every
## plugin layer and open the recovery dialog. The plugins that held a layer
## become suspect too, but the chord is no evidence about them, so the host
## pings each of their processes at once; the pong to a ping sent after the
## chord, whose watchdog names no busy handler, gives a plugin its bindings
## and enablement back. A plugin that was already suspect from a missed input
## deadline stays suspect until its `ack`: a pong does not launder evidence.
##
## ## TIME
##
## Every timer reads `now()`, a monotonic millisecond clock the caller may
## replace. The thresholds are fields with §11's values as defaults, so a test
## that is not ABOUT a threshold can widen it on a machine whose load is above
## 100 and still wait on state rather than on time.

import std/[algorithm, json, math, random, strutils, tables, monotimes]
when defined(js):
  import std/jsffi
  import ../../../common/node_os
else:
  import std/[os, posix, times]

import isonim/core/[computation, owner, signals]

import ../../../common/plugin_model
import ../../../common/view_vocabulary/vocabulary as view_vocabulary
import ../../../common/value_presentation/presenter as value_presenter
import ../../../common/value_presentation/vocabulary as value_vocabulary
import ../session_vm
import ../store/replay_data_store
import ../store/stop_timeline
import ../sync/[action_relay, sync_publisher]
import ./protocol
import ./process_link

export protocol.PluginBinding, protocol.Epoch

type
  BreakerState* = enum
    bsClosed = "closed"
    bsOpen = "open"
    bsHalfOpen = "half-open"

  FaultKind* = enum
    fkCrash = "crashed"
    fkHang = "stopped answering"
    fkMissedInput = "missed an input deadline"
    fkProtocol = "broke the plugin protocol"
    fkFlood = "flooded CodeTracer with messages"
    fkHandlerError = "raised an error"
    fkStartFailure = "failed to start"

  Fault* = object
    plugin*: string
      ## "" when the fault could not be attributed.
    package*: string
    kind*: FaultKind
    detail*: string
    atMs*: int64
    action*: string
      ## What the host did about it, in the words the user reads.

  Notification* = object
    plugin*: string
    text*: string
    atMs*: int64
    actions*: seq[string]
      ## `Re-enable`, `Disable`, `Show log`.

  ViewEntry* = object
    tree*: ViewNode
    epoch*: Epoch
    refused*: string
      ## Why the last push was refused; the surface shows the fault node.

  PushedLayer* = object
    token*: string
    plugin*: string
    owner*: string
    label*: string
    bindings*: seq[PluginBinding]
    window*: bool

  PendingKind = enum
    pkInvoke
    pkQuery

  Pending = ref object
    id: string
    plugin: string
    kind: PendingKind
    op: string
    key: string
    fromKey: bool
    startedMs: int64
    deadlineMs: int64
    acked: bool
    cancelled: bool
    finished: bool
    expired: bool

  Answer* = object
    id*: string
    plugin*: string
    kind*: string
      ## `answer`, `rows`, `done` or `error`.
    payload*: JsonNode
    epoch*: Epoch

  PluginSlot* = ref object
    id*: string
    package*: string
    spec*: PackagedPlugin
    enabled*: bool
      ## `plugins.<id>.enabled`. Disabled plugins are never started.
    sessionDisabled*: bool
      ## Disabled for this session only (the recovery dialog, bisect).
    settings*: JsonNode
    settingProblems*: seq[PluginError]
    wanted*: bool
      ## Activation was asked for (§4.2's plan reached it).
    active*: bool
    activating*: bool
      ## `activate` was sent and its `activated` has not come back yet.
    instance: Instance
    breaker*: BreakerState
    strikes*: seq[int64]
    totalStrikes*: int
    openings*: int
    latched*: bool
    reopenAtMs: int64
    halfOpenSinceMs: int64
    suspect*: bool
      ## Its layers and bindings are transparent and its enablement reads
      ## "plugin not responding" (§11.7.4). `suspectByChord` says why.
    suspectByChord*: bool
      ## True when the ONLY reason for `suspect` is the recovery chord
      ## (§11.7.6), which is the user's gesture and no evidence about the
      ## plugin. Such a plugin is probed at once, and the pong to a ping sent
      ## after the chord (`suspectAfterPing`) that names no busy handler
      ## clears it.
      ## False when a missed input deadline made it suspect: that is evidence
      ## the plugin is not answering input, and only its next `ack` (or a
      ## fresh activation, or *Re-enable*) clears it.
    suspectAfterPing*: int
      ## Its process's `pingSeq` when the chord made it suspect (meaningful
      ## with `suspectByChord`). Only the pong to a ping numbered above it
      ## clears the suspicion. A sequence number rather than a time: the
      ## clock may be the caller's and need not advance between a ping sent
      ## just before the chord and the chord itself, and that ping's pong
      ## says nothing about the process after the chord.
    lastFault*: string
    views*: Table[string, ViewEntry]
    status*: OrderedTable[string, ViewNode]
    decorations*: Table[string, JsonNode]
    truncatedDecorations*: int
    enablement*: Table[string, tuple[enabled: bool, reason: string, epoch: Epoch]]
    context*: Table[string, JsonNode]
    layers*: seq[PushedLayer]
    published*: Table[string, tuple[batch: JsonNode, epoch: Epoch]]
    ackSamples*: seq[int]
    slowAcks*: int
    tokens: float
    lastRefillMs: int64
    floodSinceMs: int64
    lastDropMs: int64
    droppedMessages*: int
    refusals*: seq[string]
      ## Pushes the host refused, newest last (layers, context keys, trees).
    hostCrashes*: int
      ## Crashes of a shared `ct-plugin-host` charged to this plugin. At
      ## `quarantineAfter` it gets a host process of its own (§11.9).
    instanceFaults*: int
      ## Its WASM instance trapped, overran or hit its limit (§11.9).
    reactivateAtMs: int64
      ## When a WASM plugin whose instance faulted is activated again.
    actionsApplied*: int

  InstanceState* = enum
    isStopped = "stopped"
    isStarting = "starting"
    isRunning = "running"
    isStopping = "stopping"
    isBackoff = "restarting"
    isDead = "stopped for this session"

  Instance* = ref object
    package*: PackageRecord
    label*: string
    dedicated*: string
      ## The one plugin this instance hosts (quarantine, window input), or "".
    link*: ProcessLink
    state*: InstanceState
    startedMs: int64
    helloSeen: bool
    registered*: seq[string]
    lastPingMs: int64
    pingOutstanding: bool
    bytesAtPing: int
      ## `link.bytesRead` when the outstanding ping was sent (or when the
      ## deadline last restarted on received bytes).
    pingSeq: int
    pongs*: int
      ## Pongs received over this instance's life, for the report and the
      ## suites (a test that asserts something survives pongs counts them).
    busy*: string
    busyMs*: int
    restartTimes: seq[int64]
    attempt: int
    nextStartMs: int64
    stopDeadlineMs: int64
    stopPhase: int
    pendingFault: tuple[set: bool, kind: FaultKind, plugin, detail: string]
    starts*: int
    features*: seq[string]
      ## What the process announced in its `hello` (§11.4.3).

  PackageRecord* = ref object
    name*: string
    dir*: string
    executable*: string
    spec*: PluginPackage
    plugins*: seq[string]
    quarantined*: bool
    unattributedFaults*: int
    loadErrors*: seq[string]
    instances*: seq[Instance]
    wasm*: bool
      ## A WASM package: its plugins run in `ct-plugin-host` (`wasmGroup`).
    args*: seq[string]
      ## Arguments the process is started with (`ct-plugin-host`'s packages).

  Supervisor* = ref object
    now*: proc(): int64
    frontEnd*: string
    version*: string
    platform*: string
    extensionsEnabled*: bool
    allDisabledForSession*: bool
    packages*: OrderedTable[string, PackageRecord]
    slots*: OrderedTable[string, PluginSlot]
    session*: SessionViewModel
    sessionId*: string
    position*: int64
    lastStop: string
    publisher: SyncPublisher
    disposeRoot: proc()
    deferred: seq[proc()]
    pending: OrderedTable[string, Pending]
    nextId: int
    answers*: seq[Answer]
    staleDropped*: int
    faults*: seq[Fault]
    notifications*: seq[Notification]
    statusLine*: string
      ## The last sentence for the status line (a dropped key, a refusal).
    logDir*: string
    env*: seq[(string, string)]
      ## Extra environment for every plugin process.
    reservedKeys*: seq[string]
    escapeTimes: seq[int64]
    recoveryOpen*: bool
    recoveryPlugins*: seq[string]
    hostModalOpen*: proc(): bool
    onDisable*: proc(id: string; enabled: bool)
      ## Persist `plugins.<id>.enabled` (the user's *Disable*).
    onChange*: proc()
      ## Something a front-end shows changed.
    actionHook*: proc(msg: JsonNode): bool
      ## A front-end's own route for a relayed action, tried before the
      ## session's `applyAction`; true when it took the action. A front-end
      ## whose loop drives the debugger's moves itself (the terminal pumps each
      ## move to its stop) takes the debugger's moves here, so a plugin's step
      ## is a step like a key's.
    rng: Rand
    # thresholds (§11.4.7, §11.6.2, §11.7.4, §11.7.5, §11.8)
    helloDeadlineMs*: int
    pingIdleMs*: int
    pingBusyMs*: int
    pongDeadlineMs*: int
    busyHangMs*: int
    ackBudgetMs*: int
    inputDeadlineMs*: int
    strikeWindowMs*: int
    strikesToOpen*: int
    breakerBackoffMs*: int
    breakerBackoffCapMs*: int
    halfOpenProbationMs*: int
    openingsToLatch*: int
    restartIntensity*: int
    restartWindowMs*: int
    restartBaseMs*: int
    restartCapMs*: int
    messagesPerSecond*: float
    messageBurst*: float
    floodStrikeAfterMs*: int
    quarantineAfter*: int
    shutdownGraceMs*: int
    termGraceMs*: int
    events*: seq[string]
      ## A trace of what the supervisor did, for the plugin log and tests.
    wasmHost*: string
      ## The `ct-plugin-host` executable that hosts every WASM package.
    wasmHostArgs*: seq[string]
      ## Extra arguments for it (`--memory-mb`, `--call-deadline-ms`, …).
    wasmGroup*: PackageRecord
      ## The record of the one process that hosts every WASM package (nil
      ## until a WASM package is added).

const
  WasmHostPackage* = "ct-plugin-host"
    ## The package name `ct-plugin-host` gives in its `hello`.
  InstanceFaultsFeature* = "instance-faults"
    ## Announced by a host whose plugins can fault one at a time (§11.9).
  FloodQuietMs* = 1_000
    ## A breach of the message bucket ends after this long without a drop.
  RecoveryChordCount* = 3
  RecoveryChordWindowMs* = 1_000
  RecoveryChordSpellings* = ["escape escape escape", "esc esc esc"]

proc monotonicMs*(): int64 = getMonoTime().ticks div 1_000_000

proc newSupervisor*(frontEnd: string; version = "0.0.0";
                    extensionsEnabled = true;
                    now: proc(): int64 = nil): Supervisor =
  Supervisor(
    now: (if now.isNil: monotonicMs else: now),
    frontEnd: frontEnd, version: version, platform: hostOS & "-" & hostCPU,
    extensionsEnabled: extensionsEnabled,
    packages: initOrderedTable[string, PackageRecord](),
    slots: initOrderedTable[string, PluginSlot](),
    pending: initOrderedTable[string, Pending](),
    rng: initRand(0x5eed),
    reservedKeys: @["ctrl+shift+p"],
    helloDeadlineMs: HelloDeadlineMs, pingIdleMs: PingIdleIntervalMs,
    pingBusyMs: PingBusyIntervalMs, pongDeadlineMs: PongDeadlineMs,
    busyHangMs: BusyHangMs, ackBudgetMs: AckBudgetMs,
    inputDeadlineMs: InputDeadlineMs, strikeWindowMs: 60_000,
    strikesToOpen: 3, breakerBackoffMs: 30_000,
    breakerBackoffCapMs: 30 * 60_000, halfOpenProbationMs: 60_000,
    openingsToLatch: 3, restartIntensity: 3, restartWindowMs: 5 * 60_000,
    restartBaseMs: 250, restartCapMs: 30_000,
    messagesPerSecond: MaxMessagesPerSecond.float,
    messageBurst: MaxMessageBurst.float,
    floodStrikeAfterMs: FloodStrikeAfterMs, quarantineAfter: 2,
    shutdownGraceMs: ShutdownGraceMs, termGraceMs: TermGraceMs)

proc changed(sup: Supervisor) =
  if not sup.onChange.isNil:
    sup.onChange()

proc note(sup: Supervisor; line: string) =
  sup.events.add line
  if sup.logDir.len > 0:
    when defined(js):
      try:
        createDir(sup.logDir)
        appendFileBytes(sup.logDir / "plugins.log",
                        "[" & $sup.now() & "] " & line & "\n")
      except CatchableError:
        discard
    else:
      try:
        createDir(sup.logDir)
        let f = open(sup.logDir / "plugins.log", fmAppend)
        f.writeLine("[" & $sup.now() & "] " & line)
        f.close()
      except CatchableError:
        discard

proc clearSuspect(s: PluginSlot) =
  ## Every place that ends a suspicion ends both its halves, so a later
  ## suspicion never inherits a stale reason.
  s.suspect = false
  s.suspectByChord = false

proc slotsOf(inst: Instance; sup: Supervisor): seq[PluginSlot] =
  for id in inst.package.plugins:
    let s = sup.slots[id]
    if s.instance == inst:
      result.add s

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

proc addPackage*(sup: Supervisor; dir: string; pkg: PluginPackage):
    PackageRecord {.discardable.} =
  ## Register an installed package. Its plugins are known, enabled by default
  ## and not running; `activate` starts them.
  result = PackageRecord(name: pkg.name, dir: dir,
                         executable: dir / pkg.executable, spec: pkg)
  for pp in pkg.plugins:
    let id = pp.parsed.manifest.id
    result.plugins.add id
    sup.slots[id] = PluginSlot(id: id, package: pkg.name, spec: pp,
                               enabled: true, settings: newJObject(),
                               floodSinceMs: -1, tokens: sup.messageBurst,
                               lastRefillMs: sup.now())
  sup.packages[pkg.name] = result
  if pkg.hostKind == phkWasm:
    # One process for every WASM package (§11.9): the group's record holds
    # its instances, and lists every WASM plugin, so its `hello` is checked
    # against all of them.
    result.wasm = true
    result.executable = dir / pkg.executable
    if sup.wasmGroup.isNil:
      sup.wasmGroup = PackageRecord(name: WasmHostPackage,
                                    executable: sup.wasmHost)
      sup.packages[WasmHostPackage] = sup.wasmGroup
    for id in result.plugins:
      if id notin sup.wasmGroup.plugins:
        sup.wasmGroup.plugins.add id
    sup.wasmGroup.args.add @["--package", dir]

proc setRateLimit*(sup: Supervisor; perSecond, burst: float) =
  ## §11.4.7's bucket, for every plugin, each bucket refilled to `burst` now.
  sup.messagesPerSecond = perSecond
  sup.messageBurst = burst
  for s in sup.slots.values:
    s.tokens = burst
    s.lastRefillMs = sup.now()

proc slot*(sup: Supervisor; id: string): PluginSlot =
  sup.slots.getOrDefault(id, nil)

proc hostInstance*(s: PluginSlot): Instance =
  ## The process instance that hosts the plugin now (nil when none).
  if s.isNil: nil else: s.instance

proc configure*(sup: Supervisor; id: string; enabled: bool;
                settings: JsonNode = nil) =
  ## The user's `plugins.<id>.enabled` and `plugins.<id>.settings`.
  let s = sup.slot(id)
  if s.isNil: return
  s.enabled = enabled
  s.settingProblems = @[]
  s.settings = validateSettings(s.spec, settings, s.settingProblems)

# ---------------------------------------------------------------------------
# The primary session and the epoch
# ---------------------------------------------------------------------------

proc epoch*(sup: Supervisor): Epoch =
  Epoch(session: sup.sessionId, position: sup.position,
        revision: (if sup.publisher.isNil: 0 else: sup.publisher.revision))

var sendFailures*: int
  ## Frames the host could not queue (over the cap, or a child that stopped
  ## reading). Counted for the report and the suites.

proc sendTo(inst: Instance; msg: JsonNode) =
  if not inst.link.isNil and inst.state in {isStarting, isRunning, isStopping}:
    if not inst.link.send(msg):
      inc sendFailures

proc sendPing(inst: Instance; t: int64) =
  ## §11.6.2's liveness ping. One is outstanding at a time, so the pong that
  ## answers it is the next pong, and `lastPingMs` is when it was sent.
  inc inst.pingSeq
  inst.pingOutstanding = true
  inst.lastPingMs = t
  inst.bytesAtPing = inst.link.bytesRead
  inst.sendTo(%*{"type": "ping", "seq": inst.pingSeq})

proc broadcastState(sup: Supervisor; msg: JsonNode) =
  var m = msg
  m["epoch"] = sup.epoch.toJson
  for pkg in sup.packages.values:
    for inst in pkg.instances:
      if inst.state == isRunning:
        var any = false
        for s in inst.slotsOf(sup):
          if s.active: any = true
        if any: inst.sendTo(m)

proc attachSession*(sup: Supervisor; session: SessionViewModel;
                    sessionId: string) =
  ## Mirror `session` to every plugin. Batches are cut in `poll`, after the
  ## position has moved, so a batch never carries the previous stop's epoch.
  sup.session = session
  sup.sessionId = sessionId
  let s = sup
  sup.publisher = createSyncPublisher(session, sessionId,
    proc(msg: JsonNode) = s.broadcastState(msg),
    proc(cb: proc()) = s.deferred.add cb)
  if not session.store.isNil:
    createRoot proc(dispose: proc()) =
      s.disposeRoot = dispose
      createEffect proc() =
        let id = stopIdentityOf(session.store.debugger.val)
        if id != s.lastStop:
          s.lastStop = id
          inc s.position

# ---------------------------------------------------------------------------
# Faults, strikes and the breaker
# ---------------------------------------------------------------------------

proc removePushed(sup: Supervisor; s: PluginSlot; reason: string;
                  tellPlugin: bool) =
  ## §11.6.3 step 2 and §11.7.5's "open": everything the plugin pushed goes.
  for l in s.layers:
    if tellPlugin and not s.instance.isNil:
      s.instance.sendTo(%*{"type": "layer-popped", "plugin": s.id,
                           "token": l.token, "reason": reason})
  s.layers = @[]
  s.enablement.clear()
  s.context.clear()
  s.decorations.clear()
  s.status.clear()

proc backoffFor(sup: Supervisor; openings: int): int64 =
  ## 30 s, then 2 min, doubling, with jitter.
  let base = if openings <= 1: sup.breakerBackoffMs.float
             else: sup.breakerBackoffMs.float * 4.0 * pow(2.0, float(openings - 2))
  let capped = min(base, sup.breakerBackoffCapMs.float)
  int64(capped * (0.8 + sup.rng.rand(0.4)))

proc sendDeactivate(sup: Supervisor; s: PluginSlot)

proc openBreaker(sup: Supervisor; s: PluginSlot; why: string) =
  let wasActive = s.active
  sup.removePushed(s, "breaker-open", tellPlugin = true)
  if wasActive:
    sup.sendDeactivate(s)
  s.breaker = bsOpen
  inc s.openings
  if s.openings >= sup.openingsToLatch:
    s.latched = true
    sup.note("breaker latched open: " & s.id & " (" & why & ")")
  else:
    s.reopenAtMs = sup.now() + sup.backoffFor(s.openings)
    sup.note("breaker open: " & s.id & " (" & why & "), half-open in " &
             $(s.reopenAtMs - sup.now()) & " ms")

proc strike(sup: Supervisor; s: PluginSlot; kind: FaultKind; detail: string;
            heldInput: bool) =
  let t = sup.now()
  s.strikes.add t
  inc s.totalStrikes
  var kept: seq[int64]
  for x in s.strikes:
    if t - x <= sup.strikeWindowMs: kept.add x
  s.strikes = kept
  s.lastFault = $kind & (if detail.len > 0: ": " & detail else: "")
  sup.note("strike " & $s.strikes.len & " for " & s.id & ": " & s.lastFault)
  if s.breaker == bsOpen:
    return
  if s.breaker == bsHalfOpen:
    sup.openBreaker(s, "a strike on probation")
  elif heldInput and kind in {fkCrash, fkHang}:
    sup.openBreaker(s, "a " & $kind & " while it held an input layer")
  elif s.strikes.len >= sup.strikesToOpen:
    sup.openBreaker(s, $s.strikes.len & " strikes within " &
                    $(sup.strikeWindowMs div 1000) & " s")

proc recordFault(sup: Supervisor; pkg: PackageRecord; plugin: string;
                 kind: FaultKind; detail, action: string) =
  let f = Fault(plugin: plugin, package: pkg.name, kind: kind, detail: detail,
                atMs: sup.now(), action: action)
  sup.faults.add f
  let who = if plugin.len > 0: "Plugin '" & plugin & "'"
            else: "A plugin of package '" & pkg.name & "'"
  var text = who & " was stopped: it " & $kind
  if detail.len > 0: text.add " (" & detail & ")"
  text.add ". " & action
  sup.notifications.add Notification(plugin: plugin, text: text,
    atMs: f.atMs, actions: @["Re-enable", "Disable", "Show log"])
  sup.note("fault: " & text)
  sup.changed()

# ---------------------------------------------------------------------------
# Process lifecycle
# ---------------------------------------------------------------------------

proc hostRecordOf(sup: Supervisor; s: PluginSlot): PackageRecord

proc eligible(sup: Supervisor; s: PluginSlot): bool =
  sup.extensionsEnabled and not sup.allDisabledForSession and s.enabled and
    not s.sessionDisabled and s.wanted and s.breaker != bsOpen and
    sup.packages[s.package].loadErrors.len == 0 and
    sup.hostRecordOf(s).loadErrors.len == 0

proc hostRecordOf(sup: Supervisor; s: PluginSlot): PackageRecord =
  ## The record whose process hosts `s`: its package's, or the WASM group's.
  let pkg = sup.packages[s.package]
  if pkg.wasm and not sup.wasmGroup.isNil: sup.wasmGroup else: pkg

proc instanceKeyFor(sup: Supervisor; s: PluginSlot): string =
  let pkg = sup.hostRecordOf(s)
  if pkg.quarantined or s.spec.capturesWindowInput or
     (pkg == sup.wasmGroup and s.hostCrashes >= sup.quarantineAfter):
    s.id
  else: ""

proc instanceFor(sup: Supervisor; s: PluginSlot): Instance =
  let pkg = sup.hostRecordOf(s)
  let key = sup.instanceKeyFor(s)
  for inst in pkg.instances:
    if inst.dedicated == key and inst.state != isDead:
      return inst
  result = Instance(package: pkg, dedicated: key,
                    label: pkg.name & (if key.len > 0: "[" & key & "]" else: ""))
  pkg.instances.add result

proc startInstance(sup: Supervisor; inst: Instance) =
  let pkg = inst.package
  inc inst.starts
  inst.helloSeen = false
  inst.registered = @[]
  inst.busy = ""
  inst.busyMs = 0
  inst.pingOutstanding = false
  inst.pendingFault.set = false
  inst.stopPhase = 0
  if pkg == sup.wasmGroup:
    pkg.executable = sup.wasmHost
    if pkg.executable.len == 0:
      inst.state = isDead
      pkg.loadErrors.add "the WASM packages cannot run: this front-end has " &
        "no " & WasmHostPackage & " (Supervisor.wasmHost)"
      sup.note(pkg.loadErrors[^1])
      return
  try:
    inst.link = spawnPluginProcess(pkg.executable,
                                   args = pkg.args & (if pkg == sup.wasmGroup:
                                                        sup.wasmHostArgs
                                                      else: @[]),
                                   env = sup.env,
                                   workingDir = pkg.dir)
  except CatchableError as e:
    inst.state = isDead
    pkg.loadErrors.add "package '" & pkg.name & "': could not start '" &
      pkg.executable & "': " & e.msg
    sup.note(pkg.loadErrors[^1])
    return
  let logDir = sup.logDir
  let label = inst.label
  inst.link.stderrSink = proc(data: string) =
    if logDir.len > 0:
      when defined(js):
        try:
          createDir(logDir)
          appendFileBytes(logDir / (label & ".stderr.log"), data)
        except CatchableError: discard
      else:
        try:
          createDir(logDir)
          let f = open(logDir / (label & ".stderr.log"), fmAppend)
          f.write(data)
          f.close()
        except CatchableError: discard
  inst.state = isStarting
  inst.startedMs = sup.now()
  inst.lastPingMs = inst.startedMs
  sup.note("start " & inst.label & " pid " & $inst.link.pid)
  if inst.link.launchNote.len > 0:
    # The host's own departure from §11.8 (on Node: no usable `setpriv`, so
    # no PR_SET_PDEATHSIG). Logged, never a fault: no plugin caused it.
    sup.note(inst.label & ": " & inst.link.launchNote)
  inst.sendTo(hostHello(sup.version, sup.frontEnd, sup.platform))

proc sendActivate(sup: Supervisor; s: PluginSlot) =
  let inst = s.instance
  if inst.isNil or inst.state != isRunning or s.active or s.activating:
    return
  var grants = newJArray()
  for c in s.spec.parsed.manifest.capabilities:
    grants.add %($c)
  s.activating = true
  # A fresh activation answers for itself: what it pushes while activating
  # (its layers among them) is not refused for an earlier silence.
  s.clearSuspect()
  # The declared sets travel with the grants, so the SDK's process and
  # socket primitives resolve a program, a host or a path against what the
  # manifest declared (§8.1.1), in the plugin's own process.
  let g = s.spec.parsed.manifest.grants
  var hosts = newJArray()
  for h in g.hosts:
    hosts.add %*{"host": h.host, "port": h.port}
  let declared = %*{"executables": g.executables, "hosts": hosts,
                    "readPaths": g.readPaths, "writePaths": g.writePaths,
                    "traceEgress": {"acknowledged": g.traceEgress.acknowledged,
                                    "statement": g.traceEgress.statement}}
  inst.sendTo(%*{"type": "activate", "plugin": s.id, "grants": grants,
                 "declared": declared,
                 "settings": s.settings, "epoch": sup.epoch.toJson})
  if not sup.publisher.isNil:
    var snap = sup.publisher.snapshot()
    snap["plugin"] = %s.id
    snap["epoch"] = sup.epoch.toJson
    inst.sendTo(snap)

proc stopInstance(sup: Supervisor; inst: Instance; graceful = true)

proc ensureRunning(sup: Supervisor; s: PluginSlot) =
  if not sup.eligible(s):
    return
  let inst = sup.instanceFor(s)
  s.instance = inst
  case inst.state
  of isStopped:
    sup.startInstance(inst)
  of isRunning:
    sup.sendActivate(s)
  else:
    discard

proc sendDeactivate(sup: Supervisor; s: PluginSlot) =
  if not s.instance.isNil and s.active:
    s.instance.sendTo(%*{"type": "deactivate", "plugin": s.id})
  s.active = false
  s.activating = false

proc activate*(sup: Supervisor; id: string) =
  ## §4.2 reached this plugin: start its process if needed and activate it.
  let s = sup.slot(id)
  if s.isNil: return
  s.wanted = true
  sup.ensureRunning(s)

proc stopIfIdle(sup: Supervisor; inst: Instance) =
  if inst.isNil or inst.state notin {isRunning, isStarting}:
    return
  for s in inst.slotsOf(sup):
    if sup.eligible(s):
      return
  sup.stopInstance(inst)

proc deactivate*(sup: Supervisor; id: string) =
  let s = sup.slot(id)
  if s.isNil: return
  s.wanted = false
  sup.removePushed(s, "deactivated", tellPlugin = false)
  sup.sendDeactivate(s)
  sup.stopIfIdle(s.instance)
  sup.changed()

proc setEnabled*(sup: Supervisor; id: string; enabled: bool;
                 persist = true) =
  ## The user enabled or disabled one plugin. Its siblings keep running in
  ## the same process; a process none of whose plugins is enabled stops.
  let s = sup.slot(id)
  if s.isNil: return
  s.enabled = enabled
  if persist and not sup.onDisable.isNil:
    sup.onDisable(id, enabled)
  if not enabled:
    sup.removePushed(s, "disabled", tellPlugin = true)
    sup.sendDeactivate(s)
    sup.stopIfIdle(s.instance)
  else:
    sup.ensureRunning(s)
  sup.changed()

proc settingsChanged*(sup: Supervisor; id: string; settings: JsonNode) =
  let s = sup.slot(id)
  if s.isNil: return
  s.settingProblems = @[]
  s.settings = validateSettings(s.spec, settings, s.settingProblems)
  # An activating plugin was sent `activate` with the settings of that moment.
  # The pipe is ordered, so a change sent now reaches it after its activation;
  # dropping it would leave the plugin on stale settings until it is next
  # activated, although the host already reports the new ones.
  if s.active or s.activating:
    s.instance.sendTo(%*{"type": "settings-changed", "plugin": s.id,
                         "settings": s.settings})

proc stopInstance(sup: Supervisor; inst: Instance; graceful = true) =
  ## §11.8's stop: `shutdown`, grace, SIGTERM to the group, grace, SIGKILL.
  if inst.isNil or inst.link.isNil or inst.state in {isStopped, isDead}:
    return
  for s in inst.slotsOf(sup):
    s.active = false
    s.activating = false
  inst.state = isStopping
  if graceful:
    inst.sendTo(%*{"type": "shutdown"})
    inst.link.flushWrites()
    inst.stopPhase = 1
    inst.stopDeadlineMs = sup.now() + sup.shutdownGraceMs
  else:
    inst.link.signalGroup(SIGKILL)
    inst.stopPhase = 3

proc restartDelay(sup: Supervisor; inst: Instance): int64 =
  let cap = min(float(sup.restartCapMs),
                float(sup.restartBaseMs) * pow(2.0, float(inst.attempt)))
  int64(sup.rng.rand(cap))

proc processFault(sup: Supervisor; inst: Instance; kind: FaultKind;
                  guilty, detail: string) =
  ## §11.6.3: strike, remove what the process pushed, restart without the
  ## plugins whose breaker is open.
  let pkg = inst.package
  let members = inst.slotsOf(sup)
  var guilty = guilty
  if guilty.len == 0 and inst.dedicated.len > 0:
    # An instance that hosts one plugin (quarantine, window input): the fault
    # is attributed by construction (§11.6.4).
    guilty = inst.dedicated
  var heldInput = false
  if guilty.len > 0 and sup.slots.hasKey(guilty):
    heldInput = sup.slots[guilty].layers.len > 0
  for s in members:
    sup.removePushed(s, "process-exited", tellPlugin = false)
    s.active = false
    s.activating = false
  var action = ""
  var moved: seq[PluginSlot]
  if guilty.len > 0 and sup.slots.hasKey(guilty):
    let g = sup.slots[guilty]
    sup.strike(g, kind, detail, heldInput)
    if pkg == sup.wasmGroup and kind in {fkCrash, fkHang} and
       inst.dedicated.len == 0:
      # §11.9: a crash of the shared WASM host, charged to the plugin that was
      # executing. Twice, and that plugin runs in a host of its own.
      inc g.hostCrashes
      if g.hostCrashes >= sup.quarantineAfter:
        moved.add g
        sup.note("quarantine " & g.id & ": it runs in a " & WasmHostPackage &
                 " of its own")
  else:
    inc pkg.unattributedFaults
    for s in members:
      if s.wanted:
        sup.strike(s, kind, detail & " (unattributed)", false)
    if pkg.unattributedFaults >= sup.quarantineAfter and not pkg.quarantined and
       pkg.plugins.len > 1:
      pkg.quarantined = true
      sup.note("quarantine " & pkg.name & ": each plugin in its own process")
  # Restart, under the intensity.
  let t = sup.now()
  var kept: seq[int64]
  for x in inst.restartTimes:
    if t - x <= sup.restartWindowMs: kept.add x
  inst.restartTimes = kept
  var anyToRun = false
  for s in members:
    if sup.eligible(s): anyToRun = true
  for m in moved:
    if sup.eligible(m):
      m.instance = nil
      let ni = sup.instanceFor(m)
      m.instance = ni
      if ni.state == isStopped:
        ni.state = isBackoff
        ni.nextStartMs = t + sup.restartDelay(ni)
  if moved.len > 0:
    action = "It now runs in a " & WasmHostPackage & " of its own. "
  if pkg.quarantined and inst.dedicated.len == 0:
    # The shared instance is retired; each plugin gets its own on restart.
    inst.state = isDead
    for s in members:
      s.instance = nil
    action = "Its plugins now run each in a process of their own."
    for s in members:
      if sup.eligible(s):
        let ni = sup.instanceFor(s)
        s.instance = ni
        if ni.state == isStopped:
          ni.state = isBackoff
          ni.nextStartMs = t + sup.restartDelay(ni)
  elif not anyToRun:
    inst.state = isStopped
    action = "It was not restarted."
  elif inst.restartTimes.len >= sup.restartIntensity:
    inst.state = isDead
    action = "It failed " & $(inst.restartTimes.len + 1) & " times in " &
      $(sup.restartWindowMs div 60_000) & " minutes and stays stopped for " &
      "this session."
    for s in members:
      if s.breaker != bsOpen:
        sup.openBreaker(s, "restart intensity exceeded")
      s.latched = true
  else:
    inst.restartTimes.add t
    inst.state = isBackoff
    inst.nextStartMs = t + sup.restartDelay(inst)
    inc inst.attempt
    action.add(if members.len > 1: "Its siblings were restarted."
               else: "It was restarted.")
  sup.recordFault(pkg, guilty, kind, detail, action)

proc killForFault(sup: Supervisor; inst: Instance; kind: FaultKind;
                  guilty, detail: string) =
  inst.pendingFault = (set: true, kind: kind, plugin: guilty, detail: detail)
  inst.link.signalGroup(SIGKILL)
  inst.state = isStopping
  inst.stopPhase = 3

# ---------------------------------------------------------------------------
# Messages from a process
# ---------------------------------------------------------------------------

proc refuse(sup: Supervisor; s: PluginSlot; what: string) =
  s.refusals.add what
  sup.statusLine = "plugin '" & s.id & "': " & what
  sup.note("refused " & s.id & ": " & what)

proc declaresSurface(s: PluginSlot; surface: string): bool =
  for c in s.spec.parsed.manifest.contributions:
    if c.kind in {ckPane, ckMarker, ckStatusItem} and
       (c.id == surface or s.id & "/" & c.id == surface):
      return true
  false

proc localSurface(s: PluginSlot; surface: string): string =
  if surface.startsWith(s.id & "/"): surface[s.id.len + 1 .. ^1] else: surface

proc isReservedKey*(sup: Supervisor; key: string): bool =
  let k = key.toLowerAscii.strip
  k in sup.reservedKeys or k in RecoveryChordSpellings

proc takeToken(sup: Supervisor; s: PluginSlot): bool =
  let t = sup.now()
  let dt = float(t - s.lastRefillMs) / 1000.0
  s.lastRefillMs = t
  s.tokens = min(sup.messageBurst, s.tokens + dt * sup.messagesPerSecond)
  if s.tokens >= 1.0:
    # A message let through does NOT end the breach: the bucket refills a
    # token between two reads, so a flood interleaves passes with drops. The
    # breach ends after `FloodQuietMs` with no drop at all.
    s.tokens -= 1.0
    return true
  inc s.droppedMessages
  if s.floodSinceMs < 0 or t - s.lastDropMs > FloodQuietMs:
    s.floodSinceMs = t
  s.lastDropMs = t
  if t - s.floodSinceMs >= sup.floodStrikeAfterMs:
    s.floodSinceMs = t
    sup.strike(s, fkFlood, $s.droppedMessages & " messages dropped", false)
    sup.recordFault(sup.packages[s.package], s.id, fkFlood,
      "more than " & $int(sup.messagesPerSecond) & " messages a second for " &
      $(sup.floodStrikeAfterMs div 1000) & " s",
      "Messages past the limit were dropped.")
  false

proc onReply(sup: Supervisor; s: PluginSlot; msg: JsonNode; t: string) =
  let id = msg{"id"}.getStr("")
  if id.len == 0:
    if t == "error":
      sup.strike(s, fkHandlerError, msg{"message"}.getStr(""), false)
    return
  let p = sup.pending.getOrDefault(id, nil)
  if t == "error":
    sup.strike(s, fkHandlerError, msg{"message"}.getStr(""), false)
  if p.isNil or p.plugin != s.id:
    return
  if p.cancelled or p.expired:
    return       # §11.4.6: binding for the host
  let e = epochFrom(msg{"epoch"})
  if p.kind == pkQuery and not samePosition(e, sup.epoch):
    inc sup.staleDropped      # §11.4.5: a stale answer is never shown
    return
  sup.answers.add Answer(id: id, plugin: s.id, kind: t,
                         payload: msg, epoch: e)
  if t in ["answer", "done", "error"]:
    p.finished = true
  sup.changed()

proc onAck(sup: Supervisor; s: PluginSlot; id: string) =
  let p = sup.pending.getOrDefault(id, nil)
  if p.isNil or p.plugin != s.id or p.acked:
    return
  p.acked = true
  let ms = int(sup.now() - p.startedMs)
  s.ackSamples.add ms
  if s.ackSamples.len > 512:
    s.ackSamples.delete(0)
  if ms > sup.ackBudgetMs:
    inc s.slowAcks
  if s.suspect:
    s.clearSuspect()
    sup.note(s.id & " answered again; its layers and bindings are back")
    sup.changed()

proc instanceFault(sup: Supervisor; inst: Instance; msg: JsonNode) =
  ## §11.9: one plugin's WASM instance trapped, overran its deadline or hit
  ## its memory limit, and the host discarded it. The plugin takes a strike
  ## and loses what it pushed; the process and its other plugins go on.
  let id = msg{"plugin"}.getStr("")
  let kind = msg{"kind"}.getStr("")
  let detail = msg{"detail"}.getStr("")
  if not sup.slots.hasKey(id) or id notin inst.registered:
    sup.killForFault(inst, fkProtocol, "",
      "a fault report for plugin '" & id & "', which it does not host")
    return
  let s = sup.slots[id]
  let pkg = sup.packages[s.package]
  if kind == "protocol":
    sup.strike(s, fkProtocol, detail, false)
    sup.recordFault(pkg, id, fkProtocol, detail, "The message was ignored.")
    return
  let fk = case kind
           of "deadline": fkHang
           else: fkCrash
  let what = case kind
             of "deadline": "its call ran past its deadline"
             of "memory-limit": "it reached its memory limit"
             of "exited": "it ended its instance"
             else: "its instance trapped"
  let heldInput = s.layers.len > 0
  sup.removePushed(s, "instance-fault", tellPlugin = false)
  s.active = false
  s.activating = false
  inc s.instanceFaults
  sup.strike(s, fk, what & ": " & detail, heldInput)
  var action = "Its instance was discarded; the other plugins kept running"
  if sup.eligible(s):
    s.reactivateAtMs = sup.now() + max(1, sup.restartDelay(inst))
    action.add ", and it will be started again."
  else:
    action.add "."
  sup.recordFault(pkg, id, fk, what & " (" & detail & ")", action)

proc handleMessage(sup: Supervisor; inst: Instance; msg: JsonNode) =
  let t = msg{"type"}.getStr("")
  if not inst.helloSeen:
    let check = checkProcessHello(msg, inst.package.name, inst.package.plugins)
    if not check.ok:
      inst.package.loadErrors = check.problems
      for p in check.problems: sup.note("load error: " & p)
      sup.stopInstance(inst, graceful = false)
      inst.state = isDead
      sup.changed()
      return
    inst.helloSeen = true
    inst.registered = check.pluginIds
    inst.features = check.features
    inst.state = isRunning
    sup.note("hello from " & inst.label)
    for s in inst.slotsOf(sup):
      if sup.eligible(s):
        sup.sendActivate(s)
    return
  if t == "pong":
    inc inst.pongs
    # Only the answer to the ping that is outstanding is a probe's answer; an
    # unsolicited pong proves nothing about when the process last answered.
    let answeredPing = inst.pingOutstanding
    inst.pingOutstanding = false
    inst.busy = msg{"busy"}.getStr("")
    inst.busyMs = msg{"busyMs"}.getInt(0)
    if inst.busy.len > 0 and inst.busyMs > sup.busyHangMs:
      sup.killForFault(inst, fkHang, inst.busy,
        "busy for " & $inst.busyMs & " ms")
      return
    # §11.7.6: a plugin the recovery chord alone made suspect is cleared by
    # the answer to a ping sent after the chord, when the watchdog names
    # no running handler: the process is reading its input and idle, which is
    # what "not responding" denied. A pong naming a busy handler clears
    # nothing, and a plugin suspect from a missed deadline is not touched.
    if inst.busy.len == 0 and answeredPing:
      var cleared = false
      for s in inst.slotsOf(sup):
        if s.suspect and s.suspectByChord and
           inst.pingSeq > s.suspectAfterPing:
          s.clearSuspect()
          sup.note(s.id & " is answering again; its layers and bindings " &
                   "are back")
          cleared = true
      if cleared:
        sup.changed()
    return
  if t == "fault" and InstanceFaultsFeature in inst.features:
    sup.instanceFault(inst, msg)
    return
  let why = violation(msg, inst.registered)
  if why.len > 0:
    let named = msg{"plugin"}.getStr("")
    if sup.slots.hasKey(named) and named in inst.registered:
      sup.strike(sup.slots[named], fkProtocol, why, false)
      sup.recordFault(inst.package, named, fkProtocol, why,
                      "The message was ignored.")
    else:
      sup.killForFault(inst, fkProtocol, "", why)
    return
  let s = sup.slots[msg["plugin"].getStr]
  if s.instance != inst:
    return
  if t notin ["activated", "activation-failed"] and not s.active and
     not s.activating:
    # (A plugin pushes during its own activation, before `activated`: those
    # pushes are its first state, not a violation.)
    # A message for a plugin that is not active (§11.4.4).
    if t notin ["ack", "answer", "rows", "done", "error", "log"]:
      sup.strike(s, fkProtocol, "a '" & t & "' message while not active",
                 false)
    return
  # The bucket counts what a plugin PUSHES. Its lifecycle replies and its
  # acknowledgements are never dropped: a flood that swallowed its own
  # `activated` would leave the plugin starting for ever, and a dropped `ack`
  # would turn a flood into missed input deadlines it did not miss.
  if t notin ["activated", "activation-failed", "ack"] and
     not sup.takeToken(s):
    return
  case t
  of "activated":
    s.activating = false
    if not sup.eligible(s):
      inst.sendTo(%*{"type": "deactivate", "plugin": s.id})
      return
    s.active = true
    s.clearSuspect()        # a fresh activation answers for itself
    if s.breaker == bsHalfOpen:
      s.halfOpenSinceMs = sup.now()
    sup.note("activated " & s.id & " in " & inst.label & " pid " &
             $inst.link.pid)
    sup.changed()
  of "activation-failed":
    s.activating = false
    s.active = false
    sup.removePushed(s, "activation-failed", tellPlugin = false)
    let reason = msg{"reason"}.getStr("")
    sup.strike(s, fkStartFailure, reason, false)
    sup.recordFault(inst.package, s.id, fkStartFailure, reason,
                    "It is not running.")
  of "action":
    let vm = msg{"vm"}.getStr("")
    if vm in ["collab", "viewport"]:
      sup.refuse(s, "a plugin cannot relay '" & vm & "' actions")
      return
    if not sup.actionHook.isNil and sup.actionHook(msg):
      inc s.actionsApplied
    elif not sup.session.isNil and sup.session.applyAction(msg):
      inc s.actionsApplied
  of "publish-batch":
    s.published[msg{"viewModel"}.getStr("")] =
      (batch: msg{"batch"}, epoch: epochFrom(msg{"epoch"}))
    sup.changed()
  of "view":
    let surface = msg{"surface"}.getStr("")
    if not s.declaresSurface(surface):
      sup.refuse(s, "a view for surface '" & surface &
                 "', which the plugin did not declare")
      return
    let local = s.localSurface(surface)
    let dec = decodeViewTree(msg{"tree"})
    if dec.error.len > 0:
      s.views[local] = ViewEntry(refused: dec.error)
      sup.refuse(s, "the view for '" & local & "' was refused: " & dec.error)
    else:
      s.views[local] = ViewEntry(tree: dec.tree, epoch: epochFrom(msg{"epoch"}))
    sup.changed()
  of "view-patch":
    let local = s.localSurface(msg{"surface"}.getStr(""))
    let cur = s.views.getOrDefault(local)
    let dec = applyViewPatch(cur.tree, msg{"patch"})
    if dec.error.len > 0:
      s.views[local] = ViewEntry(refused: dec.error)
      sup.refuse(s, "a patch for '" & local & "' was refused: " & dec.error)
    else:
      s.views[local] = ViewEntry(tree: dec.tree, epoch: epochFrom(msg{"epoch"}))
    sup.changed()
  of "status":
    let dec = decodeViewTree(msg{"tree"}, 64)
    if dec.error.len == 0:
      s.status[msg{"item"}.getStr("")] = dec.tree
      sup.changed()
    else:
      sup.refuse(s, "status item refused: " & dec.error)
  of "decorations":
    var items = msg{"items"}
    if items.kind == JArray and items.len > MaxDecorationsPerDocument:
      var cut = newJArray()
      for i in 0 ..< MaxDecorationsPerDocument: cut.add items[i]
      inc s.truncatedDecorations
      items = cut
      sup.refuse(s, "decorations truncated to " & $MaxDecorationsPerDocument)
    s.decorations[msg{"document"}.getStr("")] = items
    sup.changed()
  of "enablement":
    s.enablement[msg{"op"}.getStr("")] =
      (enabled: msg{"enabled"}.getBool(false),
       reason: msg{"reason"}.getStr(""), epoch: epochFrom(msg{"epoch"}))
    sup.changed()
  of "context":
    let key = msg{"key"}.getStr("")
    if not s.context.hasKey(key) and s.context.len >= MaxContextKeysPerPlugin:
      sup.refuse(s, "context key '" & key & "' refused: " &
                 $MaxContextKeysPerPlugin & " keys already")
      return
    s.context[key] = msg{"value"}
    sup.changed()
  of "push-layer":
    let token = msg{"token"}.getStr("")
    let owner = msg{"owner"}.getStr("")
    if not sup.hostModalOpen.isNil and sup.hostModalOpen():
      sup.refuse(s, "a layer cannot be pushed while a CodeTracer dialog is open")
      return
    if s.suspect:
      sup.refuse(s, "a layer cannot be pushed while the plugin is not responding")
      return
    if s.layers.len >= MaxLayersPerPlugin:
      sup.refuse(s, "layer refused: " & $MaxLayersPerPlugin & " already live")
      return
    let window = owner == "window"
    if window and not s.spec.capturesWindowInput:
      sup.refuse(s, "a window layer needs 'capturesWindowInput' in the manifest")
      return
    if not window and not s.declaresSurface(owner):
      sup.refuse(s, "a layer owned by '" & owner &
                 "', which is not a surface the plugin contributed")
      return
    let bindings = bindingsFrom(msg{"bindings"})
    for b in bindings:
      if sup.isReservedKey(b.key):
        sup.refuse(s, "layer refused: it binds the reserved key '" & b.key & "'")
        return
    s.layers.add PushedLayer(token: token, plugin: s.id,
      owner: (if window: "window" else: s.id & "/" & s.localSurface(owner)),
      label: msg{"label"}.getStr(""), bindings: bindings, window: window)
    sup.changed()
  of "pop-layer":
    let token = msg{"token"}.getStr("")
    for i in countdown(s.layers.high, 0):
      if s.layers[i].token == token:
        s.layers.delete(i)
    sup.changed()
  of "ack":
    sup.onAck(s, msg{"id"}.getStr(""))
  of "answer", "rows", "done", "error":
    sup.onReply(s, msg, t)
  of "log", "progress":
    sup.note(s.id & " " & t & ": " & msg{"message"}.getStr($msg))
  else:
    discard

# ---------------------------------------------------------------------------
# Requests: invoke and query
# ---------------------------------------------------------------------------

proc newRequestId(sup: Supervisor): string =
  inc sup.nextId
  "r" & $sup.nextId

proc invoke*(sup: Supervisor; plugin, op: string;
             args: JsonNode = newJObject(); key = ""): string =
  ## Hand an operation to its plugin. Returns the request id, or "" when the
  ## plugin is not active. A `key` makes it input: the deadline applies.
  let s = sup.slot(plugin)
  if s.isNil or not s.active:
    return ""
  result = sup.newRequestId()
  let t = sup.now()
  let fromKey = key.len > 0
  sup.pending[result] = Pending(id: result, plugin: plugin, kind: pkInvoke,
    op: op, key: key, fromKey: fromKey, startedMs: t,
    deadlineMs: t + sup.inputDeadlineMs)
  s.instance.sendTo(%*{"type": "invoke", "plugin": plugin, "op": op,
    "args": args, "epoch": sup.epoch.toJson, "id": result,
    "deadlineMs": sup.inputDeadlineMs, "fromKey": fromKey})

proc query*(sup: Supervisor; plugin, kind: string; input: JsonNode;
            deadlineMs = 2_000): string =
  let s = sup.slot(plugin)
  if s.isNil or not s.active:
    return ""
  result = sup.newRequestId()
  let t = sup.now()
  sup.pending[result] = Pending(id: result, plugin: plugin, kind: pkQuery,
    op: kind, startedMs: t, deadlineMs: t + deadlineMs)
  s.instance.sendTo(%*{"type": "query", "plugin": plugin, "kind": kind,
    "input": input, "epoch": sup.epoch.toJson, "id": result,
    "deadlineMs": deadlineMs})

proc cancel*(sup: Supervisor; id: string) =
  let p = sup.pending.getOrDefault(id, nil)
  if p.isNil: return
  p.cancelled = true
  let s = sup.slot(p.plugin)
  if not s.isNil and not s.instance.isNil:
    s.instance.sendTo(%*{"type": "cancel", "id": id})

proc takeAnswers*(sup: Supervisor; id = ""): seq[Answer] =
  ## The replies received (for `id`, or all), removed from the queue.
  var rest: seq[Answer]
  for a in sup.answers:
    if id.len == 0 or a.id == id: result.add a
    else: rest.add a
  sup.answers = rest

proc viewEvent*(sup: Supervisor; qualifiedId: string; event: JsonNode) =
  ## A transition the host's `applyKey` produced in a plugin view.
  let parts = qualifiedId.split('/', 1)
  if parts.len != 2: return
  let s = sup.slot(parts[0])
  if s.isNil or not s.active: return
  s.instance.sendTo(%*{"type": "view-event", "plugin": s.id,
                       "surface": parts[1], "event": event})

# ---------------------------------------------------------------------------
# The poll loop
# ---------------------------------------------------------------------------

proc pollInstance(sup: Supervisor; inst: Instance) =
  if inst.link.isNil or inst.state in {isStopped, isDead, isBackoff}:
    return
  let t = sup.now()
  inst.link.flushWrites()
  for frame in inst.link.readMessages():
    var msg: JsonNode
    var notJson = false
    when defined(js):
      # Node's `JSON.parse` throws a native `SyntaxError`, which is not a
      # Nim `CatchableError`: only a bare `except` catches it.
      try:
        msg = parseJson(frame)
      except:
        notJson = true
    else:
      try:
        msg = parseJson(frame)
      except CatchableError:
        notJson = true
    if notJson:
      sup.killForFault(inst, fkProtocol, "", "a frame that is not JSON")
      break
    sup.handleMessage(inst, msg)
    if inst.state in {isDead, isStopped}: return
  if inst.link.oversize and not inst.pendingFault.set and
     inst.state != isStopping:
    sup.killForFault(inst, fkProtocol, "", "a frame larger than " &
                     $(MaxProtocolFrameBytes div (1024 * 1024)) & " MiB")
  if inst.link.queuedBytes > MaxQueuedBytes and inst.state == isRunning:
    sup.killForFault(inst, fkHang, inst.busy, "it stopped reading its input")
  # Exit.
  if inst.link.pollExit():
    discard inst.link.readMessages()
    inst.link.closeAll()
    let link = inst.link
    if inst.pendingFault.set:
      let f = inst.pendingFault
      inst.pendingFault.set = false
      sup.processFault(inst, f.kind, f.plugin, f.detail)
    elif inst.state == isStopping and inst.stopPhase in {1, 2, 3}:
      inst.state = isStopped
      sup.note("stopped " & inst.label)
      # A plugin re-enabled while its process was stopping needs a new one.
      for s in inst.package.plugins:
        let slot = sup.slots[s]
        if slot.instance == inst and sup.eligible(slot):
          sup.ensureRunning(slot)
    elif link.exit == esExited and link.exitCode == 0 and
         inst.state != isStarting:
      inst.state = isStopped
      for s in inst.slotsOf(sup):
        s.active = false
      sup.note("exited normally " & inst.label)
    else:
      var guilty = crashRecordPlugin(link.stderrTail)
      if guilty.len == 0 and inst.busy.len > 0:
        guilty = inst.busy
      let kind = if inst.state == isStarting and not inst.helloSeen:
                   fkStartFailure else: fkCrash
      sup.processFault(inst, kind, guilty, "the process " & link.describeExit)
    sup.changed()
    return
  # The stop sequence.
  if inst.state == isStopping:
    if inst.stopPhase == 1 and t >= inst.stopDeadlineMs:
      inst.link.signalGroup(SIGTERM)
      inst.stopPhase = 2
      inst.stopDeadlineMs = t + sup.termGraceMs
    elif inst.stopPhase == 2 and t >= inst.stopDeadlineMs:
      inst.link.signalGroup(SIGKILL)
      inst.stopPhase = 3
    return
  # The handshake deadline.
  if inst.state == isStarting and t - inst.startedMs > sup.helloDeadlineMs:
    sup.killForFault(inst, fkStartFailure, "",
                     "no hello within " & $sup.helloDeadlineMs & " ms")
    return
  # Liveness.
  if inst.state == isRunning:
    var waiting = false
    for p in sup.pending.values:
      if not p.finished and not p.cancelled and
         sup.slots[p.plugin].instance == inst:
        waiting = true
    # A plugin the recovery chord made suspect is waiting for a pong to
    # clear it. When the chord found a ping already outstanding (sent before
    # it, so its pong cannot clear it), the next one goes out at the busy
    # interval rather than the idle one.
    var chordSuspect = false
    for s in inst.slotsOf(sup):
      if s.suspect and s.suspectByChord:
        chordSuspect = true
    let interval =
      if waiting or inst.busy.len > 0 or chordSuspect: sup.pingBusyMs
      else: sup.pingIdleMs
    if inst.pingOutstanding:
      if t - inst.lastPingMs > sup.pongDeadlineMs:
        if inst.link.bytesRead > inst.bytesAtPing:
          # STILL DELIVERING, SO ANSWERING. The `pong` can queue behind a
          # large frame the plugin is writing into a full pipe: at load
          # 120-165 a healthy plugin was called hung this way. Bytes that
          # arrived since the ping are progress; the deadline restarts from
          # them, and a process that then goes silent is still hung.
          inst.lastPingMs = t
          inst.bytesAtPing = inst.link.bytesRead
        else:
          sup.killForFault(inst, fkHang, "", "its watchdog did not answer a " &
                           "ping within " & $sup.pongDeadlineMs & " ms")
          return
    elif t - inst.lastPingMs >= interval:
      inst.sendPing(t)
  inst.link.flushWrites()

proc pollDeadlines(sup: Supervisor) =
  let t = sup.now()
  var done: seq[string]
  for id, p in sup.pending:
    if p.finished or p.cancelled:
      if p.acked or p.kind == pkQuery or not p.fromKey:
        done.add id
      continue
    if p.kind == pkInvoke and p.fromKey and not p.acked and not p.expired and
       t >= p.deadlineMs:
      # §11.7.4: the key is dropped, never replayed.
      p.expired = true
      let s = sup.slot(p.plugin)
      if not s.isNil:
        # Evidence: only an `ack` clears this, never a pong (a plugin that
        # takes keys and never answers them still answers pings).
        s.suspect = true
        s.suspectByChord = false
        sup.statusLine = "`" & p.key & "` went to " & p.plugin &
          ", which did not answer"
        sup.strike(s, fkMissedInput, "no acknowledgement of `" & p.key &
                   "` within " & $sup.inputDeadlineMs & " ms",
                   s.layers.len > 0)
        sup.changed()
    elif p.kind == pkQuery and t >= p.deadlineMs:
      p.expired = true
    if p.expired and (p.kind == pkQuery or t - p.startedMs > 60_000):
      done.add id
    elif p.acked and p.kind == pkInvoke and t - p.startedMs > 60_000:
      done.add id
  for id in done:
    sup.pending.del(id)

proc pollBreakers(sup: Supervisor) =
  let t = sup.now()
  for s in sup.slots.values:
    case s.breaker
    of bsOpen:
      if not s.latched and t >= s.reopenAtMs:
        s.breaker = bsHalfOpen
        s.halfOpenSinceMs = t
        sup.note("breaker half-open: " & s.id)
        sup.ensureRunning(s)
        sup.changed()
    of bsHalfOpen:
      if s.active and t - s.halfOpenSinceMs >= sup.halfOpenProbationMs:
        s.breaker = bsClosed
        sup.note("breaker closed: " & s.id)
    of bsClosed:
      discard

proc poll*(sup: Supervisor) =
  ## One turn: cut pending batches, read every process, run every timer.
  ## Never blocks. A front-end calls it from its event loop.
  if sup.deferred.len > 0:
    let d = sup.deferred
    sup.deferred = @[]
    for cb in d: cb()
  let t = sup.now()
  for pkg in sup.packages.values:
    # A copy: a fault handled below may add an instance (quarantine).
    let instances = pkg.instances
    for inst in instances:
      if inst.state == isBackoff and t >= inst.nextStartMs:
        var any = false
        for s in pkg.plugins:
          let slot = sup.slots[s]
          if slot.instance == inst and sup.eligible(slot): any = true
          elif slot.instance.isNil and sup.eligible(slot) and
               sup.instanceFor(slot) == inst:
            slot.instance = inst
            any = true
        if any: sup.startInstance(inst)
        else: inst.state = isStopped
      sup.pollInstance(inst)
  for s in sup.slots.values:
    if s.reactivateAtMs > 0 and t >= s.reactivateAtMs:
      s.reactivateAtMs = 0
      if not s.active and not s.activating:
        sup.ensureRunning(s)
  sup.pollDeadlines()
  sup.pollBreakers()

proc busy*(sup: Supervisor): bool =
  ## Whether something is in flight that a front-end's loop should poll for
  ## soon: a request, a process starting, stopping or due to restart, a batch
  ## not yet cut. A loop that blocks may block longer when this is false.
  if sup.deferred.len > 0: return true
  for p in sup.pending.values:
    if not p.finished and not p.cancelled and not p.expired: return true
  for pkg in sup.packages.values:
    for inst in pkg.instances:
      if inst.state in {isStarting, isStopping, isBackoff}: return true
  false

# ---------------------------------------------------------------------------
# Reading what plugins pushed
# ---------------------------------------------------------------------------

proc faultNodeFor(s: PluginSlot; qualifiedId, why: string): ViewNode =
  viewText("plugin-fault:" & qualifiedId,
    "Plugin '" & s.id & "' is not showing this pane: " & why &
    ". Plugins: Show status lists what happened.")

proc renderSurface*(sup: Supervisor; qualifiedId: string): ViewNode =
  ## A contributed surface, from the last tree its plugin pushed. Never calls
  ## plugin code, never returns nil.
  if not sup.extensionsEnabled:
    return viewText("surface-no-extensions:" & qualifiedId,
      "Extensions are off for this session (--no-extensions).")
  let parts = qualifiedId.split('/', 1)
  let s = if parts.len == 2: sup.slot(parts[0]) else: nil
  if s.isNil:
    return viewText("surface-unknown:" & qualifiedId,
      "No plugin in this session contributes '" & qualifiedId & "'.")
  if not s.enabled or s.sessionDisabled or sup.allDisabledForSession:
    return viewText("plugin-disabled:" & qualifiedId,
      "Plugin '" & s.id & "' is disabled.")
  if s.breaker == bsOpen:
    return s.faultNodeFor(qualifiedId, s.lastFault)
  let e = s.views.getOrDefault(parts[1])
  if e.refused.len > 0:
    return s.faultNodeFor(qualifiedId, "its view was refused: " & e.refused)
  if e.tree.isNil:
    return viewText("plugin-loading:" & qualifiedId,
      (if s.active: "Plugin '" & s.id & "' has not drawn this pane yet."
       else: "Plugin '" & s.id & "' is starting."))
  e.tree

proc isStale*(sup: Supervisor; qualifiedId: string): bool =
  ## §11.4.5: a view tree is kept and marked stale when it was computed at an
  ## earlier position.
  let parts = qualifiedId.split('/', 1)
  if parts.len != 2: return false
  let s = sup.slot(parts[0])
  if s.isNil: return false
  let e = s.views.getOrDefault(parts[1])
  not e.tree.isNil and not samePosition(e.epoch, sup.epoch)

proc contributedPanes*(sup: Supervisor): seq[tuple[id, title: string]] =
  ## Every pane an enabled plugin contributes, qualified.
  for s in sup.slots.values:
    if not s.enabled: continue
    for c in s.spec.parsed.manifest.contributions:
      if c.kind == ckPane:
        result.add (id: s.id & "/" & c.id,
                    title: (if c.title.len > 0: c.title else: c.id))

proc commands*(sup: Supervisor): seq[tuple[plugin, op, title: string]] =
  for s in sup.slots.values:
    if not s.enabled or s.sessionDisabled: continue
    for c in s.spec.parsed.manifest.contributions:
      if c.kind == ckCommand:
        result.add (plugin: s.id, op: c.id,
                    title: (if c.title.len > 0: c.title else: c.id))

proc statusItems*(sup: Supervisor): seq[tuple[plugin, item: string; tree: ViewNode]] =
  for s in sup.slots.values:
    if s.breaker == bsOpen: continue
    for item, tree in s.status:
      result.add (plugin: s.id, item: item, tree: tree)

proc enablementOf*(sup: Supervisor; plugin, op: string):
    tuple[enabled: bool, reason: string] =
  ## §11.7.2: read the last pushed value; never ask.
  let s = sup.slot(plugin)
  if s.isNil: return (false, "no such plugin")
  if not s.enabled or s.sessionDisabled or sup.allDisabledForSession:
    return (false, "plugin disabled")
  if s.breaker == bsOpen: return (false, "plugin stopped: " & s.lastFault)
  if s.suspect: return (false, "plugin not responding")
  if not s.active: return (false, "plugin starting")
  if not s.enablement.hasKey(op): return (false, "plugin starting")
  let e = s.enablement[op]
  (e.enabled, e.reason)

const PluginVisualisersViewModel* = "visualisers"
  ## The published ViewModel a plugin contributes per-type visualisers
  ## through (PLAT-12's `ptPlugin` tier): a batch of declarations, each
  ## `{id, typeMatch, matchKind, language, summary, rank}` — data, the same
  ## shape a project definition's `[[visualiser]]` row has, never code.

proc pluginVisualisers*(sup: Supervisor): seq[Visualiser] =
  ## Every running plugin's visualisers, as `ptPlugin`-tier `Visualiser`s.
  ## A plugin must declare the `visualisers` ViewModel it publishes; a batch
  ## from one that did not is ignored. Ids are namespaced by the plugin.
  for s in sup.slots.values:
    if not s.active or s.breaker == bsOpen: continue
    var declared = false
    for c in s.spec.parsed.manifest.contributions:
      if c.kind == ckViewModel and c.id == PluginVisualisersViewModel:
        declared = true
    if not declared or not s.published.hasKey(PluginVisualisersViewModel):
      continue
    let batch = s.published[PluginVisualisersViewModel].batch
    if batch.isNil or batch.kind != JArray: continue
    for v in batch:
      var mk = mkTypeName
      case v{"matchKind"}.getStr("typeName")
      of "typePrefix": mk = mkTypePrefix
      of "typeSuffix": mk = mkTypeSuffix
      else: mk = mkTypeName
      let typeMatch = v{"typeMatch"}.getStr("")
      if typeMatch.len == 0: continue
      result.add Visualiser(id: "plugin:" & s.id & "#" & v{"id"}.getStr($result.len),
                            tier: ptPlugin, tierDeclared: true,
                            typeMatch: typeMatch, matchKind: mk,
                            language: v{"language"}.getStr(""),
                            summary: v{"summary"}.getStr(""),
                            rank: v{"rank"}.getInt(0))

proc contextKeys*(sup: Supervisor): Table[string, bool] =
  ## Every plugin context key, as `plugin.<id>.<key>`, truthy or not.
  for s in sup.slots.values:
    if s.breaker == bsOpen or s.suspect: continue
    for k, v in s.context:
      let truthy = case v.kind
        of JBool: v.getBool
        of JNull: false
        of JString: v.getStr.len > 0
        of JInt: v.getInt != 0
        else: true
      result["plugin." & s.id & "." & k] = truthy

proc topLayerLabel*(sup: Supervisor): string =
  ## §11.7.3: the status line names the top plugin layer and its plugin.
  var best: PushedLayer
  var found = false
  for s in sup.slots.values:
    if s.suspect or s.breaker == bsOpen: continue
    for l in s.layers:
      best = l
      found = true
  if not found: return ""
  (if best.label.len > 0: best.label.toUpperAscii else: "PLUGIN") &
    " MODE (" & best.plugin & ")"

proc allLayers*(sup: Supervisor): seq[PushedLayer] =
  for s in sup.slots.values:
    for l in s.layers: result.add l

# ---------------------------------------------------------------------------
# Key resolution (§11.7)
# ---------------------------------------------------------------------------

type
  KeyRoute* = object
    found*: bool
    plugin*: string
    op*: string
    viaLayer*: string

proc resolveLayerKey*(sup: Supervisor; key, focusedSurface: string;
                      hostContext: Table[string, bool] =
                        initTable[string, bool]()): KeyRoute =
  ## The plugin layers' answer for `key`, top layer first. A suspect plugin's
  ## layers are transparent; so is everything while a host modal is open
  ## (host modal layers rank above every plugin layer).
  if not sup.hostModalOpen.isNil and sup.hostModalOpen():
    return
  let k = key.toLowerAscii
  var ctx = hostContext
  for kk, v in sup.contextKeys: ctx[kk] = v
  var order: seq[PluginSlot]
  for s in sup.slots.values: order.add s
  # Newest layer on top: walk every layer in push order, last wins.
  var candidates: seq[(PluginSlot, PushedLayer)]
  for s in order:
    for l in s.layers: candidates.add (s, l)
  var struck: seq[string]
  for i in countdown(candidates.high, 0):
    let (s, l) = candidates[i]
    if s.breaker == bsOpen or not s.active: continue
    if not l.window and l.owner != focusedSurface: continue
    for b in l.bindings:
      if b.key == k and evalWhen(b.whenClause, ctx):
        if s.suspect:
          # §11.7.4: TRANSPARENT. The key falls through to the next layer,
          # and the plugin, still holding a layer it does not answer for,
          # takes a strike for the key it would have swallowed — so a plugin
          # that stopped answering loses its layer within three keys, the
          # breaker's threshold, not only within three deadlines.
          if s.id notin struck:
            struck.add s.id
            sup.statusLine = "`" & k & "` passed " & s.id &
              "'s layer: the plugin is not responding"
            sup.strike(s, fkMissedInput, "a key fell through its layer " &
                       "while it was not responding", true)
          break
        return KeyRoute(found: true, plugin: s.id, op: b.op, viaLayer: l.token)

proc resolveStaticKey*(sup: Supervisor; key, focusedSurface: string;
                       hostContext: Table[string, bool] =
                         initTable[string, bool]()): KeyRoute =
  ## The plugin PASS, between the user pass and the base pass (§11.7.2).
  if not sup.hostModalOpen.isNil and sup.hostModalOpen():
    return
  let k = key.toLowerAscii
  var ctx = hostContext
  for kk, v in sup.contextKeys: ctx[kk] = v
  for s in sup.slots.values:
    if s.suspect or s.breaker == bsOpen or not s.active: continue
    for b in s.spec.bindings:
      if b.key != k: continue
      if b.scope != "window" and b.scope != focusedSurface and
         s.id & "/" & b.scope != focusedSurface: continue
      if not evalWhen(b.whenClause, ctx): continue
      if not sup.enablementOf(s.id, b.op).enabled: continue
      return KeyRoute(found: true, plugin: s.id, op: b.op)

proc routeKey*(sup: Supervisor; route: KeyRoute; key: string): string =
  ## Consume `key` for the plugin `route` names: an `invoke` with the input
  ## deadline. The key is consumed whatever the plugin later does (§11.7.2:
  ## plugin operations may not decline).
  sup.invoke(route.plugin, route.op, %*{"key": key}, key = key)

proc bindingConflicts*(sup: Supervisor): seq[PluginError] =
  ## §11.7.2: two plugins binding one key in one scope with `when` clauses
  ## that can both hold, and plugin rows that take a reserved key.
  proc canBothHold(a, b: string): bool =
    var ta, tb: seq[string]
    for x in a.split("&&"):
      if x.strip.len > 0: ta.add x.strip
    for x in b.split("&&"):
      if x.strip.len > 0: tb.add x.strip
    for x in ta:
      for y in tb:
        if x == "!" & y or y == "!" & x: return false
    true
  var rows: seq[(string, string, string, string)]
  for s in sup.slots.values:
    for b in s.spec.bindings:
      if sup.isReservedKey(b.key):
        result.add pluginError(s.id, pecReservedKey,
          "key '" & b.key & "' (bound to '" & b.op & "') is reserved: it " &
          "opens the palette or the recovery dialog, which no plugin may take")
      rows.add (s.id, b.key, b.scope, b.whenClause)
  for i in 0 ..< rows.len:
    for j in i + 1 ..< rows.len:
      let (pa, ka, sa, wa) = rows[i]
      let (pb, kb, sb, wb) = rows[j]
      if pa != pb and ka == kb and sa == sb and canBothHold(wa, wb):
        result.add pluginError(pa, pecBindingConflict,
          "key '" & ka & "' in scope '" & sa & "' is also bound by plugin '" &
          pb & "'. Rebind one of them in your key bindings")

# ---------------------------------------------------------------------------
# Escape, recovery and the user's actions (§11.7.6)
# ---------------------------------------------------------------------------

proc observeEscape*(sup: Supervisor): bool {.discardable.} =
  ## Called by a front-end's router for EVERY `Escape`, before any layer is
  ## resolved. The third within a second pops every plugin layer, marks the
  ## plugins that held one suspect, and opens the recovery dialog. True when
  ## it did.
  ##
  ## The chord is the user's gesture, not evidence about a plugin: it is
  ## pressed as readily over a healthy plugin as over a stuck one. A plugin
  ## that was not suspect already becomes suspect BY THE CHORD
  ## (`suspectByChord`), and its process is probed at once with a ping; the
  ## pong, if the watchdog names no busy handler, gives its bindings and
  ## enablement back (`handleMessage`). Without the probe it could never
  ## recover: a suspect plugin receives no key and no command, so the `ack`
  ## that clears a missed deadline never comes. A plugin already suspect from
  ## a missed input deadline stays so, and still needs an `ack`.
  let t = sup.now()
  sup.escapeTimes.add t
  var kept: seq[int64]
  for x in sup.escapeTimes:
    if t - x <= RecoveryChordWindowMs: kept.add x
  sup.escapeTimes = kept
  if kept.len < RecoveryChordCount:
    return false
  sup.escapeTimes = @[]
  sup.recoveryPlugins = @[]
  for s in sup.slots.values:
    if s.layers.len > 0:
      sup.recoveryPlugins.add s.id
      for l in s.layers:
        if not s.instance.isNil:
          s.instance.sendTo(%*{"type": "layer-popped", "plugin": s.id,
                               "token": l.token, "reason": "recovery"})
      s.layers = @[]
      if not s.suspect:
        s.suspect = true
        s.suspectByChord = true
        s.suspectAfterPing =
          if s.instance.isNil: 0 else: s.instance.pingSeq
  # Probe each affected process now. One whose ping is already outstanding
  # was pinged before the chord; the liveness loop sends the next at the busy
  # interval while any of its plugins is suspect by the chord.
  for s in sup.slots.values:
    let inst = s.instance
    if s.suspect and s.suspectByChord and s.id in sup.recoveryPlugins and
       not inst.isNil and inst.state == isRunning and
       not inst.pingOutstanding:
      inst.sendPing(t)
  sup.recoveryOpen = true
  sup.note("recovery chord: popped the layers of " &
           (if sup.recoveryPlugins.len == 0: "no plugin"
            else: sup.recoveryPlugins.join(", ")))
  sup.changed()
  true

proc disableForSession*(sup: Supervisor; id: string) =
  let s = sup.slot(id)
  if s.isNil: return
  s.sessionDisabled = true
  sup.removePushed(s, "disabled", tellPlugin = true)
  sup.sendDeactivate(s)
  sup.stopIfIdle(s.instance)
  sup.changed()

proc disableAllForSession*(sup: Supervisor) =
  ## *Plugins: Disable all for this session*: no plugin process runs.
  sup.allDisabledForSession = true
  for s in sup.slots.values:
    sup.removePushed(s, "disabled", tellPlugin = true)
    s.active = false
    s.activating = false
  for pkg in sup.packages.values:
    for inst in pkg.instances:
      sup.stopInstance(inst)
  sup.recoveryOpen = false
  sup.changed()

proc reEnable*(sup: Supervisor; id: string) =
  ## *Re-enable*: a latched or open breaker goes half-open now.
  let s = sup.slot(id)
  if s.isNil: return
  s.sessionDisabled = false
  s.latched = false
  s.clearSuspect()
  if s.breaker == bsOpen:
    s.breaker = bsHalfOpen
    s.halfOpenSinceMs = sup.now()
  let pkg = sup.packages[s.package]
  for inst in pkg.instances:
    if inst.state == isDead and (inst.dedicated == "" or inst.dedicated == id):
      inst.state = isStopped
      inst.restartTimes = @[]
      inst.attempt = 0
  sup.ensureRunning(s)
  sup.changed()

proc closeRecovery*(sup: Supervisor) =
  sup.recoveryOpen = false

# ---------------------------------------------------------------------------
# Bisect (§11.7.6)
# ---------------------------------------------------------------------------

type
  Bisect* = ref object
    candidates*: seq[string]
    disabled*: seq[string]
    steps*: int
    culprit*: string

proc startBisect*(sup: Supervisor): Bisect =
  ## *Plugins: Find the plugin causing a problem*: disable half of the
  ## enabled plugins for this session.
  result = Bisect()
  for s in sup.slots.values:
    if s.enabled and not s.sessionDisabled: result.candidates.add s.id
  let half = result.candidates.len div 2
  for i in 0 ..< half:
    result.disabled.add result.candidates[i]
    sup.disableForSession(result.candidates[i])
  inc result.steps

proc answerBisect*(sup: Supervisor; b: Bisect; problemRemains: bool) =
  ## The user's answer. When the problem remains, the culprit is among the
  ## plugins still enabled; otherwise among those just disabled.
  var next: seq[string]
  if problemRemains:
    for c in b.candidates:
      if c notin b.disabled: next.add c
  else:
    next = b.disabled
  for c in b.candidates:
    let s = sup.slot(c)
    if not s.isNil and s.sessionDisabled:
      s.sessionDisabled = false
      sup.ensureRunning(s)
  b.candidates = next
  b.disabled = @[]
  if next.len <= 1:
    b.culprit = if next.len == 1: next[0] else: ""
    return
  let half = next.len div 2
  for i in 0 ..< half:
    b.disabled.add next[i]
    sup.disableForSession(next[i])
  inc b.steps

# ---------------------------------------------------------------------------
# Reports (§11.6.5)
# ---------------------------------------------------------------------------

proc percentile(samples: seq[int]; p: float): int =
  if samples.len == 0: return -1
  var s = samples
  s.sort()
  s[min(s.high, int(ceil(p * float(s.len))) - 1).max(0)]

proc stateOf*(sup: Supervisor; s: PluginSlot): string =
  if not sup.extensionsEnabled: "off (--no-extensions)"
  elif sup.allDisabledForSession or s.sessionDisabled: "disabled for this session"
  elif not s.enabled: "disabled"
  elif sup.packages[s.package].loadErrors.len > 0: "failed to load"
  elif s.breaker == bsOpen and s.latched: "stopped until re-enabled"
  elif s.breaker == bsOpen: "stopped (restarts in " &
    $max(0, (s.reopenAtMs - sup.now()) div 1000) & " s)"
  elif s.suspect: "not responding"
  elif s.active and s.breaker == bsHalfOpen: "running (on probation)"
  elif s.active: "running"
  elif s.wanted: "starting"
  else: "not started"

proc latency*(s: PluginSlot): tuple[p50, p99: int] =
  (percentile(s.ackSamples, 0.5), percentile(s.ackSamples, 0.99))

proc report*(sup: Supervisor): string =
  ## The Plugins pane and `ct plugins status`: each plugin with its state,
  ## strikes, last fault and acknowledgement latency.
  var lines: seq[string]
  if not sup.extensionsEnabled:
    lines.add "Extensions are off for this session (--no-extensions): no " &
      "plugin process was started."
  for pkg in sup.packages.values:
    var procs: seq[string]
    for inst in pkg.instances:
      procs.add inst.label & " " & $inst.state &
        (if not inst.link.isNil and inst.state == isRunning:
           " pid " & $inst.link.pid else: "")
    lines.add "package " & pkg.name & (if pkg.quarantined: " (quarantined)" else: "") &
      (if procs.len > 0: ": " & procs.join(", ") else: "")
    for e in pkg.loadErrors:
      lines.add "  load error: " & e
    for id in pkg.plugins:
      let s = sup.slots[id]
      let (p50, p99) = s.latency
      var line = "  " & id & "  " & sup.stateOf(s) & "  breaker " & $s.breaker &
        "  strikes " & $s.strikes.len
      if p50 >= 0:
        line.add "  ack p50 " & $p50 & " ms p99 " & $p99 & " ms"
      if s.slowAcks > 0:
        line.add "  slow " & $s.slowAcks
      lines.add line
      if s.lastFault.len > 0:
        lines.add "    last fault: " & s.lastFault
      for p in s.settingProblems:
        lines.add "    " & render(p)
  if lines.len == 0:
    lines.add "No plugins are installed."
  lines.join("\n")

proc processIds*(sup: Supervisor): seq[int] =
  for pkg in sup.packages.values:
    for inst in pkg.instances:
      if not inst.link.isNil and inst.link.exit == esRunning and
         inst.state in {isStarting, isRunning, isStopping}:
        result.add int(inst.link.pid)

proc pidOf*(sup: Supervisor; plugin: string): int =
  let s = sup.slot(plugin)
  if s.isNil or s.instance.isNil or s.instance.link.isNil: return 0
  if s.instance.state notin {isRunning, isStarting}: return 0
  int(s.instance.link.pid)

proc finishShutdown(sup: Supervisor) =
  ## What `shutdown` does once the graceful wait is over: SIGKILL for
  ## whatever remains, and the mirror disposed.
  for pkg in sup.packages.values:
    for inst in pkg.instances:
      if not inst.link.isNil and inst.link.exit == esRunning:
        inst.link.signalGroup(SIGKILL)
        discard inst.link.pollExit()
  if not sup.publisher.isNil:
    sup.publisher.dispose()
  if not sup.disposeRoot.isNil:
    sup.disposeRoot()
    sup.disposeRoot = nil

when defined(js):
  const ReapAfterKillMs = 2_000
    ## How long `shutdown` waits for Node to report the exits of what it
    ## SIGKILLed.
  proc jsSetInterval(cb: proc(); ms: int): JsObject {.importjs: "setInterval(#, #)".}
  proc jsClearInterval(t: JsObject) {.importjs: "clearInterval(#)".}

proc shutdown*(sup: Supervisor; waitMs = 3_000; onDone: proc() = nil) =
  ## Stop every process: the graceful sequence, polled until each is reaped
  ## or `waitMs` passes, then SIGKILL for whatever remains. `onDone` runs
  ## after that.
  ##
  ## On the C backend this returns when it is over. On the JavaScript
  ## backend the bytes and exits it waits for arrive in Node's event loop,
  ## which a loop here would block: it polls once now, and if a process is
  ## still running, again every 5 ms on a timer; it returns at once and
  ## `onDone` says when it is over.
  for pkg in sup.packages.values:
    for inst in pkg.instances:
      sup.stopInstance(inst)
  when defined(js):
    let start = monotonicMs()
    sup.poll()
    if sup.processIds.len == 0:
      sup.finishShutdown()
      if not onDone.isNil: onDone()
      return
    var timer: JsObject
    timer = jsSetInterval(proc() =
      sup.poll()
      if sup.processIds.len == 0 or monotonicMs() - start >= waitMs:
        jsClearInterval(timer)
        sup.finishShutdown()
        # What was SIGKILLed is reaped by Node later: read its exit before
        # saying the shutdown is over, so `processIds` is true afterwards.
        let reapStart = monotonicMs()
        var reaper: JsObject
        reaper = jsSetInterval(proc() =
          var running = false
          for pkg in sup.packages.values:
            for inst in pkg.instances:
              if not inst.link.isNil and not inst.link.pollExit():
                running = true
          if not running or monotonicMs() - reapStart >= ReapAfterKillMs:
            jsClearInterval(reaper)
            if not onDone.isNil: onDone(), 5), 5)
  else:
    let start = monotonicMs()
    while monotonicMs() - start < waitMs:
      sup.poll()
      if sup.processIds.len == 0: break
      os.sleep(5)
    sup.finishShutdown()
    if not onDone.isNil: onDone()
