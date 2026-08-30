## A facade instantiation backed by an out-of-process endpoint.
##
## ## What this is for
##
## NS1's `test_a_remote_instantiation_needs_no_signature_change`:
##
##   "A stub instantiation backed by an out-of-process endpoint satisfies every
##    facade module without altering a single signature — the cheap check that
##    the container path ([WD1]) is an implementation rather than a second
##    architecture."
##
## That test is only cheap if the check is mechanical, so this module is
## deliberately *complete* rather than *representative*: it satisfies every
## field of all seven facades. If a facade ever grows an operation whose
## signature only makes sense in-process — one returning a `File`, a
## `Process`, a pointer, or an iterator — this module stops compiling, and it
## stops compiling on the day the operation is added rather than on the day
## `ct host` is refactored. That is the entire value.
##
## ## What it is NOT
##
## Not the container instantiation, and not a mock standing in for one. There
## is no HTTP client here and no wire format. `RemoteTransport` is a single
## `proc(method, payload) -> future[payload]` that the caller supplies: the
## point being proved is that *every* facade operation can be expressed as one
## request and one response over such a seam, and no real transport is needed
## to prove it. Noir-Studio.md §3.1a plans the real one, and
## Architecture/UI-Bundle-And-Endpoints.md owns the wire format.
##
## ## Why the encoding is deliberately trivial
##
## Requests and responses are `string`. A JSON codec would make this module
## about serialisation, which is not what it exists to demonstrate, and would
## have to be rewritten when the real wire format lands. The claim under test
## is about *shapes* — argument in, outcome out, latency expressible — and a
## trivial encoding tests exactly that claim and nothing else.

import ../platform/outcome
import ../platform/capabilities
import ../platform/fs
import ../platform/process
import ../platform/vcs
import ../platform/settings
import ../platform/clipboard
import ../platform/download
import ../platform/shell
import ../platform/platform

type
  RemoteRequest* = object
    verb*: string
      ## The facade operation, e.g. `"fs.readText"`.
    args*: seq[string]

  RemoteResponse* = object
    ok*: bool
    payload*: string
    errorKind*: PlatformErrorKind
    errorMessage*: string

  RemoteTransport* = proc(request: RemoteRequest
                         ): PlatformFuture[RemoteResponse]
    ## One hop. Everything in this module is one call to this.

proc remoteOk*(payload: string): RemoteResponse =
  RemoteResponse(ok: true, payload: payload)

proc remoteErr*(kind: PlatformErrorKind; message: string): RemoteResponse =
  RemoteResponse(ok: false, errorKind: kind, errorMessage: message)

# ---------------------------------------------------------------------------
# The one adapter every operation goes through
# ---------------------------------------------------------------------------

proc callRemote[T](transport: RemoteTransport; verb: string; args: seq[string];
                   decode: proc(payload: string): T
                  ): PlatformFuture[PlatformOutcome[T]] =
  ## Send, await, decode. The `when defined(js)` split is the *transport's*
  ## business showing through, not the facade's: the signature this returns is
  ## identical on both backends, which is the property being demonstrated.
  let response = transport(RemoteRequest(verb: verb, args: args))
  when defined(js):
    # A transport that answered synchronously must stay synchronously
    # observable. Chaining `then` unconditionally would push the value onto
    # V8's microtask queue, which no headless caller can drain — so a suite
    # asserting on a facade result would assert nothing. `isSyncResolved` is
    # nim-everywhere's marker for exactly this case; see the note in
    # platform/outcome.nim's `resolved`.
    if isSyncResolved(response):
      let r = getSyncValue[RemoteResponse](response)
      result =
        if r.ok: newCompletedFuture(succeeded(decode(r.payload)))
        else: newCompletedFuture(failed[T](r.errorKind, r.errorMessage))
    else:
      result = newPromise(proc(resolve: proc(v: PlatformOutcome[T])) =
        discard response.then(proc(r: RemoteResponse) =
          if r.ok: resolve(succeeded(decode(r.payload)))
          else: resolve(failed[T](r.errorKind, r.errorMessage))))
  else:
    let promise = newFuture[PlatformOutcome[T]]("remote." & verb)
    # `addCallback` wants `proc() {.closure, gcsafe.}`, and the closure captures
    # the caller's `decode`, which carries no such annotation. The cast is the
    # standard way to bridge that and is safe here for the same reason it is in
    # every other single-threaded callback in this tree: nothing captured
    # crosses a thread.
    response.addCallback(proc() {.gcsafe.} =
      {.cast(gcsafe).}:
        if response.failed:
          promise.complete(failed[T](
            pkTransport, verb & ": the endpoint did not answer",
            response.readError.msg))
        else:
          let r = response.read()
          if r.ok: promise.complete(succeeded(decode(r.payload)))
          else: promise.complete(failed[T](r.errorKind, r.errorMessage)))
    result = promise

proc decodeString(payload: string): string = payload
proc decodeNothing(payload: string): Nothing = nothing

proc decodeBool(payload: string): bool = payload == "true"

proc decodeInt(payload: string): int =
  result = 0
  var negative = false
  for i, c in payload:
    if i == 0 and c == '-': negative = true
    elif c in {'0' .. '9'}: result = result * 10 + int(c) - int('0')
  if negative: result = -result

proc splitRecords(payload: string; sep: char): seq[string] =
  ## Split on `sep`, keeping every field — INCLUDING a trailing empty one.
  ##
  ## An earlier version dropped the final field when it was empty, on the
  ## reasoning that a trailing separator is punctuation. It is not: a record
  ## whose last field is legitimately empty (a process that wrote nothing to
  ## stderr, a file change with no previous path) then arrived one field short,
  ## the arity check rejected it, and the decoder returned a zero value. The
  ## test that caught it asserted on captured stdout and saw "".
  result = @[]
  var current = ""
  for c in payload:
    if c == sep:
      result.add current
      current = ""
    else:
      current.add c
  result.add current

proc decodeBytes(payload: string): seq[byte] =
  result = newSeq[byte](payload.len)
  for i, c in payload: result[i] = byte(c)

proc decodeStringSeq(payload: string): seq[string] =
  if payload.len == 0: @[] else: splitRecords(payload, '\x1f')

proc decodeFsStat(payload: string): FsStat =
  let f = splitRecords(payload, '\x1f')
  result = FsStat()
  if f.len >= 4:
    result.kind = FsEntryKind(decodeInt(f[0]))
    result.size = int64(decodeInt(f[1]))
    result.modifiedMs = int64(decodeInt(f[2]))
    result.readOnly = f[3] == "true"

proc decodeDirEntries(payload: string): seq[FsDirEntry] =
  result = @[]
  if payload.len == 0: return
  for record in splitRecords(payload, '\x1e'):
    if record.len == 0: continue
    let f = splitRecords(record, '\x1f')
    if f.len >= 2:
      result.add FsDirEntry(name: f[0], kind: FsEntryKind(decodeInt(f[1])))

proc decodeWatchHandle(payload: string): FsWatchHandle = FsWatchHandle(payload)
proc decodeProcessHandle(payload: string): ProcessHandle = ProcessHandle(payload)

proc decodeRunResult(payload: string): ProcessRunResult =
  let f = splitRecords(payload, '\x1f')
  result = ProcessRunResult()
  if f.len >= 4:
    result.exit = ProcessExit(exitCode: decodeInt(f[0]), signalled: f[1] == "true")
    result.stdout = f[2]
    result.stderr = f[3]

proc decodeVcsStatus(payload: string): VcsStatus =
  let sections = splitRecords(payload, '\x1d')
  result = VcsStatus()
  if sections.len >= 1:
    let head = splitRecords(sections[0], '\x1f')
    if head.len >= 5:
      result.branch = head[0]
      result.upstream = head[1]
      result.ahead = decodeInt(head[2])
      result.behind = decodeInt(head[3])
      result.detached = head[4] == "true"
  if sections.len >= 2 and sections[1].len > 0:
    for record in splitRecords(sections[1], '\x1e'):
      if record.len == 0: continue
      let f = splitRecords(record, '\x1f')
      if f.len >= 4:
        result.changes.add VcsFileChange(
          path: f[0], previousPath: f[1],
          indexStatus: VcsFileStatus(decodeInt(f[2])),
          workingTreeStatus: VcsFileStatus(decodeInt(f[3])))

proc decodeCommits(payload: string): seq[VcsCommit] =
  result = @[]
  if payload.len == 0: return
  for record in splitRecords(payload, '\x1e'):
    if record.len == 0: continue
    let f = splitRecords(record, '\x1f')
    if f.len >= 7:
      result.add VcsCommit(
        id: f[0], shortId: f[1],
        parents: if f[2].len > 0: splitRecords(f[2], ',') else: @[],
        authorName: f[3], authorEmail: f[4],
        authoredAtMs: int64(decodeInt(f[5])), subject: f[6],
        body: if f.len > 7: f[7] else: "")

proc decodeCommit(payload: string): VcsCommit =
  let all = decodeCommits(payload)
  if all.len > 0: all[0] else: VcsCommit()

proc decodeWindowState(payload: string): WindowState =
  let f = splitRecords(payload, '\x1f')
  result = WindowState()
  if f.len >= 4:
    result.maximized = f[0] == "true"
    result.minimized = f[1] == "true"
    result.fullscreen = f[2] == "true"
    result.focused = f[3] == "true"

proc encodeBool(value: bool): string = (if value: "true" else: "false")

proc encodeInt(value: int): string =
  if value == 0: return "0"
  var n = value
  let negative = n < 0
  if negative: n = -n
  var digits = ""
  while n > 0:
    digits = char(int('0') + (n mod 10)) & digits
    n = n div 10
  if negative: "-" & digits else: digits

proc encodeBytes(content: seq[byte]): string =
  result = newString(content.len)
  for i, b in content: result[i] = char(b)

proc joinRecords(values: seq[string]; sep: char): string =
  for i, value in values:
    if i > 0: result.add sep
    result.add value

# ---------------------------------------------------------------------------
# The instantiation
# ---------------------------------------------------------------------------

proc newRemoteStubPlatform*(transport: RemoteTransport;
                            profile = containerProfile): Platform =
  ## Every facade field, satisfied by one round trip. No signature is altered
  ## and no operation is left refusing — which is the assertion.
  result = newPlatform(profile)

  # -- filesystem ---------------------------------------------------------
  result.fs.readText = proc(path: string): auto =
    callRemote[string](transport, "fs.readText", @[path], decodeString)
  result.fs.readBytes = proc(path: string): auto =
    callRemote[seq[byte]](transport, "fs.readBytes", @[path], decodeBytes)
  result.fs.writeText = proc(path, content: string): auto =
    callRemote[Nothing](transport, "fs.writeText", @[path, content], decodeNothing)
  result.fs.writeBytes = proc(path: string; content: seq[byte]): auto =
    callRemote[Nothing](transport, "fs.writeBytes",
                        @[path, encodeBytes(content)], decodeNothing)
  result.fs.appendText = proc(path, content: string): auto =
    callRemote[Nothing](transport, "fs.appendText", @[path, content], decodeNothing)
  result.fs.stat = proc(path: string): auto =
    callRemote[FsStat](transport, "fs.stat", @[path], decodeFsStat)
  result.fs.listDir = proc(path: string): auto =
    callRemote[seq[FsDirEntry]](transport, "fs.listDir", @[path], decodeDirEntries)
  result.fs.createDir = proc(path: string): auto =
    callRemote[Nothing](transport, "fs.createDir", @[path], decodeNothing)
  result.fs.remove = proc(path: string; recursive: bool): auto =
    callRemote[Nothing](transport, "fs.remove",
                        @[path, encodeBool(recursive)], decodeNothing)
  result.fs.copy = proc(source, destination: string): auto =
    callRemote[Nothing](transport, "fs.copy", @[source, destination], decodeNothing)
  result.fs.move = proc(source, destination: string): auto =
    callRemote[Nothing](transport, "fs.move", @[source, destination], decodeNothing)
  result.fs.realPath = proc(path: string): auto =
    callRemote[string](transport, "fs.realPath", @[path], decodeString)
  result.fs.makeTempDir = proc(prefix: string): auto =
    callRemote[string](transport, "fs.makeTempDir", @[prefix], decodeString)
  result.fs.watch = proc(path: string; recursive: bool;
                         onEvent: proc(event: FsWatchEvent)): auto =
    # The callback stays on this side of the wire; the endpoint streams events
    # against the returned handle. That the SIGNATURE accommodates this without
    # change is the point — a watch that had returned an OS handle could not.
    callRemote[FsWatchHandle](transport, "fs.watch",
                              @[path, encodeBool(recursive)], decodeWatchHandle)
  result.fs.unwatch = proc(handle: FsWatchHandle): auto =
    callRemote[Nothing](transport, "fs.unwatch", @[string(handle)], decodeNothing)

  # -- process ------------------------------------------------------------
  proc encodeSpec(spec: ProcessSpec): seq[string] =
    var envPairsEncoded: seq[string] = @[]
    for (key, value) in spec.env:
      envPairsEncoded.add key & "=" & value
    @[spec.command, joinRecords(spec.args, '\x1f'), spec.workingDir,
      joinRecords(envPairsEncoded, '\x1f'), encodeBool(spec.clearEnv),
      spec.stdinText, encodeInt(spec.timeoutMs)]

  result.process.run = proc(spec: ProcessSpec): auto =
    callRemote[ProcessRunResult](transport, "process.run", encodeSpec(spec),
                                 decodeRunResult)
  result.process.start = proc(spec: ProcessSpec;
                              onOutput: proc(chunk: ProcessOutputChunk);
                              onExit: proc(exit: ProcessExit)): auto =
    callRemote[ProcessHandle](transport, "process.start", encodeSpec(spec),
                              decodeProcessHandle)
  result.process.signal = proc(handle: ProcessHandle; signal: ProcessSignal): auto =
    callRemote[Nothing](transport, "process.signal",
                        @[string(handle), encodeInt(ord(signal))], decodeNothing)
  result.process.writeStdin = proc(handle: ProcessHandle; text: string): auto =
    callRemote[Nothing](transport, "process.writeStdin",
                        @[string(handle), text], decodeNothing)
  result.process.closeStdin = proc(handle: ProcessHandle): auto =
    callRemote[Nothing](transport, "process.closeStdin",
                        @[string(handle)], decodeNothing)
  result.process.isRunning = proc(handle: ProcessHandle): auto =
    callRemote[bool](transport, "process.isRunning", @[string(handle)], decodeBool)
  result.process.which = proc(program: string): auto =
    callRemote[string](transport, "process.which", @[program], decodeString)

  # -- vcs ----------------------------------------------------------------
  result.vcs.isRepository = proc(path: string): auto =
    callRemote[bool](transport, "vcs.isRepository", @[path], decodeBool)
  result.vcs.repositoryRoot = proc(path: string): auto =
    callRemote[string](transport, "vcs.repositoryRoot", @[path], decodeString)
  result.vcs.status = proc(repository: string): auto =
    callRemote[VcsStatus](transport, "vcs.status", @[repository], decodeVcsStatus)
  result.vcs.log = proc(repository: string; maxCount: int; path: string): auto =
    callRemote[seq[VcsCommit]](transport, "vcs.log",
                               @[repository, encodeInt(maxCount), path],
                               decodeCommits)
  result.vcs.readBlob = proc(repository, path: string; source: VcsBlobSource): auto =
    callRemote[string](transport, "vcs.readBlob",
                       @[repository, path, encodeInt(ord(source))], decodeString)
  result.vcs.readBlobAt = proc(repository, path, revision: string): auto =
    callRemote[string](transport, "vcs.readBlobAt",
                       @[repository, path, revision], decodeString)
  result.vcs.diff = proc(repository: string; paths: seq[string]; staged: bool;
                         contextLines: int): auto =
    callRemote[string](transport, "vcs.diff",
                       @[repository, joinRecords(paths, '\x1f'),
                         encodeBool(staged), encodeInt(contextLines)],
                       decodeString)
  result.vcs.stage = proc(repository: string; paths: seq[string]): auto =
    callRemote[Nothing](transport, "vcs.stage",
                        @[repository, joinRecords(paths, '\x1f')], decodeNothing)
  result.vcs.unstage = proc(repository: string; paths: seq[string]): auto =
    callRemote[Nothing](transport, "vcs.unstage",
                        @[repository, joinRecords(paths, '\x1f')], decodeNothing)
  result.vcs.discardChanges = proc(repository: string; paths: seq[string]): auto =
    callRemote[Nothing](transport, "vcs.discardChanges",
                        @[repository, joinRecords(paths, '\x1f')], decodeNothing)
  result.vcs.applyPatch = proc(repository, patch: string; reverse: bool): auto =
    callRemote[Nothing](transport, "vcs.applyPatch",
                        @[repository, patch, encodeBool(reverse)], decodeNothing)
  result.vcs.commit = proc(repository, message, authorName, authorEmail: string): auto =
    callRemote[VcsCommit](transport, "vcs.commit",
                          @[repository, message, authorName, authorEmail],
                          decodeCommit)
  result.vcs.initRepository = proc(path: string): auto =
    callRemote[Nothing](transport, "vcs.initRepository", @[path], decodeNothing)
  result.vcs.fetch = proc(repository, remote: string): auto =
    callRemote[Nothing](transport, "vcs.fetch", @[repository, remote], decodeNothing)
  result.vcs.push = proc(repository, remote, refspec: string): auto =
    callRemote[Nothing](transport, "vcs.push",
                        @[repository, remote, refspec], decodeNothing)

  # -- settings -----------------------------------------------------------
  result.settings.get = proc(scope: SettingsScope; key: string): auto =
    callRemote[string](transport, "settings.get",
                       @[encodeInt(ord(scope)), key], decodeString)
  result.settings.set = proc(scope: SettingsScope; key, value: string): auto =
    callRemote[Nothing](transport, "settings.set",
                        @[encodeInt(ord(scope)), key, value], decodeNothing)
  result.settings.delete = proc(scope: SettingsScope; key: string): auto =
    callRemote[Nothing](transport, "settings.delete",
                        @[encodeInt(ord(scope)), key], decodeNothing)
  result.settings.keys = proc(scope: SettingsScope; prefix: string): auto =
    callRemote[seq[string]](transport, "settings.keys",
                            @[encodeInt(ord(scope)), prefix], decodeStringSeq)
  result.settings.environment = proc(name: string): auto =
    callRemote[string](transport, "settings.environment", @[name], decodeString)
  result.settings.getSecret = proc(account, key: string): auto =
    callRemote[string](transport, "settings.getSecret", @[account, key], decodeString)
  result.settings.setSecret = proc(account, key, value: string): auto =
    callRemote[Nothing](transport, "settings.setSecret",
                        @[account, key, value], decodeNothing)
  result.settings.deleteSecret = proc(account, key: string): auto =
    callRemote[Nothing](transport, "settings.deleteSecret",
                        @[account, key], decodeNothing)

  # -- clipboard ----------------------------------------------------------
  result.clipboard.writeText = proc(text: string): auto =
    callRemote[Nothing](transport, "clipboard.writeText", @[text], decodeNothing)
  result.clipboard.readText = proc(): auto =
    callRemote[string](transport, "clipboard.readText", @[], decodeString)
  result.clipboard.writeHtml = proc(html, plainText: string): auto =
    callRemote[Nothing](transport, "clipboard.writeHtml",
                        @[html, plainText], decodeNothing)

  # -- download -----------------------------------------------------------
  proc encodeFilters(filters: seq[FileFilter]): string =
    var records: seq[string] = @[]
    for filter in filters:
      records.add filter.name & "\x1f" & joinRecords(filter.extensions, ',')
    joinRecords(records, '\x1e')

  result.download.offerFile = proc(suggestedName: string; content: seq[byte];
                                   mimeType: string): auto =
    callRemote[Nothing](transport, "download.offerFile",
                        @[suggestedName, encodeBytes(content), mimeType],
                        decodeNothing)
  result.download.offerText = proc(suggestedName, content, mimeType: string): auto =
    callRemote[Nothing](transport, "download.offerText",
                        @[suggestedName, content, mimeType], decodeNothing)
  result.download.openFileDialog = proc(options: OpenDialogOptions): auto =
    callRemote[seq[string]](transport, "download.openFileDialog",
                            @[options.title, options.defaultPath,
                              encodeFilters(options.filters),
                              encodeBool(options.allowMultiple)],
                            decodeStringSeq)
  result.download.saveFileDialog = proc(options: SaveDialogOptions): auto =
    callRemote[string](transport, "download.saveFileDialog",
                       @[options.title, options.suggestedName,
                         options.defaultDirectory, encodeFilters(options.filters)],
                       decodeString)
  result.download.pickDirectory = proc(options: OpenDialogOptions): auto =
    callRemote[string](transport, "download.pickDirectory",
                       @[options.title, options.defaultPath], decodeString)

  # -- shell --------------------------------------------------------------
  result.shell.openExternalUrl = proc(url: string): auto =
    callRemote[Nothing](transport, "shell.openExternalUrl", @[url], decodeNothing)
  result.shell.revealInFileManager = proc(path: string): auto =
    callRemote[Nothing](transport, "shell.revealInFileManager", @[path], decodeNothing)
  result.shell.windowState = proc(): auto =
    callRemote[WindowState](transport, "shell.windowState", @[], decodeWindowState)
  result.shell.minimizeWindow = proc(): auto =
    callRemote[Nothing](transport, "shell.minimizeWindow", @[], decodeNothing)
  result.shell.toggleMaximizeWindow = proc(): auto =
    callRemote[Nothing](transport, "shell.toggleMaximizeWindow", @[], decodeNothing)
  result.shell.closeWindow = proc(): auto =
    callRemote[Nothing](transport, "shell.closeWindow", @[], decodeNothing)
  result.shell.setFullscreen = proc(fullscreen: bool): auto =
    callRemote[Nothing](transport, "shell.setFullscreen",
                        @[encodeBool(fullscreen)], decodeNothing)
  result.shell.openSessionWindow = proc(sessionId: string): auto =
    callRemote[Nothing](transport, "shell.openSessionWindow",
                        @[sessionId], decodeNothing)
  # `onWindowStateChanged` is a subscription with no return value, so there is
  # nothing to round-trip: the endpoint pushes, and this side registers. It is
  # left as `newPlatform`'s no-op rather than given a fake registration, because
  # a stub that pretended to subscribe would assert something untrue.
