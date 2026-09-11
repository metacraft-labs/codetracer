## io_tool_plugin.nim — PLAT-8's plugin fixtures: a plugin that integrates a
## real external tool, exactly the way Extensibility-Model.md §8.1 says one
## should be able to.
##
## Three plugins live here because they are three shapes of the SAME plugin and
## splitting them would triple the closure the reactive-boundary gate walks for
## no gain:
##
##   `IoPipelinePlugin`  drives a child process over its stdin/stdout as
##                       streams, with delimiter framing.
##   `IoSocketPlugin`    drives a Unix domain socket, with length-prefixed
##                       framing, against a peer that is another real process.
##   `IoProbePlugin`     makes the attempts that must be REFUSED — a shell, a
##                       non-loopback address, an undeclared path — and hands
##                       the outcome back so a test can assert the refusal
##                       rather than the absence of a success.
##
## ## IT DOES NOT NAME A SYNCHRONOUS I/O PRIMITIVE, AND IT COULD NOT USEFULLY
##
## There is no `waitFor`, `execProcess`, `startProcess`, `readFile`,
## `writeFile`, `readAll`, `newSocket` or `waitForExit` in this file's CODE.
## Two mechanisms hold that, and neither alone is enough — the same pair
## PLAT-7 needed for the reactive primitives:
##
##   * `codetracer_plugin` re-exports `std/asyncdispatch` with `waitFor`,
##     `runForever`, `poll` and `drain` filtered out, so the spelling a plugin
##     author would reach for does not compile;
##   * `ci/test/plugin-reactive-boundary.sh` refuses every name in
##     `PluginDeniedSyncIo` in the SOURCE of this file and of every module it
##     reaches, which is the half that catches `osproc.execProcess(...)` — and
##     the half that catches `readFile`, which is in `system` and therefore
##     cannot be filtered out of any scope at all. That was measured, not
##     assumed: with PLAT-7's surface alone, `compiles(readFile("x"))` is
##     **true** inside a plugin.
##
## The names above appear in this DOC COMMENT, deliberately, so the gate's
## comment stripper has a second file to discriminate on — the same job
## `position_watch_plugin.nim` does for `PluginDeniedPrimitives`.
##
## ## THE TOOL IS REAL AND SO IS THE PEER
##
## No mocks. `IoPipelinePlugin` is pointed at whatever program the test
## declares — `cat` in the suite — and talks to it over the kernel's pipes.
## `IoSocketPlugin` talks to a real `python3` process over a real
## `AF_UNIX` socket. Neither has a stand-in and neither has a code path that
## works differently under test.
##
## ## WHAT THE PLUGIN DOES NOT OWN
##
## It does not choose the path of its tool: it names `cat` and the host
## resolves it. It does not build a command line: it hands over a `seq[string]`
## and never sees one. It does not close its own handles at deactivation: it
## may, and `IoPipelinePlugin` deliberately does NOT in the teardown case, so
## the suite measures the HOST's sweep rather than the plugin's manners.

import std/[monotimes, times]

import codetracer_plugin

type
  IoPipelinePlugin* = ref object
    ## §8.1's Process row plus the Stream row: spawn, argv, environment,
    ## working directory, stdio as streams, framing, exit status.
    ctx*: PluginContext
    toolName*: string
    args*: seq[string]
    env*: seq[(string, string)]
    workingDir*: string
    toSend*: seq[string]
    received*: seq[string]
    spawnStatus*: IoStatus
    spawnMessage*: string
    exit*: ExitOutcome
    activated*: int
    process*: PluginProcess
      ## Retained so a test can tear the plugin down MID-OPERATION and then
      ## ask the OS about this pid. A plugin would not normally expose it.
    keepOpen*: bool
      ## When true the plugin leaves the child and its streams open after the
      ## exchange, so deactivation has something to release.

  IoSocketPlugin* = ref object
    ## §8.1's Socket row plus the Codec row: connect, length-prefixed framing.
    ctx*: PluginContext
    socketPath*: string
    request*: string
    reply*: string
    connectStatus*: IoStatus
    connectMessage*: string
    frameStatus*: IoStatus
    frameMessage*: string
    stream*: PluginStream
    keepOpen*: bool

  IoProbePlugin* = ref object
    ## The refusals. Every field is what an ATTEMPT returned, because
    ## PLAT-8's tests are phrased as attempts and "it did not happen" is not
    ## something the absence of a value can say.
    ctx*: PluginContext
    burnMs*: int
      ## When non-zero, `activate` creates ONE plugin effect that burns this
      ## long and then makes an I/O call. That is the only way to exercise
      ## the I/O API as a deadline checkpoint honestly: `pluginEffect`
      ## requires the activation scope to be ambient, which it is only inside
      ## `activate`, and a suite that created the effect from outside would be
      ## refused by `requireScope` rather than measured by the budget.
    burnTool*: string
    reachedIo*: bool
      ## The burn finished and the I/O call was about to be made.
    completedIo*: bool
      ## The I/O call RETURNED. It must not: `checkBudget` raises in the
      ## caller's frame, which is the whole of rule 1a in `plugin_io.nim`.

const
  SyncDrainsAreOutOfScope* =
    not compiles(waitFor(newFuture[int]("probe"))) and
    not compiles(runForever())
    ## Evaluated in a module whose import list is a PLUGIN's. `export …
    ## except` filters unqualified lookup, so the spelling a plugin author
    ## would write does not compile.

  SanctionedAsyncIsInScope* =
    compiles(newFuture[int]("probe")) and
    compiles(sleepAsync(0))
    ## THE CONTROL, through the same `compiles`. A narrowing that removed the
    ## async vocabulary altogether would satisfy the rule above and leave a
    ## plugin unable to write asynchronous code at all — which is the shape
    ## Verification-Harness-Traps §4a warns about from the other side.

  # ---- F6, 2026-09-09: A FOURTH WAY TO BLOCK, AND WHICH HALF REFUSES IT ----
  #
  # `SyncDrainsAreOutOfScope` above is a claim about FOUR names, and the
  # milestone read it as a claim about the property. A verification pass
  # measured five more routines that block, or that reach a shell, and that
  # compile in exactly this scope. The constants below are the honest record
  # of what the LANGUAGE half can and cannot do about them; the SOURCE GATE
  # refuses all of them, by identifier, out of `PluginDeniedSyncIo`.
  #
  # Each is evaluated HERE, in a module whose import list is a plugin's, for
  # the same reason `SyncDrainsAreOutOfScope` is: a `compiles` in the suite
  # would be a claim about the suite, which imports `std/os` directly.

  SystemBlockersAreStillInScope* =
    compiles(readLine(stdin)) and
    compiles(readLines("/dev/null", 1)) and
    compiles(readChar(stdin)) and
    compiles(staticExec("true")) and
    compiles(gorge("true"))
    ## **THE LANGUAGE CANNOT REFUSE THESE, AND THIS ASSERTS THAT IT DOES NOT.**
    ## All five are in `system`, which is auto-imported and exported by
    ## nothing, so there is no `export … except` clause that could filter them
    ## — the property `plugin_io.nim` already records for `readFile`. A reader
    ## must not take their presence on `PluginDeniedSyncIo` as "the compiler
    ## stops them": the source gate is the ONLY half that refuses them.
    ##
    ## It is written as a POSITIVE assertion rather than as a comment because
    ## a comment cannot go red. If a future nim, or a future facade, did put
    ## them out of scope, this constant becomes `false` and the case naming it
    ## fails — which is the moment to move them from one column to the other
    ## rather than to discover it three milestones later.

  OsSleepIsNotOnTheFacade* =
    (not compiles(sleep(0))) and (not compiles(os.sleep(0)))
    ## **MEASURED 2026-09-09, AND IT IS THE OPPOSITE OF WHAT WAS EXPECTED**,
    ## which is why it is a constant rather than a sentence.
    ##
    ## `std/os`'s `sleep` blocks the calling thread outright and the
    ## verification pass reported it "in scope". It is NOT in scope through the
    ## plugin facade — measured in this module, whose import list is a
    ## plugin's, in both spellings: bare `sleep` and module-qualified
    ## `os.sleep` are each `false`. The pass's probe had `std/os` in ITS own
    ## imports.
    ##
    ## **That does not make the finding wrong, and this is the part worth
    ## carrying**: a plugin may write `import std/os` itself — nothing in
    ## PLAT-7's or PLAT-8's denial refuses that import — and then `sleep` is in
    ## scope and blocks the front-end. So `sleep` belongs on
    ## `PluginDeniedSyncIo` exactly as the five `system` names do, and the
    ## SOURCE GATE is again the only half that refuses it. The suite carries
    ## the positive control for that, from a module that does import `std/os`.
    ##
    ## Written as an assertion so the day the facade starts re-exporting
    ## `std/os` this goes red, instead of the comment above quietly becoming
    ## false.

func newIoPipelinePlugin*(toolName: string; toSend: seq[string]): IoPipelinePlugin =
  IoPipelinePlugin(toolName: toolName, toSend: toSend, spawnStatus: ioOk)

func newIoSocketPlugin*(socketPath, request: string): IoSocketPlugin =
  IoSocketPlugin(socketPath: socketPath, request: request)

func newIoProbePlugin*(): IoProbePlugin =
  IoProbePlugin()

# ---------------------------------------------------------------------------
# activate — it returns promptly, which is the whole of §8.1.3 from the
# plugin's side
# ---------------------------------------------------------------------------

proc implementation*(p: IoPipelinePlugin;
                     manifest: PluginManifest): PluginImplementation =
  ## `activate` captures the context and RETURNS. It does not spawn anything:
  ## §5.3 and §8.1.3 both say a plugin's synchronous work is budgeted, and a
  ## spawn inside `activate` would put an `execve` on the front-end's thread
  ## for no reason. The work is started by whoever has an event loop.
  let plugin = p
  PluginImplementation(manifest: manifest, activate: proc(ctx: PluginContext) =
    plugin.ctx = ctx
    plugin.activated = plugin.activated + 1)

proc implementation*(p: IoSocketPlugin;
                     manifest: PluginManifest): PluginImplementation =
  let plugin = p
  PluginImplementation(manifest: manifest, activate: proc(ctx: PluginContext) =
    plugin.ctx = ctx)

proc implementation*(p: IoProbePlugin;
                     manifest: PluginManifest): PluginImplementation =
  let plugin = p
  PluginImplementation(manifest: manifest, activate: proc(ctx: PluginContext) =
    plugin.ctx = ctx
    if plugin.burnMs > 0:
      ctx.pluginEffect("io-after-overrun", proc() =
        let started = getMonoTime()
        while (getMonoTime() - started).inMilliseconds < plugin.burnMs:
          discard
        plugin.reachedIo = true
        # The checkpoint is BEFORE the capability decision, so this raises
        # even for a plugin that holds the grant.
        discard ctx.spawnProcess(plugin.burnTool)
        plugin.completedIo = true))

# ---------------------------------------------------------------------------
# The pipeline: a real child, real pipes, delimiter framing
# ---------------------------------------------------------------------------

proc runPipeline*(p: IoPipelinePlugin): Future[void] {.async.} =
  ## Write every line as a delimited frame, close stdin so the tool sees EOF,
  ## read frames back until EOF, then take the exit status.
  ##
  ## The loop is the one §8.1's fourth row exists to stop every plugin from
  ## writing: `readFrame` owns the buffer and the "did a whole message
  ## arrive yet" question, and this file never sees a partial read.
  let spawned = await p.ctx.spawnProcess(p.toolName, p.args, p.env,
                                         p.workingDir)
  p.spawnStatus = spawned.status
  p.spawnMessage = spawned.message
  if spawned.status != ioOk: return
  p.process = spawned.process

  for line in p.toSend:
    let w = await p.process.stdin.writeFrame(line, frDelimited)
    if w.status != ioOk:
      p.spawnStatus = w.status
      p.spawnMessage = w.message
      return
  # EOF to the child. Without this a filter that reads to end of input never
  # finishes, and the read below would wait for a message nobody will send —
  # which is the deadlock a framing helper cannot rescue anyone from.
  closeStream(p.process.stdin)

  while true:
    let f = await p.process.stdout.readFrame(frDelimited)
    case f.status
    of ioOk: p.received.add f.frame
    of ioEof: break
    else:
      p.spawnStatus = f.status
      p.spawnMessage = f.message
      break

  p.exit = await p.process.awaitExit()
  if not p.keepOpen:
    closeProcess(p.process)

proc startLongRunning*(p: IoPipelinePlugin): Future[void] {.async.} =
  ## Spawn and leave it running. What a plugin holding a language server or an
  ## analyser daemon looks like at the moment the user closes the tab.
  let spawned = await p.ctx.spawnProcess(p.toolName, p.args, p.env,
                                         p.workingDir)
  p.spawnStatus = spawned.status
  p.spawnMessage = spawned.message
  if spawned.status != ioOk: return
  p.process = spawned.process

# ---------------------------------------------------------------------------
# The socket: a real peer, length-prefixed framing
# ---------------------------------------------------------------------------

proc runSocketExchange*(p: IoSocketPlugin): Future[void] {.async.} =
  let c = await p.ctx.connectUnixSocket(p.socketPath)
  p.connectStatus = c.status
  p.connectMessage = c.message
  if c.status != ioOk: return
  p.stream = c.stream

  let w = await p.stream.writeFrame(p.request, frLengthPrefixed)
  if w.status != ioOk:
    p.frameStatus = w.status
    p.frameMessage = w.message
    return
  let f = await p.stream.readFrame(frLengthPrefixed)
  p.frameStatus = f.status
  p.frameMessage = f.message
  if f.status == ioOk: p.reply = f.frame
  if not p.keepOpen:
    closeStream(p.stream)

proc connectAndHold*(p: IoSocketPlugin): Future[void] {.async.} =
  ## Connect and keep the socket, so a teardown has something to leak.
  let c = await p.ctx.connectUnixSocket(p.socketPath)
  p.connectStatus = c.status
  p.connectMessage = c.message
  if c.status == ioOk: p.stream = c.stream

# ---------------------------------------------------------------------------
# The attempts — each one is a refusal a test asserts by making it
# ---------------------------------------------------------------------------

proc attemptSpawn*(p: IoProbePlugin; name: string;
                   args: seq[string] = @[]): Future[SpawnOutcome] =
  ## Used for the shell attempts. It is the plugin that reaches for the shell,
  ## not the suite, because §8.1.1's rule is about what a PLUGIN can do.
  p.ctx.spawnProcess(name, args)

proc attemptConnect*(p: IoProbePlugin; host: string;
                     port: int): Future[SocketOutcome] =
  p.ctx.connectTcp(host, port)

proc attemptTlsConnect*(p: IoProbePlugin; host: string;
                        port: int): Future[SocketOutcome] =
  p.ctx.connectTcp(host, port, tls = true)

proc attemptListen*(p: IoProbePlugin; host: string;
                    port: int): Future[ListenOutcome] =
  p.ctx.listenTcp(host, port)

proc attemptUnixConnect*(p: IoProbePlugin;
                         path: string): Future[SocketOutcome] =
  p.ctx.connectUnixSocket(path)

proc attemptRead*(p: IoProbePlugin; io: PluginIoContext;
                  path: string): Future[ReadOutcome] =
  p.ctx.readPath(io, path)

proc attemptWrite*(p: IoProbePlugin; io: PluginIoContext;
                   path, data: string): Future[WriteOutcome] =
  p.ctx.writePath(io, path, data)
