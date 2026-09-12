## plugin_host/plugin_io.nim — PLAT-8. The primitives Extensibility-Model.md
## §8.1 says the SDK owns: process, stream, socket, codec helpers — every one
## of them asynchronous, every one of them gated by a per-kind capability, and
## every handle attributable to the plugin that opened it.
##
## ## WHAT §8 ASKS FOR, AND WHERE EACH SENTENCE LANDS
##
## | §8.1's table | here |
## |---|---|
## | **Process** — spawn, argv, environment, working directory, stdio as streams, signals, exit status | `spawnProcess`, `PluginProcess`, `signalProcess`, `awaitExit` |
## | **Stream** — async read/write, backpressure, partial reads, EOF and error as values | `PluginStream`, `read`, `write`, `ReadOutcome`, `WriteOutcome` |
## | **Socket** — Unix domain, TCP, TLS; connect and listen | `connectUnixSocket`, `connectTcp`, `listenUnixSocket`, `listenTcp`, `acceptFrom` |
## | **Codec helpers** — length-prefixed and delimiter framing | `Framing`, `encodeFrame`, `takeFrame`, `readFrame` |
##
## ## RULE 1: THERE IS NO SYNCHRONOUS FORM OF ANY I/O CALL
##
## §8.1.3, in its own words: "All of it is asynchronous. §6.3's rule — a plugin
## may not block the UI — is not softened by a plugin doing real I/O; it is the
## reason the I/O API has no synchronous form at all. A read that could block
## is a read that returns a future."
##
## This is the load-bearing constraint of the whole milestone, and it is not
## stylistic. PLAT-7's budget stops a plugin from blocking the front-end only
## while there is nothing blocking for it to call: its own status section
## states the limit as "one overrun, attributed, then never again", and a
## blocking `read` inside that first overrun freezes a terminal for as long as
## the peer feels like taking. CTUI-14 spent a milestone removing exactly that.
##
## Three mechanisms hold it, and none of them is a convention:
##
##   1. **Every entry point returns a `Future`.** Asserted in the type system
##      rather than in prose — `test_plugin_io_sdk.nim` has a `static:` block
##      that requires `Future` of each entry point's result type, so a proc
##      that returned a value directly would not compile the suite.
##   2. **`PluginDeniedSyncIo` is refused in a plugin's SOURCE**, over its whole
##      reachable closure, by `ci/test/plugin-reactive-boundary.sh` — the same
##      walk, the same extractor and the same comment-stripper PLAT-7 built for
##      `PluginDeniedPrimitives`, over a second list. A plugin that wrote
##      `osproc.execProcess(...)` or `waitFor(fut)` is named by the gate.
##   3. **This module names none of them either**, and the gate checks that
##      too. An SDK whose own implementation blocks would satisfy rule 2 while
##      breaking rule 1 on the plugin's behalf.
##
## ## RULE 1a: THE ENTRY POINT IS NOT `{.async.}`, AND THAT IS DELIBERATE
##
## Every entry point below is a plain `proc` returning `Future[T]` that does
## two things synchronously and then delegates to an inner async proc:
##
##   * `ctx.checkBudget()` — PLAT-7's deadline checkpoint. `plugin_api.nim`'s
##     rule 3(b) says "PLAT-8's I/O primitives are required to be checkpoints
##     for the same reason", and a checkpoint that returns a FAILED FUTURE is
##     not one: `{.async.}` wraps the whole body in a `try`, so a raise before
##     the first `await` is captured into the future instead of propagating.
##     A plugin looping over `read` would then loop forever, collecting failed
##     futures, inside an overrun nothing could stop. Raising in the caller's
##     own frame is what makes §5.4's third layer reach the I/O API.
##   * the capability decision — refused BEFORE any resource exists, so a
##     refusal cannot leak the thing it refused.
##
## ## RULE 2: THE HOST RETAINS RESOLUTION, ARGUMENTS, HANDLES AND LIFETIME
##
## §8.1.1's four, each with the line that implements it:
##
##   * **Resolution.** `spawnProcess` takes a NAME. It refuses anything with a
##     path separator (`capabilities.isBareExecutableName`), requires the name
##     to be in the manifest's declared set, and resolves it itself with
##     `findExe` against the host's own PATH. A plugin never hands over a path.
##   * **No command line.** `args` is a `seq[string]` and reaches `execve` as
##     `argv`. `startProcess` is called WITHOUT `poEvalCommand`, so there is no
##     command line anywhere in the path from the plugin to the kernel and the
##     INJECTION class does not exist to be filtered. `test_plugin_io_sdk.nim`
##     asserts this by ATTEMPTING it, twice: once by naming a shell (refused —
##     it is not declared), and once by putting shell metacharacters in an
##     argument to a declared program and observing that the program received
##     them as one literal argument and that nothing ran.
##
##     **THIS IS NOT "a plugin cannot reach a shell", AND THE MILESTONE SAID
##     THAT UNTIL 2026-09-09.** It is the narrower and true claim that the host
##     never builds a command line, so nothing the plugin writes is ever
##     re-parsed by a shell. A plugin that DECLARES an exec wrapper reaches a
##     shell through argv alone and no quoting rule can prevent it — measured
##     with `env sh -c`, printing a sentinel and creating a file. What bounds
##     that is rule 3, not this one, and conflating the two is how the false
##     sentence survived: the suite's own `env` case is two suites away from
##     the case asserting the refusal.
##   * **Ownership of handles.** Every process, stream, socket and listener is
##     registered in the plugin's `HandleTable` at the moment it exists, with
##     the closer that releases it. `host.deactivate` sweeps the table.
##   * **Accounting.** The table is per plugin and reachable only through that
##     plugin's context, so a handle cannot exist unattributed.
##
## ## RULE 3: `process` IS A GENERAL-PURPOSE GRANT, AND THE MODEL SAYS SO
##
## **This rule said the opposite until 2026-09-09, and it was false.** It read
## "`socket:remote` IS GRANTABLE, AND `process` IS NOT THE HOLE IN IT", on the
## argument that an executable is declared by name, that the grants are
## separate, and that the only residual is "a declared program is a program —
## `sort` could open a socket".
##
## A verification pass measured all three away. A plugin declaring `trace`,
## `fs:read` and `process` with `env` as its one declared executable — **no
## socket capability, no declared host, no trace-egress grant** — read a
## recording and shipped it over TCP to a real listener, and the user was shown
## no exfiltration disclosure at all. The same plugin reached a shell through
## `env sh -c …`, argv only, with no metacharacters anywhere, which falsifies
## the milestone's "a plugin cannot reach a shell" as well.
##
## The residual as written describes something different in kind and does not
## cover this. `sort` opening a socket is a program doing something incidental;
## `env`, `xargs`, `find`, `sh` and `python3` are EXEC WRAPPERS, and declaring
## any one of them makes `process` a superset of every other grant at once —
## past the declared-host set, past the loopback/remote split, past the fs
## roots, past `trace`, and past the egress gate.
##
## So the model is now the honest one, and it is enforced rather than warned
## about (`capabilities.SubsumingCapabilities`, `effectiveCapabilities`):
##
##   * **`process` subsumes every other capability.** Stated in
##     `describeGrants`, on the `process` row itself, so a user reading
##     "may spawn: env" is told in the same breath that `env` is not a bound.
##   * **The egress gate binds `process`**, not only `socket:remote`.
##     `needsTraceEgressGrant` asks its question of the EFFECTIVE set, so a
##     `process` grant needs the explicit acknowledgement on its own — the
##     composition that exfiltrated a recording is refused at LOAD, and refused
##     again in `decide(irSpawnProcess)` if it ever reaches the runtime.
##   * A denylist of exec wrappers was considered and REFUSED as the primary
##     defence: it is the shape of PLAT-7's import-extractor blocklist, which
##     took seven passes and still has a residual, and it is unsound in
##     principle because the host cannot know what an arbitrary binary does
##     with its argv. The rule binds by capability COMPOSITION instead, which
##     nothing a plugin author writes can respell around.
##
## What survives of the old argument is only this: `socket:remote` is grantable
## rather than forbidden, because refusing it outright pushes authors toward
## `process`, and `process` is strictly worse. That is still right, and it is
## now right for the stated reason instead of a false one.
##
## ## ERRORS AND EOF ARE VALUES
##
## §8.1's Stream row: "EOF and error as values". So `read` completes with a
## `ReadOutcome` carrying `ioEof` rather than raising, `connectTcp` completes
## with `ioRefused` and the policy's own sentence rather than raising, and a
## plugin's normal path is a `case` over a closed enum. The futures below
## complete; they do not fail. The one thing that DOES raise is `checkBudget`,
## and it raises for the reason rule 1a gives.
##
## ## NO MOCKS
##
## Nothing here stands in for anything. `startProcess` is `std/osproc`'s,
## the pipes are the kernel's, `AsyncFile` and `AsyncSocket` are
## `std/asyncfile` and `std/asyncnet` over `std/asyncdispatch`'s real
## dispatcher, and `findExe` searches the real PATH. The suites drive `cat`,
## `printf` and a real `python3` peer over a real Unix socket.
##
## ## THE STATED LIMITS
##
## Four, and each is a bound on the WORK rather than on the evidence:
##
##   1. **The process arm is POSIX.** Wrapping a child's stdio as async streams
##      needs the pipe file descriptors and `O_NONBLOCK`; the Windows arm needs
##      overlapped I/O on the same handles and is not written. On a non-POSIX
##      target `spawnProcess` completes with `ioUnsupported` naming the
##      platform — a refusal, not a silent failure, and not a stub that
##      pretends to have spawned something.
##   2. **TLS is behind `-d:ssl`.** `connectTcp(tls = true)` wraps the socket
##      with `std/net`'s OpenSSL context, which only exists when the binary was
##      built with an SSL backend. Without it the call completes with
##      `ioUnsupported` naming the define. The capability decision is taken
##      identically in both builds, so a TLS connection is never MORE permitted
##      than a plaintext one to the same host.
##   3. **`trace` has no reader of its own**, because PLAT-7's `PluginContext`
##      deliberately carries no CodeTracer state and PLAT-9 owns the surfaces
##      that would hand a plugin recorded data. What `trace` gates HERE is
##      real and measured: a path under one of the host's declared trace roots
##      is refused to `readPath` unless `trace` is granted, so `fs:read` cannot
##      be used as a way around it. **That containment is on the REALPATH as of
##      2026-09-09** — until then it was textual over an unresolved path, and
##      an ordinary symlink inside a declared root read the recording.
##   4. **A declared program is not sandboxed AT ALL, and that is the model
##      rather than a residual.** This limit used to read "a declared program
##      is a program — `sort` could open a socket", which understates it by a
##      category: the program runs with the user's full authority, and a
##      declared exec wrapper runs an arbitrary OTHER program with it. So
##      `process` subsumes every capability on the list, the egress gate binds
##      it, and `describeGrants` says so on the `process` row. See rule 3.
##
##      **The one thing the host still owes is a HARD LINK.** A hard link from
##      inside a declared root to a recording defeats path-based containment
##      with nothing to resolve. Making one needs `link(2)`, which this SDK
##      does not offer, so it needs `process` — which is now disclosed and
##      gated. `openVerified` states the seam and fails closed.

import std/[strutils]

import ./plugin_api

const
  PluginDeniedSyncIo*: array[41,
      tuple[primitive, replacement: string, hostOnly: bool]] = [
    ## THE SECOND DENIED LIST, and it is read by both halves the same way
    ## `PluginDeniedPrimitives` is: `ci/test/plugin-reactive-boundary.sh`
    ## parses the names out of this table rather than hardcoding them, so the
    ## SDK and the gate cannot drift.
    ##
    ## Left: a routine that BLOCKS THE CALLING THREAD on I/O or on a child.
    ## Right: what a plugin writes instead. Every entry has a replacement — the
    ## same property that makes `PluginDeniedPrimitives` a narrowing rather
    ## than a removal.
    ##
    ## `read`, `write`, `close` and `send` are deliberately NOT here. They are
    ## the SDK's own asynchronous spellings and the words a plugin must use;
    ## a denied list that refused them would refuse the sanctioned path, which
    ## is the shape Verification-Harness-Traps §4a warns about from the other
    ## side. `PluginSystemSurfaceExempt` below carries `write` and `close` with
    ## that reason attached, so the exemption is REVIEWED rather than implied
    ## by an absence — and states what they can still reach.
    ##
    ## **`open` WAS ON THAT LIST UNTIL 2026-09-09 AND IS NOT ANY MORE.** The
    ## claim was that `handles.open` is the SDK's own registration proc, so
    ## denying the name would refuse the sanctioned path. That was a naming
    ## collision rather than a law of nature: the proc is called
    ## `registerHandle` now, it never opened anything, and `open` is denied
    ## like any other name. See `handles.nim`'s comment on the rename.
    ##
    ## ## THE `system` HALF OF THIS TABLE IS DERIVED, NOT TYPED
    ##
    ## The entries below the `system` rule are not a list somebody extended
    ## each time somebody else found a hole. They are the exported surface of
    ## `std/syncio` and `system/compilation.nim`, swept off the PINNED
    ## COMPILER'S OWN SOURCE by `ci/lib/system-io-surface.sh`, and checked for
    ## completeness on every gate run by `system-surface-enumerated`
    ## (check 23): every derived name must appear HERE or on
    ## `PluginSystemSurfaceExempt`, and a name on neither reddens the gate.
    ##
    ## THAT MECHANISM EXISTS BECAUSE THE HAND-KEPT VERSION LOST THREE TIMES,
    ## and the third time is the one worth reading. The residual was written
    ## down as ten names with `open` among them; `open` was denied nowhere, and
    ## the buffer family AROUND it was not written down at all, so a plugin
    ## whose entire import list was `import codetracer_plugin` had a complete
    ## file I/O API — measured, `SYSIO-READ[gpu-server-001]` and
    ## `SYSIO-WRITE-OK`, with no capability, no manifest entry, no import and
    ## no FFI pragma. Then, sweeping for the repair, two MORE names turned up
    ## that nobody's list had:
    ##
    ##   * `reopen(stdin, "/etc/hostname", fmRead)` reads any file with NO
    ##     `open` at all — `stdin` is already a `File` — so denying `open`
    ##     alone would have left the hole exactly where it was;
    ##   * `for l in lines("/etc/hostname")` reads any file with ONE
    ##     identifier.
    ##
    ## Three passes, three enumerations, each one short. The fix is not a
    ## fourth enumeration; it is deriving the set from the language.
    ##
    ## THE THIRD FIELD IS `hostOnly`, and it is what lets the gate hold the SDK
    ## to the same rule it holds a plugin to. `startProcess` does not block —
    ## it returns as soon as the child exists — and the reason a PLUGIN may not
    ## name it is that its pipes are `std/streams`, which do. The host is the
    ## one place that is allowed to call it, because the host is what wraps
    ## those pipes as `AsyncFile`s. Every other entry blocks outright, and the
    ## gate's `sdk-does-not-block` check asserts this file names none of them.
    ## Marking the exception in the DATA rather than in the gate is what stops
    ## the gate from growing a hardcoded second list that could drift.
    ("waitFor",        "await, inside the plugin's own async proc",        false),
    ("runForever",     "await; the host owns the dispatcher",              false),
    ("startProcess",   "ctx.spawnProcess (the host resolves the name)",    true),
    ("execProcess",    "ctx.spawnProcess",                                 false),
    ("execCmd",        "ctx.spawnProcess (there is no command line)",      false),
    ("execCmdEx",      "ctx.spawnProcess",                                 false),
    ("execShellCmd",   "ctx.spawnProcess (there is no shell)",             false),
    ("waitForExit",    "await ctx.awaitExit(process)",                     false),
    ("readFile",       "await ctx.readPath(path)",                         false),
    ("writeFile",      "await ctx.writePath(path, data)",                  false),
    ("readAll",        "await stream.read(n), until ioEof",                false),
    ("newSocket",      "await ctx.connectTcp / ctx.connectUnixSocket",     false),
    ("dial",           "await ctx.connectTcp(host, port)",                 false),
    # ---- ADDED 2026-09-09, FROM A VERIFICATION PASS THAT FOUND A FOURTH WAY
    # TO BLOCK. All five below compile in a plugin's scope today and none was
    # on the list, so the milestone's "no synchronous form of any I/O call"
    # was a claim about thirteen names rather than about the property.
    #
    # WHICH HALF REFUSES WHICH — measured, not assumed, because the two halves
    # do not have the same reach:
    #
    #   * `sleep` is `std/os`'s. The LANGUAGE half cannot refuse it: nothing on
    #     the plugin surface re-exports `std/os`, so it is not in an `export …
    #     except` clause to filter, and it arrives by module-qualified lookup
    #     (`os.sleep`) which `except` does not filter anyway. The SOURCE GATE
    #     refuses it, in both spellings, by identifier.
    #   * `readLine`, `readLines`, `readChar`, `staticExec`, `gorge` and
    #     `gorgeEx` are in `system`. `system` is auto-imported and exported by
    #     nothing, so it cannot be filtered out of any scope at all — exactly
    #     the property already recorded for `readFile` above. **The source gate
    #     is the ONLY half that refuses these six.** A reader must not take
    #     their presence on this list as "the compiler stops them".
    ("sleep",          "await sleepAsync(ms)",                             false),
    ("readLine",       "await stream.read(n) / stream.readFrame(...)",     false),
    ("readLines",      "await ctx.readPath(path), then split it",          false),
    ("readChar",       "await stream.read(1)",                             false),
    ("staticExec",     "await ctx.spawnProcess (there is no shell, and " &
                       "compile time is not inside the sandbox)",          false),
    ("gorge",          "await ctx.spawnProcess — `gorge` IS `staticExec`", false),
    ("gorgeEx",        "await ctx.spawnProcess — `gorgeEx` IS `staticExec`",
                                                                           false),
    # ---- ADDED 2026-09-09 BY THE DERIVED SWEEP. Twenty-one names, every one
    # of them reachable in a plugin with no import and no pragma, because
    # `system.nim` ends with `export syncio`. See the header.
    #
    # `open` IS `hostOnly` AND NOTHING ELSE HERE IS. A plugin naming `open` is
    # refused by check 15; the SDK is exempt at check 16 for ONE site,
    # `posix.open` inside `openVerified`, which is the mediated open taken
    # after `decide` — the same argument `startProcess` carries above, and it
    # covers one line rather than six only because `handles.open` was renamed.
    # ON ONE LINE, AND THAT IS LOAD-BEARING: the gate reads `hostOnly` off the
    # SAME line as the name (`table_names … host-only` matches `, true)` in the
    # record it just matched `("open"` in). Split across a continuation the flag
    # is invisible, `open` is treated as an ordinary denied name, and
    # `sdk-does-not-block` fires on `posix.open` — measured, first run.
    ("open",             "await ctx.readPath / ctx.writePath (the host opens)", true),
    ("reopen",           "await ctx.readPath — `reopen` re-binds an ALREADY " &
                         "OPEN File to a path, so it needs no `open`",  false),
    ("lines",            "await ctx.readPath(path), then split it — `lines` " &
                         "opens the path itself",                       false),
    ("readBuffer",       "await stream.read(n)",                        false),
    ("readBytes",        "await stream.read(n)",                        false),
    ("readChars",        "await stream.read(n)",                        false),
    ("writeBuffer",      "await stream.write(data)",                    false),
    ("writeBytes",       "await stream.write(data)",                    false),
    ("writeChars",       "await stream.write(data)",                    false),
    ("writeLine",        "await stream.writeFrame(line, frDelimited)",  false),
    ("getFileSize",      "read until the outcome is ioEof; there is no size " &
                         "query on a stream",                           false),
    ("getFilePos",       "a plugin reads a stream forwards; there is no seek",
                                                                        false),
    ("setFilePos",       "a plugin reads a stream forwards; there is no seek",
                                                                        false),
    ("endOfFile",        "read until the outcome is ioEof",             false),
    ("flushFile",        "await stream.write — it completes when the bytes " &
                         "have been accepted, which IS the flush",      false),
    ("getFileHandle",    "a plugin holds a PluginStream, not a descriptor",
                                                                        false),
    ("getOsFileHandle",  "a plugin holds a PluginStream, not a descriptor",
                                                                        false),
    ("setInheritable",   "the host owns what a spawned child inherits", false),
    ("setStdIoUnbuffered", "the host owns its own standard streams",    false),
    ("slurp",            "await ctx.readPath — `slurp` IS `staticRead`, and " &
                         "compile time is not inside the sandbox",      false),
    ("staticRead",       "await ctx.readPath (compile time is not inside the " &
                         "sandbox)",                                    false),
  ]

  PluginSystemSurfaceExempt*: array[27, tuple[primitive, replacement: string]] = [
    ## THE OTHER HALF OF THE DERIVED SWEEP: what `system` puts in every
    ## plugin's scope that is deliberately NOT refused, WITH THE REASON.
    ##
    ## An exemption that is merely an ABSENCE from a denied list is
    ## indistinguishable from an oversight — which is exactly how `open`,
    ## `readBuffer` and `writeBuffer` came to be an unmediated file I/O API
    ## while the residual paragraph claimed nine of ten names were covered. So
    ## the sweep in `ci/lib/system-io-surface.sh` derives the whole surface and
    ## check 23 requires every member to be on ONE of these two tables. This is
    ## the table that says "we looked at it and it stays", and the right-hand
    ## column is the argument.
    ##
    ## Left: the name. Right: why it is not a way to reach the operating
    ## system.
    ##
    ## THE FIRST TWO ROWS ARE THE ONLY LOAD-BEARING ONES. The rest are types,
    ## compile-time constants and predicates that produce no effect at all.
    ("write",            "THE SDK'S OWN SPELLING — `stream.write(data)` is " &
                         "the sanctioned path and denying the name would deny " &
                         "it. What `write(f: File, …)` can still reach is the " &
                         "three File VALUES below, because every routine that " &
                         "binds a path or a descriptor to a File is denied"),
    ("close",            "THE SDK'S OWN SPELLING, same as `write` — " &
                         "`stream.close()`, `process.close()`"),
    ("stdin",            "the host's own standard input, already open. It is " &
                         "a File a plugin can WRITE to and CLOSE — the two " &
                         "exempt routines — but NOT READ: every routine that " &
                         "could (`readLine`, `readAll`, `readBuffer`, " &
                         "`readChar`, `readChars`, `lines`) is denied above. " &
                         "And it is not a path: `reopen`, the one routine " &
                         "that could re-bind it to one, is denied. (This row " &
                         "read 'WRITE to and READ from' until 2026-09-09; " &
                         "the read half was measured false in verification.)"),
    ("stdout",           "the host's own standard output; see `stdin`"),
    ("stderr",           "the host's own standard error; see `stdin`"),
    ("stdmsg",           "a template returning `stderr` or `stdout`; see " &
                         "`stdin`"),
    ("File",             "a type. Naming it binds no path, and every routine " &
                         "that RETURNS one — `open`, `reopen` — is denied"),
    ("FileHandle",       "a type; see `File` above"),
    ("FileMode",         "an enum; see `File` above"),
    ("FileSeekPos",      "an enum; see `File` above"),
    ("&=",               "string append spelled as an operator. It is `add`, " &
                         "and it opens nothing"),
    ("nimrtl",           "the shared-library FILENAME, behind " &
                         "`when defined(useNimRtl)`. A string constant; the " &
                         "sweep reads every `when` branch on purpose, so it " &
                         "reports names `nim jsondoc` does not"),
    ("compiles",         "a compile-time predicate over an expression; it " &
                         "emits nothing"),
    ("declared",         "a compile-time predicate over a symbol"),
    ("declaredInScope",  "a compile-time predicate over a symbol"),
    ("defined",          "a compile-time predicate over a define"),
    ("compileOption",    "a compile-time predicate over a switch"),
    ("astToStr",         "a compile-time rendering of an expression"),
    ("currentSourcePath", "the path of the SOURCE FILE, at compile time. It " &
                         "discloses a path and reads nothing at it"),
    ("isMainModule",     "a compile-time boolean"),
    ("nimvm",            "a compile-time boolean"),
    ("runnableExamples", "a documentation form; its body is not this module"),
    ("CompileDate",      "a compile-time string constant"),
    ("CompileTime",      "a compile-time string constant"),
    ("NimMajor",         "a compile-time integer constant"),
    ("NimMinor",         "a compile-time integer constant"),
    ("NimPatch",         "a compile-time integer constant"),
  ]

  PluginSystemSurfaceExemptConst* = "PluginSystemSurfaceExempt"
    ## Read by the gate by NAME, from here, for the same drift reason
    ## `PluginAllowedStdlibModulesConst` is: a rename that did not carry the
    ## gate with it would leave check 23 parsing an empty exempt table, which
    ## reddens the gate rather than widening the surface silently.

type
  IoStatus* = enum
    ## Every way an I/O call can end, as a VALUE. §8.1's "EOF and error as
    ## values" is this enum plus the outcome records below.
    ioOk
    ioEof            ## the peer closed, or the child's stdout reached the end
    ioRefused        ## a capability decision. `message` is the policy's own
    ioFailed         ## the OS said no
    ioClosed         ## the handle was reclaimed under the caller
    ioUnsupported    ## this build or this platform has no such primitive

  Framing* = enum
    ## §8.1's fourth row: "so every plugin does not re-implement the loop where
    ## framing bugs live". Two, because these are the two a byte protocol
    ## actually uses.
    frLengthPrefixed  ## a 4-byte big-endian unsigned length, then the payload
    frDelimited       ## a payload, then one delimiter byte

  ReadOutcome* = object
    status*: IoStatus
    data*: string
      ## PARTIAL READS ARE NORMAL, not an error: `data.len` may be anything
      ## from 1 to the requested maximum, and a caller wanting exactly n bytes
      ## loops or uses a frame. A read that returned only whole buffers would
      ## either buffer unboundedly or deadlock on a peer that speaks in small
      ## pieces.
    message*: string

  WriteOutcome* = object
    status*: IoStatus
    written*: int
      ## BACKPRESSURE. The future does not complete until the bytes have been
      ## accepted, so a plugin writing faster than the peer reads is suspended
      ## in its own await rather than growing a buffer inside the host. On
      ## success `written == data.len`; a short write is `ioFailed` with what
      ## got through, because a silent short write is the framing bug the
      ## codec helpers exist to remove.
    message*: string

  ExitOutcome* = object
    status*: IoStatus
    code*: int
    signalled*: bool
      ## `true` when the child died on a signal. `code` is then the signal
      ## number. A caller that only reads `code` would otherwise see a plain
      ## nonzero and could not tell a program that failed from one that was
      ## killed — which is exactly the distinction a teardown test needs.
    message*: string

  FrameOutcome* = object
    status*: IoStatus
    frame*: string
    message*: string

  PluginStreamKind* = enum
    pskProcessInput
    pskProcessOutput
    pskProcessError
    pskSocket

  PluginIoContext* = ref object
    ## What an I/O call needs that `PluginContext` does not carry: where the
    ## host says the recordings live.
    ##
    ## It is a SEPARATE object rather than three more fields on
    ## `PluginContext`, because `PluginContext` is what a plugin holds and
    ## these are the host's policy inputs. A plugin that could edit its own
    ## trace roots could read a recording without `trace`.
    traceRoots*: seq[string]

const
  MaxFrameBytes* = 64 * 1024 * 1024
    ## A length-prefixed frame larger than this is refused rather than
    ## allocated. A 4-byte length field is 4 GiB of rope for a peer to hang the
    ## host with, and "the plugin's peer sent a large number" must not be a way
    ## to exhaust the process.

  DefaultReadChunk* = 64 * 1024

# ---------------------------------------------------------------------------
# The codec helpers — PURE, and therefore the same code on every backend
# ---------------------------------------------------------------------------
#
# These are functions over strings. They open nothing, so they compile and run
# wherever the facade does, and the framing loop that every protocol gets wrong
# is written and tested once.

func encodeFrame*(payload: string; framing: Framing; delim = '\n'): string =
  ## The wire form of one message.
  ##
  ## A delimited frame containing the delimiter is a protocol error rather than
  ## something to escape: escaping would need an unescaper on the far side and
  ## the far side is somebody else's program. The caller gets an empty string,
  ## which `writeFrame` turns into `ioFailed`.
  case framing
  of frLengthPrefixed:
    let n = payload.len
    if n > MaxFrameBytes: return ""
    result = newStringOfCap(n + 4)
    result.add chr((n shr 24) and 0xff)
    result.add chr((n shr 16) and 0xff)
    result.add chr((n shr 8) and 0xff)
    result.add chr(n and 0xff)
    result.add payload
  of frDelimited:
    if delim in payload: return ""
    result = payload & delim

type
  TakeStatus* = enum
    tsFrame        ## one whole frame came out of the buffer
    tsIncomplete   ## the buffer does not yet hold a whole frame
    tsOverlong     ## a length prefix beyond `MaxFrameBytes`

func takeFrame*(buffer: var string; framing: Framing; frame: var string;
                delim = '\n'): TakeStatus =
  ## Consume one frame from `buffer` if it holds one. The buffer is a `var`
  ## because framing IS a buffer: the whole reason this is a shared helper is
  ## that "read some bytes, keep the tail for next time" is where the bugs are.
  case framing
  of frLengthPrefixed:
    if buffer.len < 4: return tsIncomplete
    let n = (ord(buffer[0]) shl 24) or (ord(buffer[1]) shl 16) or
            (ord(buffer[2]) shl 8) or ord(buffer[3])
    if n > MaxFrameBytes: return tsOverlong
    if buffer.len < 4 + n: return tsIncomplete
    frame = buffer[4 ..< 4 + n]
    buffer = buffer[4 + n .. ^1]
    tsFrame
  of frDelimited:
    let idx = buffer.find(delim)
    if idx < 0: return tsIncomplete
    frame = buffer[0 ..< idx]
    buffer = buffer[idx + 1 .. ^1]
    tsFrame

# ---------------------------------------------------------------------------
# The decision, in one place both arms call
# ---------------------------------------------------------------------------

func grantsOf*(ctx: PluginContext): GrantSet =
  ctx.manifest.grants

func refusalOutcome[T](d: Decision): T =
  result = T(status: ioRefused, message: d.reason)

func pathIsRecorded*(io: PluginIoContext; path: string): bool =
  ## Is this path inside a recording the host has declared?
  ##
  ## The rule this exists for: `fs:read` must not be a way around `trace`. A
  ## plugin granted a directory that happens to contain a trace would otherwise
  ## read the recorded program's memory and I/O with a grant that says nothing
  ## about recordings — and §9 is explicit that a trace is "whatever the
  ## recorded program held — credentials, keys, customer data".
  if io.isNil: return false
  for root in io.traceRoots:
    if pathIsUnder(path, root): return true
  false

when defined(js):
  # The facade compiles on the JS backend, and a browser has no child
  # processes and no Unix sockets. The codec helpers, the outcome types and
  # the capability decision above are all pure and are present on both arms;
  # the primitives are not, in the same shape `codetracer_embed.nim`'s
  # filesystem half already takes ("behind `when not defined(js)` so this
  # facade still compiles on the JS backend").
  #
  # This is a stated absence rather than a stub that reports success.
  discard

else:
  import std/[asyncdispatch, asyncfile, asyncnet, nativesockets, os, osproc,
              strtabs]
  when defined(posix):
    import std/posix
  when defined(ssl):
    import std/net as std_net

  # THE ASYNC VOCABULARY REACHES A PLUGIN, MINUS THE FOUR THAT BLOCK.
  #
  # A plugin writing `await ctx.spawnProcess(...)` needs `Future`, `async`,
  # `await` and `sleepAsync` in scope, and they arrive here because this
  # module is on the facade. `waitFor`, `runForever`, `poll` and `drain` are
  # filtered out by the same `export … except` mechanism
  # `codetracer_plugin.nim` uses for the ten reactive primitives, and for the
  # same reason: they are the spellings that turn an asynchronous API back
  # into a blocking one, which is §8.1.3's whole prohibition.
  #
  # The filter is HALF the denial, exactly as it is there. `export … except`
  # does not filter module-qualified lookup, and `system.readFile` is not
  # exported by anything so it cannot be filtered at all — measured: with
  # PLAT-7's surface alone, `compiles(readFile("x"))` is **true** in a plugin
  # today. `PluginDeniedSyncIo` and the source gate are the other half.
  export asyncdispatch except waitFor, runForever, poll, drain

  type
    PluginStream* = ref object
      ## §8.1's Stream row. One object over two very different fds — a pipe to
      ## a child and a socket — because a plugin composing a protocol should
      ## not care which one it got, and `readFrame` below is written once for
      ## both.
      kind*: PluginStreamKind
      handle*: PluginHandle
      ctx: PluginContext
      buffer: string
        ## The framing tail. Held HERE rather than by the plugin, because a
        ## per-stream buffer owned by the caller is the thing everybody
        ## forgets to carry between reads.
      atEof: bool
      file: AsyncFile
      socket: AsyncSocket

    PluginProcess* = ref object
      ## §8.1's Process row.
      handle*: PluginHandle
      ctx: PluginContext
      name*: string
      argv*: seq[string]
      pid*: int
      stdin*: PluginStream
      stdout*: PluginStream
      stderr*: PluginStream
      proc0: Process
      reaped: bool
      exitCode: int
      exitSignalled: bool

    PluginListener* = ref object
      ## §8.1's "connect and listen".
      handle*: PluginHandle
      ctx: PluginContext
      socket: AsyncSocket
      unixPath: string

    SpawnOutcome* = object
      status*: IoStatus
      process*: PluginProcess
      message*: string

    SocketOutcome* = object
      status*: IoStatus
      stream*: PluginStream
      message*: string

    ListenOutcome* = object
      status*: IoStatus
      listener*: PluginListener
      message*: string

    PluginSignal* = enum
      ## §8.1's "signals". Four, spelled by intent rather than by number, so a
      ## plugin cannot send `SIGSEGV` to something by arithmetic.
      psInterrupt = "SIGINT"
      psTerminate = "SIGTERM"
      psHangup    = "SIGHUP"
      psKill      = "SIGKILL"

  # -------------------------------------------------------------------------
  # Streams
  # -------------------------------------------------------------------------

  proc closeStream*(s: PluginStream) =
    ## Release one stream. Idempotent through the handle table, which clears
    ## the closer before running it.
    if s.isNil: return
    if not s.handle.isNil:
      s.ctx.state.handles.close(s.handle)

  proc rawCloseStream(s: PluginStream) =
    ## What the handle table runs. Never called directly — going through the
    ## table is what keeps the accounting true.
    s.atEof = true
    if not s.file.isNil:
      try: s.file.close()
      except CatchableError, Defect: discard
      s.file = nil
    if not s.socket.isNil:
      try: s.socket.close()
      except CatchableError, Defect: discard
      s.socket = nil

  proc isOpen*(s: PluginStream): bool =
    (not s.file.isNil) or (not s.socket.isNil)

  proc readInner(s: PluginStream; maxBytes: int): Future[ReadOutcome] {.async.} =
    if not s.isOpen:
      return ReadOutcome(status: ioClosed,
        message: "the stream was closed or reclaimed")
    if s.atEof:
      return ReadOutcome(status: ioEof)
    var chunk = ""
    try:
      if not s.file.isNil:
        chunk = await s.file.read(maxBytes)
      else:
        chunk = await s.socket.recv(maxBytes)
    except CatchableError as e:
      return ReadOutcome(status: ioFailed, message: e.msg)
    if chunk.len == 0:
      s.atEof = true
      return ReadOutcome(status: ioEof)
    ReadOutcome(status: ioOk, data: chunk)

  proc read*(s: PluginStream; maxBytes = DefaultReadChunk): Future[ReadOutcome] =
    ## A partial read. See `ReadOutcome.data`.
    ##
    ## NOT `{.async.}` — see rule 1a in the header. `checkBudget` must raise in
    ## the caller's frame or it is not a checkpoint.
    s.ctx.checkBudget()
    if maxBytes <= 0:
      let f = newFuture[ReadOutcome]("plugin_io.read")
      f.complete(ReadOutcome(status: ioFailed,
        message: "a read of " & $maxBytes & " bytes asks for nothing"))
      return f
    readInner(s, maxBytes)

  proc writeInner(s: PluginStream; data: string): Future[WriteOutcome] {.async.} =
    if not s.isOpen:
      return WriteOutcome(status: ioClosed,
        message: "the stream was closed or reclaimed")
    try:
      if not s.file.isNil:
        await s.file.write(data)
      else:
        await s.socket.send(data)
    except CatchableError as e:
      return WriteOutcome(status: ioFailed, message: e.msg)
    WriteOutcome(status: ioOk, written: data.len)

  proc write*(s: PluginStream; data: string): Future[WriteOutcome] =
    ## Backpressure is the future: it completes when the bytes are accepted.
    s.ctx.checkBudget()
    writeInner(s, data)

  proc readFrameInner(s: PluginStream; framing: Framing;
                      delim: char): Future[FrameOutcome] {.async.} =
    var frame = ""
    while true:
      case takeFrame(s.buffer, framing, frame, delim)
      of tsFrame:
        return FrameOutcome(status: ioOk, frame: frame)
      of tsOverlong:
        return FrameOutcome(status: ioFailed,
          message: "the peer announced a frame larger than " &
                   $MaxFrameBytes & " bytes")
      of tsIncomplete:
        discard
      let r = await readInner(s, DefaultReadChunk)
      case r.status
      of ioOk:
        s.buffer.add r.data
      of ioEof:
        # A CLEAN EOF AND A TRUNCATED FRAME ARE DIFFERENT FACTS. A peer that
        # closed between messages is normal; one that closed halfway through
        # a length-prefixed payload lost data, and a helper that reported both
        # as "eof" would hide the second.
        if s.buffer.len == 0:
          return FrameOutcome(status: ioEof)
        return FrameOutcome(status: ioFailed,
          message: "the peer closed with " & $s.buffer.len &
                   " byte(s) of an incomplete frame buffered")
      else:
        return FrameOutcome(status: r.status, message: r.message)

  proc readFrame*(s: PluginStream; framing: Framing;
                  delim = '\n'): Future[FrameOutcome] =
    ## One whole message, however many reads that takes. §8.1's fourth row.
    s.ctx.checkBudget()
    readFrameInner(s, framing, delim)

  proc writeFrameInner(s: PluginStream; payload: string; framing: Framing;
                       delim: char): Future[WriteOutcome] {.async.} =
    let encoded = encodeFrame(payload, framing, delim)
    if encoded.len == 0 and payload.len >= 0 and framing == frDelimited and
       delim in payload:
      return WriteOutcome(status: ioFailed,
        message: "a delimited frame may not contain its own delimiter " &
                 "(0x" & toHex(ord(delim), 2) & ")")
    if encoded.len == 0 and framing == frLengthPrefixed:
      return WriteOutcome(status: ioFailed,
        message: "a frame of " & $payload.len & " bytes exceeds " &
                 $MaxFrameBytes)
    return await writeInner(s, encoded)

  proc writeFrame*(s: PluginStream; payload: string; framing: Framing;
                   delim = '\n'): Future[WriteOutcome] =
    s.ctx.checkBudget()
    writeFrameInner(s, payload, framing, delim)

  proc newStreamOverFile(ctx: PluginContext; kind: PluginStreamKind;
                         f: AsyncFile; description: string): PluginStream =
    result = PluginStream(kind: kind, ctx: ctx, file: f)
    let s = result
    result.handle = ctx.state.handles.registerHandle(hkProcessStream, description,
      proc() = rawCloseStream(s))

  proc newStreamOverSocket(ctx: PluginContext; sock: AsyncSocket;
                           description: string): PluginStream =
    result = PluginStream(kind: pskSocket, ctx: ctx, socket: sock)
    let s = result
    result.handle = ctx.state.handles.registerHandle(hkSocket, description,
      proc() = rawCloseStream(s))

  # -------------------------------------------------------------------------
  # Process
  # -------------------------------------------------------------------------

  proc rawKill(p: PluginProcess) =
    ## The closer registered for the process handle, and the whole of
    ## §8.1.1's "Deactivation closes them — the reason a plugin cannot leak a
    ## daemon past its own lifetime".
    ##
    ## SIGKILL rather than SIGTERM, and that is a decision rather than
    ## laziness: this runs when the plugin is already gone, so there is nobody
    ## left to notice a child that chose to ignore a polite request. A plugin
    ## that wants a graceful shutdown sends `psTerminate` itself while it is
    ## still alive.
    ##
    ## AND IT REAPS. A kill without a `waitpid` leaves a zombie, which is a
    ## process the OS still lists — so a test asserting "no surviving child"
    ## against `/proc` would fail, correctly, on a teardown that only killed.
    ##
    ## ## IT KILLS THE PROCESS GROUP, NOT THE PID (fixed 2026-09-09)
    ##
    ## Until 2026-09-09 this sent `SIGKILL` to `p.pid` and nothing else, and a
    ## verification pass measured what that is worth for the shape
    ## `startLongRunning`'s own comment names — "a language server or an
    ## analyser daemon": `after deactivate: child alive=false grandchild
    ## alive=true`. The child died, its own child did not, and the milestone's
    ## "no surviving child" was true of exactly one process.
    ##
    ## `spawnInner` therefore passes `poDaemon`, which is `POSIX_SPAWN_SETPGROUP`
    ## with a pgroup of `0` — the kernel puts the child in a process group of
    ## its own, atomically at spawn, so there is no window in which a
    ## parent-side `setpgid` could lose a race with `execve`. Every descendant
    ## inherits that group unless it deliberately leaves, so one `killpg`
    ## reaches the subtree.
    ##
    ## **THE `pgid == pid` GUARD IS NOT DEFENSIVE DECORATION.** If the child is
    ## NOT its own group leader, its group is CodeTracer's, and `killpg` on it
    ## would SIGKILL the editor, the front-end and this process. So the group
    ## is read back from the kernel and compared with the pid before anything
    ## is signalled, and the fallback when they differ is the old behaviour —
    ## kill the one pid — which is worse and is not catastrophic. `poDaemon` is
    ## honoured only on nim's `posix_spawn` path (`startProcessAuxFork` ignores
    ## it), so this is a state a build really can reach.
    if p.reaped: return
    when defined(posix):
      if p.pid > 0:
        let pgid = getpgid(Pid(p.pid))
        if pgid == Pid(p.pid):
          discard posix.killpg(pgid, SIGKILL)
        else:
          discard posix.kill(Pid(p.pid), SIGKILL)
    else:
      try: p.proc0.kill()
      except CatchableError, Defect: discard
    # Reap. `peekExitCode` is `waitpid(WNOHANG)`; the child was just SIGKILLed
    # so it is at most microseconds away, and the bounded spin is what keeps
    # this synchronous closer from becoming a blocking wait.
    var spins = 0
    while spins < 20000:
      var code = -1
      try:
        code = p.proc0.peekExitCode()
      except CatchableError, Defect:
        break
      if code >= 0:
        p.exitCode = code
        break
      inc spins
    p.reaped = true

  proc resolveExecutable*(name: string): string =
    ## §8.1.1's "the host resolves it against a declared set and its own PATH
    ## policy". `findExe` is the host's PATH policy: the process environment
    ## CodeTracer itself was started with, not one the plugin supplied.
    ##
    ## `followSymlinks = false`, AND THAT WAS MEASURED RATHER THAN CHOSEN.
    ## `findExe`'s default resolves the link, and on a multi-call binary that
    ## changes which program runs: on this workspace's nixpkgs coreutils,
    ## `findExe("printf")` returns `…/bin/coreutils`, whose `argv[0]` is then
    ## `coreutils` and which exits 1 having printed nothing, because a
    ## multi-call binary dispatches on its own name. The plugin declared
    ## `printf`; resolving the declaration to a different program is the
    ## opposite of what §8.1.1 hands the host resolution for.
    if not isBareExecutableName(name): return ""
    findExe(name, followSymlinks = false)

  proc setNonBlocking(fd: int) =
    when defined(posix):
      let flags = fcntl(cint(fd), F_GETFL, 0)
      if flags >= 0:
        discard fcntl(cint(fd), F_SETFL, flags or O_NONBLOCK)

  proc spawnInner(ctx: PluginContext; name: string; args: seq[string];
                  env: seq[(string, string)];
                  workingDir: string): Future[SpawnOutcome] {.async.} =
    when not defined(posix):
      return SpawnOutcome(status: ioUnsupported,
        message: "the plugin process SDK is POSIX-only in PLAT-8; this is " &
                 hostOS & ". See plugin_io.nim's stated limits.")
    else:
      let exe = resolveExecutable(name)
      if exe.len == 0:
        return SpawnOutcome(status: ioFailed,
          message: "plugin '" & ctx.state.id & "': '" & name &
                   "' is declared but is not on the host's PATH")
      if workingDir.len > 0 and not dirExists(workingDir):
        return SpawnOutcome(status: ioFailed,
          message: "working directory '" & workingDir & "' does not exist")

      # THE ENVIRONMENT IS THE PLUGIN'S, EXPLICITLY. `startProcess` inherits
      # the host's environment when `env` is nil, and the host's environment
      # holds whatever CodeTracer was started with — tokens included. A plugin
      # gets what it named and nothing else.
      var envTable = newStringTable(modeCaseSensitive)
      for (k, v) in env:
        envTable[k] = v

      var p: Process
      try:
        # NO `poEvalCommand` and NO `poUsePath`: `exe` is already absolute and
        # `args` reaches `execve` as argv. There is no command line, so there
        # is no shell and nothing to quote.
        #
        # `poDaemon` IS THE TEARDOWN, not a detachment. On nim's POSIX
        # `posix_spawn` path it is exactly `POSIX_SPAWN_SETPGROUP` with a
        # pgroup of `0` and nothing else — no `setsid`, no change to the three
        # pipes below, no controlling-terminal work — so the child becomes its
        # own process-group leader and `rawKill` can reach its descendants with
        # one `killpg`. See `rawKill` for what that is worth and for the guard
        # that keeps it from ever reaching CodeTracer's own group.
        p = startProcess(exe, workingDir = workingDir, args = args,
                         env = envTable, options = {poDaemon})
      except CatchableError as e:
        return SpawnOutcome(status: ioFailed,
          message: "spawning '" & name & "' failed: " & e.msg)

      let inH = int(p.inputHandle)
      let outH = int(p.outputHandle)
      let errH = int(p.errorHandle)
      setNonBlocking(inH)
      setNonBlocking(outH)
      setNonBlocking(errH)

      var res = PluginProcess(ctx: ctx, name: name, argv: args,
                              pid: p.processID, proc0: p, exitCode: -1)
      let rp = res
      res.handle = ctx.state.handles.registerHandle(hkProcess,
        name & " (pid " & $res.pid & ")", proc() = rawKill(rp))
      res.stdin = newStreamOverFile(ctx, pskProcessInput,
        newAsyncFile(AsyncFD(inH)), name & ":stdin")
      res.stdout = newStreamOverFile(ctx, pskProcessOutput,
        newAsyncFile(AsyncFD(outH)), name & ":stdout")
      res.stderr = newStreamOverFile(ctx, pskProcessError,
        newAsyncFile(AsyncFD(errH)), name & ":stderr")
      return SpawnOutcome(status: ioOk, process: res)

  proc spawnProcess*(ctx: PluginContext; name: string; args: seq[string] = @[];
                     env: seq[(string, string)] = @[];
                     workingDir = ""): Future[SpawnOutcome] =
    ## §8.1's Process row, and §8.1.1's first two rules.
    ##
    ## `name` is a NAME. `args` is a LIST. There is no overload taking a
    ## command line and there will not be one — that is the whole of "the
    ## injection class disappears rather than being filtered".
    ctx.checkBudget()
    let d = decide(grantsOf(ctx), ctx.state.id,
                   IoRequest(kind: irSpawnProcess, target: name))
    if not d.permitted:
      let f = newFuture[SpawnOutcome]("plugin_io.spawnProcess")
      f.complete(refusalOutcome[SpawnOutcome](d))
      return f
    spawnInner(ctx, name, args, env, workingDir)

  proc signalProcess*(p: PluginProcess; sig: PluginSignal): Future[ExitOutcome] =
    ## §8.1's "signals". Returns a future so the API has no synchronous form,
    ## and completes as soon as the signal is delivered — it does NOT wait for
    ## the child, because "I asked it to stop" and "it stopped" are different
    ## facts and `awaitExit` is the second one.
    p.ctx.checkBudget()
    let f = newFuture[ExitOutcome]("plugin_io.signalProcess")
    if p.reaped:
      f.complete(ExitOutcome(status: ioClosed,
        message: "the process has already been reaped"))
      return f
    when defined(posix):
      let n =
        case sig
        of psInterrupt: SIGINT
        of psTerminate: SIGTERM
        of psHangup: SIGHUP
        of psKill: SIGKILL
      if posix.kill(Pid(p.pid), n) != 0:
        f.complete(ExitOutcome(status: ioFailed,
          message: "kill(" & $p.pid & ", " & $sig & ") failed"))
      else:
        f.complete(ExitOutcome(status: ioOk, code: -1))
    else:
      try:
        if sig == psKill: p.proc0.kill() else: p.proc0.terminate()
        f.complete(ExitOutcome(status: ioOk, code: -1))
      except CatchableError as e:
        f.complete(ExitOutcome(status: ioFailed, message: e.msg))
    f

  proc awaitExitInner(p: PluginProcess;
                      pollMs: int): Future[ExitOutcome] {.async.} =
    ## §8.1's "exit status", asynchronously.
    ##
    ## A poll rather than a blocking `waitpid`: `waitForExit` is on
    ## `PluginDeniedSyncIo` and an SDK that called it on the plugin's behalf
    ## would break rule 1 for it. `sleepAsync` yields to the host's dispatcher
    ## between polls, so the front-end keeps running while a child takes its
    ## time. SIGCHLD-driven wakeups would be tighter and are not portable
    ## across the dispatchers `async_compat` selects between.
    if p.reaped:
      return ExitOutcome(status: ioOk, code: p.exitCode,
                         signalled: p.exitSignalled)
    while true:
      var code = -1
      try:
        code = p.proc0.peekExitCode()
      except CatchableError as e:
        return ExitOutcome(status: ioFailed, message: e.msg)
      if code >= 0:
        p.reaped = true
        # `exitStatusLikeShell` reports a signalled death as 128 + signal,
        # which is the shell's convention and the one a plugin author knows.
        p.exitSignalled = code > 128
        p.exitCode = code
        return ExitOutcome(status: ioOk, code: code,
                           signalled: p.exitSignalled)
      await sleepAsync(pollMs)

  proc awaitExit*(p: PluginProcess; pollMs = 2): Future[ExitOutcome] =
    p.ctx.checkBudget()
    awaitExitInner(p, pollMs)

  proc closeProcess*(p: PluginProcess) =
    ## Release the child and its three streams. What `host.deactivate` reaches
    ## through the handle table; a plugin may call it earlier.
    if p.isNil: return
    closeStream(p.stdin)
    closeStream(p.stdout)
    closeStream(p.stderr)
    if not p.handle.isNil:
      p.ctx.state.handles.close(p.handle)

  # -------------------------------------------------------------------------
  # Sockets
  # -------------------------------------------------------------------------

  proc connectUnixInner(ctx: PluginContext;
                        path: string): Future[SocketOutcome] {.async.} =
    var sock: AsyncSocket
    try:
      sock = newAsyncSocket(nativesockets.AF_UNIX, nativesockets.SOCK_STREAM,
                            nativesockets.IPPROTO_IP, buffered = false)
      await sock.connectUnix(path)
    except CatchableError as e:
      if not sock.isNil:
        try: sock.close()
        except CatchableError, Defect: discard
      return SocketOutcome(status: ioFailed,
        message: "connecting to unix socket '" & path & "': " & e.msg)
    return SocketOutcome(status: ioOk,
      stream: newStreamOverSocket(ctx, sock, "unix:" & path))

  proc connectUnixSocket*(ctx: PluginContext;
                          path: string): Future[SocketOutcome] =
    ctx.checkBudget()
    let d = decide(grantsOf(ctx), ctx.state.id,
                   IoRequest(kind: irConnectUnix, target: path))
    if not d.permitted:
      let f = newFuture[SocketOutcome]("plugin_io.connectUnixSocket")
      f.complete(refusalOutcome[SocketOutcome](d))
      return f
    connectUnixInner(ctx, path)

  proc resolvedAddressesOf(host: string; port: int): seq[string] =
    ## The host's own resolution, so the second capability pass has a real
    ## address to judge. `getAddrInfo` is `std/nativesockets`; a name that does
    ## not resolve yields an empty sequence and the caller reports that rather
    ## than connecting to something.
    var info: ptr AddrInfo
    try:
      info = getAddrInfo(host, Port(port), AF_UNSPEC)
    except CatchableError, Defect:
      return @[]
    var it = info
    while it != nil:
      try:
        result.add getAddrString(it.ai_addr)
      except CatchableError, Defect:
        discard
      it = it.ai_next
    freeAddrInfo(info)

  proc connectTcpInner(ctx: PluginContext; host: string; port: int;
                       tls: bool): Future[SocketOutcome] {.async.} =
    # THE SECOND CAPABILITY PASS. The first was on the literal the plugin
    # wrote; this one is on the address the kernel would be handed, so a name
    # that resolves off the machine cannot be reached with `socket:local`.
    # It runs BEFORE the socket exists, so a refusal leaks nothing.
    let addrs = resolvedAddressesOf(host, port)
    if addrs.len == 0:
      return SocketOutcome(status: ioFailed,
        message: "plugin '" & ctx.state.id & "': '" & host &
                 "' did not resolve to any address")
    for a in addrs:
      let d2 = decideResolvedAddress(grantsOf(ctx), ctx.state.id, host, a, port)
      if not d2.permitted:
        return SocketOutcome(status: ioRefused, message: d2.reason)

    if tls:
      when defined(ssl):
        discard
      else:
        return SocketOutcome(status: ioUnsupported,
          message: "TLS needs a build with an SSL backend (-d:ssl); this " &
                   "binary has none, and a plaintext fallback would be a " &
                   "downgrade the plugin did not ask for")

    var sock: AsyncSocket
    try:
      sock = newAsyncSocket(buffered = false)
      when defined(ssl):
        if tls:
          let sslCtx = std_net.newContext(verifyMode = std_net.CVerifyPeer)
          sslCtx.wrapSocket(sock)
      await sock.connect(host, Port(port))
    except CatchableError as e:
      if not sock.isNil:
        try: sock.close()
        except CatchableError, Defect: discard
      return SocketOutcome(status: ioFailed,
        message: "connecting to " & host & ":" & $port & ": " & e.msg)
    return SocketOutcome(status: ioOk,
      stream: newStreamOverSocket(ctx, sock,
        (if tls: "tls:" else: "tcp:") & host & ":" & $port))

  proc connectTcp*(ctx: PluginContext; host: string; port: int;
                   tls = false): Future[SocketOutcome] =
    ## §8.1's Socket row: TCP and TLS, connect.
    ##
    ## The capability decision is taken TWICE — once on the literal here, once
    ## on the resolved address inside — and the TLS flag changes neither. A
    ## TLS connection is never more permitted than a plaintext one to the same
    ## host, which is the property that stops `tls = true` from being a way
    ## around a declaration.
    ctx.checkBudget()
    let d = decide(grantsOf(ctx), ctx.state.id,
                   IoRequest(kind: irConnectTcp, target: host, port: port))
    if not d.permitted:
      let f = newFuture[SocketOutcome]("plugin_io.connectTcp")
      f.complete(refusalOutcome[SocketOutcome](d))
      return f
    connectTcpInner(ctx, host, port, tls)

  proc rawCloseListener(l: PluginListener) =
    if not l.socket.isNil:
      try: l.socket.close()
      except CatchableError, Defect: discard
      l.socket = nil
    if l.unixPath.len > 0:
      try: removeFile(l.unixPath)
      except CatchableError, Defect: discard
      l.unixPath = ""

  proc listenUnixInner(ctx: PluginContext;
                       path: string): Future[ListenOutcome] {.async.} =
    var sock: AsyncSocket
    try:
      if fileExists(path): removeFile(path)
      sock = newAsyncSocket(nativesockets.AF_UNIX, nativesockets.SOCK_STREAM,
                            nativesockets.IPPROTO_IP, buffered = false)
      sock.bindUnix(path)
      sock.listen()
    except CatchableError as e:
      if not sock.isNil:
        try: sock.close()
        except CatchableError, Defect: discard
      return ListenOutcome(status: ioFailed,
        message: "listening on unix socket '" & path & "': " & e.msg)
    var l = PluginListener(ctx: ctx, socket: sock, unixPath: path)
    let ll = l
    l.handle = ctx.state.handles.registerHandle(hkListener, "unix:" & path,
      proc() = rawCloseListener(ll))
    return ListenOutcome(status: ioOk, listener: l)

  proc listenUnixSocket*(ctx: PluginContext;
                         path: string): Future[ListenOutcome] =
    ctx.checkBudget()
    let d = decide(grantsOf(ctx), ctx.state.id,
                   IoRequest(kind: irListenUnix, target: path))
    if not d.permitted:
      let f = newFuture[ListenOutcome]("plugin_io.listenUnixSocket")
      f.complete(refusalOutcome[ListenOutcome](d))
      return f
    listenUnixInner(ctx, path)

  proc listenTcpInner(ctx: PluginContext; host: string;
                      port: int): Future[ListenOutcome] {.async.} =
    var sock: AsyncSocket
    try:
      sock = newAsyncSocket(buffered = false)
      sock.setSockOpt(OptReuseAddr, true)
      sock.bindAddr(Port(port), host)
      sock.listen()
    except CatchableError as e:
      if not sock.isNil:
        try: sock.close()
        except CatchableError, Defect: discard
      return ListenOutcome(status: ioFailed,
        message: "listening on " & host & ":" & $port & ": " & e.msg)
    var l = PluginListener(ctx: ctx, socket: sock)
    let ll = l
    l.handle = ctx.state.handles.registerHandle(hkListener, "tcp:" & host & ":" & $port,
      proc() = rawCloseListener(ll))
    return ListenOutcome(status: ioOk, listener: l)

  proc listenTcp*(ctx: PluginContext; host: string;
                  port: int): Future[ListenOutcome] =
    ## Loopback only, and the refusal for anything else is in
    ## `capabilities.decide`: `socket:remote` is granted for OUTBOUND
    ## connections, and a listener beyond loopback publishes a service from
    ## inside the debugger.
    ctx.checkBudget()
    let d = decide(grantsOf(ctx), ctx.state.id,
                   IoRequest(kind: irListenTcp, target: host, port: port))
    if not d.permitted:
      let f = newFuture[ListenOutcome]("plugin_io.listenTcp")
      f.complete(refusalOutcome[ListenOutcome](d))
      return f
    listenTcpInner(ctx, host, port)

  proc boundPort*(l: PluginListener): int =
    ## What the kernel actually chose when the plugin asked for port 0.
    if l.socket.isNil: return 0
    try: int(getLocalAddr(l.socket.getFd(), AF_INET)[1])
    except CatchableError, Defect: 0

  proc acceptInner(l: PluginListener): Future[SocketOutcome] {.async.} =
    if l.socket.isNil:
      return SocketOutcome(status: ioClosed,
        message: "the listener was closed or reclaimed")
    var peer: AsyncSocket
    try:
      peer = await l.socket.accept()
    except CatchableError as e:
      return SocketOutcome(status: ioFailed, message: e.msg)
    return SocketOutcome(status: ioOk,
      stream: newStreamOverSocket(l.ctx, peer, "accepted"))

  proc acceptFrom*(l: PluginListener): Future[SocketOutcome] =
    l.ctx.checkBudget()
    acceptInner(l)

  proc closeListener*(l: PluginListener) =
    if l.isNil: return
    if not l.handle.isNil:
      l.ctx.state.handles.close(l.handle)

  # -------------------------------------------------------------------------
  # Files — `fs:read` / `fs:write`, and the rule that neither is a way around
  # `trace`
  # -------------------------------------------------------------------------

  proc canonicalPath*(path: string): string =
    ## THE ONE CANONICALISER, used for the SUBJECT of every filesystem decision
    ## and for the ROOTS it is measured against.
    ##
    ## ## IT IS NOT THE SAME FUNCTION ON TWO PLATFORMS, AND THAT IS A LIMIT
    ##
    ## `os.expandFilename` is `realpath(3)` on POSIX — every symlink resolved —
    ## and `GetFullPathNameW` on Windows, which normalises `.` and `..` and
    ## **does not resolve symlinks or junctions at all**. Its doc comment says
    ## "Follows symlinks", which is true of one of its two `when` arms.
    ##
    ## So the containment below is a real containment on POSIX and a no-op on
    ## Windows, and this repair is POSIX-only in BOTH its halves — not just in
    ## the `O_NOFOLLOW` half, which is how it was first written up. The process
    ## arm is already POSIX-only and the real-stack suite is Linux, so this is
    ## the same bound rather than a new one. It is said here because the
    ## alternative is a reader taking the paragraph below for a cross-platform
    ## guarantee.
    ##
    ## ## WHY THIS REPLACED `absolutePath` + `normalizedPath`
    ##
    ## Neither of those resolves a symlink, and `pathIsUnder` is textual. So on
    ## 2026-09-09 a verification pass put an ordinary symlink inside a declared
    ## readable root and measured this:
    ##
    ##     direct read of the recording:               ioRefused
    ##     read via symlink into the recording:        ioOk  RECORDED-SECRETS
    ##     read via symlink outside the declared root: ioOk  OUTSIDE-THE-ROOT
    ##
    ## Both the `trace` gate and the `fs:read` root were aliased past by a link
    ## any user can make, which falsifies §8.1.4's bullet calling the first of
    ## those "the part that could have been silently absent, and the part that
    ## matters".
    ##
    ## ## A PATH THAT DOES NOT EXIST YET STILL HAS TO CANONICALISE
    ##
    ## `writePath` creates files, so the leaf is often absent and `realpath` on
    ## the whole path fails. Resolving the PARENT and re-appending the leaf is
    ## correct for exactly the reason the whole-path form is: every symlink in
    ## the path except a leaf that does not exist has been followed, and a leaf
    ## that does not exist cannot be a symlink. If the parent does not resolve
    ## either, the lexical form is returned and the open fails on its own — a
    ## nonexistent directory cannot alias into a declared root.
    let absolute =
      try: absolutePath(path)
      except CatchableError, Defect: path
    try:
      return expandFilename(absolute)
    except CatchableError, Defect:
      discard
    let parent = absolute.parentDir()
    let leaf = absolute.extractFilename()
    if parent.len > 0 and leaf.len > 0:
      try:
        return expandFilename(parent) / leaf
      except CatchableError, Defect:
        discard
    try: normalizedPath(absolute)
    except CatchableError, Defect: path

  proc normalisedFor(path: string): string =
    canonicalPath(path)

  proc canonicalRootsOf(io: PluginIoContext): PluginIoContext =
    ## THE ROOTS GO THROUGH THE SAME CANONICALISER AS THE SUBJECT, which is the
    ## half of the repair that is easy to skip. `pathIsUnder` compares two
    ## strings; canonicalising one side and not the other makes a declared root
    ## that is itself reached through a symlink — `/tmp` on macOS, a
    ## bind-mounted trace directory, a home directory under `/home/x` that is
    ## really `/data/home/x` — stop containing its own children.
    ##
    ## It returns a NEW context rather than mutating, so there is still exactly
    ## one containment predicate (`pathIsRecorded`) and it still takes already-
    ## canonical inputs. Verification-Harness-Traps §14: the rule and its
    ## inputs both go through one function.
    if io.isNil: return io
    var roots: seq[string] = @[]
    for r in io.traceRoots:
      roots.add canonicalPath(r)
    PluginIoContext(traceRoots: roots)

  when defined(posix):
    let O_NOFOLLOW_CT {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
      ## `std/posix` does not declare `O_NOFOLLOW` on any platform — checked
      ## across `posix_linux_amd64_consts`, `posix_other_consts` and
      ## `posix_freertos_consts`, which have `O_CLOEXEC` and not this. Imported
      ## from the header rather than written as a number, because the value
      ## differs between Linux (0o400000), the BSDs (0x100) and macOS.

  proc canonicalGrantsOf(ctx: PluginContext): GrantSet =
    ## The declared fs roots, through the SAME canonicaliser as the subject.
    ##
    ## THIS WAS FOUND BY ITS OWN NEW ARM, which is the argument for writing the
    ## positive twin. Canonicalising `canonicalRootsOf`'s trace roots and
    ## stopping there is a HALF repair: `declaresReadPath` compares the
    ## resolved subject against the manifest's unresolved `paths.read`, so a
    ## plugin whose declared root is itself reached through a symlink — `/tmp`
    ## on macOS, a bind-mounted directory, a home under `/home/x` that is
    ## really `/data/home/x` — stops being able to read its own files. The
    ## refusal is the safe direction, which is exactly why it would have
    ## shipped: nothing about it looks like a security defect from the outside.
    result = grantsOf(ctx)
    var rs: seq[string] = @[]
    for r in result.readPaths: rs.add canonicalPath(r)
    result.readPaths = rs
    var ws: seq[string] = @[]
    for w in result.writePaths: ws.add canonicalPath(w)
    result.writePaths = ws

  proc openVerified(path: string; flags: cint;
                    fd: var cint; why: var string): bool =
    ## Open a path the policy has ALREADY approved, and prove the descriptor
    ## refers to the object the policy judged.
    ##
    ## ## THE TOCTOU SEAM, NAMED RATHER THAN HOPED AWAY
    ##
    ## `canonicalPath` resolves and `decide` judges; the open happens after
    ## both. An attacker who can write inside the declared root can swap a
    ## component for a symlink in that window, so "we resolved it" is a claim
    ## about the past. Two mechanisms close it, and each covers what the other
    ## cannot:
    ##
    ##   * `O_NOFOLLOW` — the kernel refuses if the FINAL component is a
    ##     symlink at the moment of the open. The path handed here has no
    ##     symlinks in it by construction, so a leaf that has become one is
    ##     precisely the swap, and `ELOOP` is the refusal.
    ##   * an `fstat` of the descriptor against an `lstat` of the path,
    ##     compared on `(st_dev, st_ino)` — which catches a swap that RACES
    ##     the check, on any component, where `O_NOFOLLOW` says nothing.
    ##
    ## **CORRECTED 2026-09-12, BY EXPERIMENT RATHER THAN FROM A MAN PAGE.**
    ## The second bullet used to read "catches a swap of an INTERMEDIATE
    ## directory", and that is an overclaim. Build `root/a/b`; replace the
    ## DIRECTORY `a` with a symlink to an outside directory that also holds a
    ## `b`; then run this exact open/`fstat`/`lstat` sequence. The open
    ## SUCCEEDS — `O_NOFOLLOW` constrains the final component and nothing else
    ## — the two stats AGREE, because `lstat` follows intermediate components
    ## exactly as `open` does and only declines to follow the leaf, and the
    ## descriptor holds the OUTSIDE file's bytes. The control in the same run
    ## confirms the instrument rather than the claim: a symlink in the LEAF
    ## position is refused with `ELOOP`.
    ##
    ## So an intermediate swap that COMPLETES BEFORE the open is followed
    ## consistently by both calls and is not caught. Only a swap that lands
    ## BETWEEN the `open` and the `lstat` makes the two disagree, and that is
    ## refused: the check FAILS CLOSED, so the attacker's win condition is
    ## "make two stats of the same name agree while naming different objects",
    ## which needs one inode with two names — a HARD LINK.
    ##
    ## **WHAT CLOSING THE INTERMEDIATE CASE WOULD TAKE, NAMED AND NOT
    ## IMPLEMENTED.** Resolve the path a component at a time: `openat` each
    ## directory with `O_NOFOLLOW` from a descriptor for the one above it, or
    ## on Linux one `openat2` with `RESOLVE_BENEATH`. Both make containment a
    ## property of the descriptors the kernel handed back rather than of a
    ## string, which is the only formulation a swap cannot get between. It is
    ## recorded rather than written because it is one platform's answer
    ## (`openat2` is Linux 5.6+) to a problem the other two still have, and
    ## because the residual it closes needs write access inside the declared
    ## root, which is the user's own. PLAT-11's `readSourceFile` carries the
    ## same two sentences; they are the same seam in a second place.
    ##
    ## **The hard-link residual is real and is bounded elsewhere.** A hard link
    ## from inside a declared root to a recording defeats every path-based
    ## policy, this one included, and no amount of resolving fixes it because
    ## there is nothing to resolve. Making one needs `link(2)`, which the SDK
    ## does not offer — so it needs a spawned program, which needs `process`,
    ## which now requires the trace-egress acknowledgement on its own
    ## (`capabilities.needsTraceEgressGrant`). It is a residual of the model
    ## rather than a way past the disclosure.
    ## **THE RE-VERIFICATION IS POSIX-ONLY**, and that is stated rather than
    ## silently absent. `canonicalPath` — the primary F2 repair — is
    ## `expandFilename`, which resolves symlinks on every target nim supports,
    ## so the containment decision is taken on a resolved path everywhere. What
    ## the non-POSIX arm below lacks is the *second* half: `O_NOFOLLOW` and the
    ## `(dev, ino)` comparison. The Windows equivalent is
    ## `FILE_FLAG_OPEN_REPARSE_POINT` with `GetFileInformationByHandle`'s file
    ## index, and it is not written — the same bound the process arm already
    ## carries.
    when not defined(posix):
      why = "the resolve/open re-verification is POSIX-only in PLAT-8; this " &
            "is " & hostOS & ". See openVerified's header."
      fd = -1
      return false
    else:
      var st1, st2: Stat
      fd = posix.open(path.cstring, flags or O_NOFOLLOW_CT or O_CLOEXEC,
                      0o666.Mode)
      if fd < 0:
        why = "opening '" & path & "' failed (" & $strerror(errno) & ")"
        return false
      if fstat(fd, st1) != 0:
        discard posix.close(fd)
        fd = -1
        why = "the opened descriptor for '" & path & "' could not be stat'd"
        return false
      if lstat(path.cstring, st2) != 0:
        discard posix.close(fd)
        fd = -1
        why = "'" & path & "' disappeared between the decision and the open"
        return false
      if st1.st_dev != st2.st_dev or st1.st_ino != st2.st_ino:
        discard posix.close(fd)
        fd = -1
        why = "'" & path & "' names a different object than the one the " &
              "capability decision was taken on — it was replaced between " &
              "the check and the open, and the request is refused rather " &
              "than retried"
        return false
      return true

  proc readPathInner(path: string): Future[ReadOutcome] {.async.} =
    var fd: cint = -1
    var why = ""
    if not openVerified(path, O_RDONLY, fd, why):
      # A verification failure is a REFUSAL and not a failure: the difference
      # is whether the caller may retry, and here they may not.
      if fd < 0 and "different object" in why:
        return ReadOutcome(status: ioRefused, message: why)
      return ReadOutcome(status: ioFailed, message: why)
    var f: AsyncFile
    try:
      f = newAsyncFile(AsyncFD(fd))
    except CatchableError as e:
      discard posix.close(fd)
      return ReadOutcome(status: ioFailed, message: e.msg)
    var acc = ""
    try:
      while true:
        let chunk = await f.read(DefaultReadChunk)
        if chunk.len == 0: break
        acc.add chunk
    except CatchableError as e:
      f.close()
      return ReadOutcome(status: ioFailed, message: e.msg)
    f.close()
    return ReadOutcome(status: ioOk, data: acc)

  proc readPath*(ctx: PluginContext; io: PluginIoContext;
                 path: string): Future[ReadOutcome] =
    ## `fs:read`, over declared paths only, asynchronously.
    ##
    ## AND `trace` IS CHECKED FIRST. A recording under a declared readable
    ## directory is still recorded program data, and §9 is explicit about what
    ## that contains. `fs:read` is not a way around `trace`.
    ctx.checkBudget()
    let full = normalisedFor(path)
    let f = newFuture[ReadOutcome]("plugin_io.readPath")
    if pathIsRecorded(canonicalRootsOf(io), full):
      let dt = decide(grantsOf(ctx), ctx.state.id,
                      IoRequest(kind: irReadTrace, target: full))
      if not dt.permitted:
        f.complete(ReadOutcome(status: ioRefused, message: dt.reason &
          " (the path is inside a recording, so 'fs:read' does not reach it)"))
        return f
    let d = decide(canonicalGrantsOf(ctx), ctx.state.id,
                   IoRequest(kind: irReadPath, target: full))
    if not d.permitted:
      f.complete(refusalOutcome[ReadOutcome](d))
      return f
    readPathInner(full)

  proc writePathInner(path, data: string): Future[WriteOutcome] {.async.} =
    var fd: cint = -1
    var why = ""
    if not openVerified(path, O_WRONLY or O_CREAT or O_TRUNC, fd, why):
      if fd < 0 and "different object" in why:
        return WriteOutcome(status: ioRefused, message: why)
      return WriteOutcome(status: ioFailed, message: why)
    var f: AsyncFile
    try:
      f = newAsyncFile(AsyncFD(fd))
    except CatchableError as e:
      discard posix.close(fd)
      return WriteOutcome(status: ioFailed, message: e.msg)
    try:
      await f.write(data)
    except CatchableError as e:
      f.close()
      return WriteOutcome(status: ioFailed, message: e.msg)
    f.close()
    return WriteOutcome(status: ioOk, written: data.len)

  proc writePath*(ctx: PluginContext; io: PluginIoContext; path,
                  data: string): Future[WriteOutcome] =
    ## `fs:write`, over declared paths only, asynchronously.
    ctx.checkBudget()
    let full = normalisedFor(path)
    let f = newFuture[WriteOutcome]("plugin_io.writePath")
    if pathIsRecorded(canonicalRootsOf(io), full):
      f.complete(WriteOutcome(status: ioRefused,
        message: "plugin '" & ctx.state.id & "': writing '" & full &
          "' refused — it is inside a recording, and a plugin does not " &
          "modify recorded data under any grant"))
      return f
    let d = decide(canonicalGrantsOf(ctx), ctx.state.id,
                   IoRequest(kind: irWritePath, target: full))
    if not d.permitted:
      f.complete(refusalOutcome[WriteOutcome](d))
      return f
    writePathInner(full, data)

  # -------------------------------------------------------------------------
  # Accounting, from the plugin's side
  # -------------------------------------------------------------------------

  proc handleReport*(ctx: PluginContext): string =
    ## §8.1.1's "a misbehaving one is nameable", from the context a plugin
    ## already holds. The host reads the same table.
    ctx.state.handles.describe()
