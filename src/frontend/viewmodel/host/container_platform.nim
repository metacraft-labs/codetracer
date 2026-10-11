## The client half of the container deployment: every facade operation as one
## call over the endpoint contract.
##
## ## What this is
##
## `Architecture/UI-Bundle-And-Endpoints.md` §6 is the contract; this module is
## the side of it that the bundle runs. Every field of all seven facades is one
## `call` frame out and one `reply` frame back, with `endpoint_codec.nim`
## deciding what the values look like in between. It is the fourth facade
## instantiation, beside `desktop_electron`, `desktop_native` and
## `web_platform`.
##
## ## Why this file was promoted rather than copied
##
## It began as NS1's `remote_stub.nim`, whose reason for existing was to
## satisfy **every field of all seven facades** so that
## `test_a_remote_instantiation_needs_no_signature_change` was a compile rather
## than a review: if a facade grows an operation whose signature only makes
## sense in-process — one returning a `File`, a `Process`, a pointer, or an
## iterator — this module stops compiling, and it stops compiling on the day
## the operation is added. `{.requiresInit.}` on the seven facade types is what
## makes that true.
##
## A second module under the same obligation would be a second place to
## maintain that completeness, which is the drift WD1b exists to remove. So the
## demonstration became the implementation, and the property it was built to
## hold is unchanged.
##
## ## `RemoteTransport` is still a caller-supplied seam
##
## Everything here is one call to a `proc(request) -> future[response]` the
## caller hands in. That is deliberate and survives promotion for two reasons:
## the bundle's real transport is the socket `ct host` already opens (§6.1),
## which belongs to the page rather than to the facade, and a suite can
## exercise every verb with a fake and no network at all. There is no socket in
## this file and there is no `hello`/`welcome` exchange — `endpoint_protocol`
## owns the envelope, and whoever opens the channel performs the handshake.
##
## ## Sixteen operations that are NOT one call — §6.6
##
## `newContainerPlatform(transport, profile)` below routes every field over the
## wire, including the clipboard, the downloads and the window. That is the
## right shape for a suite that wants to see a verb arrive and it is the WRONG
## shape for a deployment: §6.6 measured that a container endpoint refuses all
## sixteen and withdraws their capabilities, so a user sat in a browser with a
## clipboard got a platform with none.
##
## `newContainerPlatform(transport, tab, welcome)` is the deployment's
## constructor. It builds fs / process / vcs / settings over the transport and
## takes clipboard / download / shell from `platform/browser_facades.nim` — the
## same three builders `web_platform.newWebPlatform` uses, not a second copy —
## and composes the profile as the union §6.3 is refined into.
##
## ## What is NOT here: the event frames
##
## `fs.watch` and `process.start` take callbacks, and §6.2's `event` frame is
## how the endpoint delivers against them. `RemoteTransport` is one hop, so it
## cannot carry a stream; the callbacks stay on this side and the handle the
## verb returns is what an `event` frame is keyed on. Wiring that registry is
## the duplex channel's job, not this module's, and pretending to subscribe
## here would assert something untrue.

import std/json

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
import ../platform/endpoint_codec
import ../platform/browser_facades

type
  RemoteRequest* = object
    verb*: string
      ## The facade operation, e.g. `"fs.readText"`. §6.2 fixes the dotted
      ## vocabulary, and it is this module's, unchanged: the server dispatches
      ## on exactly these strings.
    args*: JsonNode
      ## A JSON **object** with named fields, never a positional list. The
      ## server reads `args["source"]`, so a client that swapped two positions
      ## would be caught by the name rather than by the arity.

  RemoteResponse* = object
    ok*: bool
    payload*: JsonNode
    errorKind*: PlatformErrorKind
    errorMessage*: string
    detail*: string
      ## §6.2's `detail`: the originating diagnostic, kept separate so a
      ## container call is no less debuggable than the same call in-process.

  RemoteTransport* = proc(request: RemoteRequest
                         ): PlatformFuture[RemoteResponse]
    ## One hop. Everything in this module is one call to this.

proc remoteOk*(payload: JsonNode): RemoteResponse =
  RemoteResponse(ok: true, payload: payload)

proc remoteErr*(kind: PlatformErrorKind; message: string;
                detail = ""): RemoteResponse =
  RemoteResponse(ok: false, errorKind: kind, errorMessage: message,
                 detail: detail)

# ---------------------------------------------------------------------------
# The one adapter every operation goes through
# ---------------------------------------------------------------------------

proc decoded[T](verb: string; payload: JsonNode;
                decode: proc(payload: JsonNode): T): PlatformOutcome[T] =
  ## Decode, or turn the refusal into the outcome the caller already handles.
  ##
  ## `endpoint_codec`'s decoders RAISE on a payload this build cannot read —
  ## an unknown enum name, a non-base64 byte string — and that is the right
  ## answer there, because a `vfsDeleted` read as `vfsUnmodified` is worse than
  ## a refusal that says so. But the raise happens inside a completion
  ## callback, where on the JS backend nothing is left to catch it and it
  ## escapes into the renderer.
  ##
  ## `pkTransport` rather than `pkFailed`, for §6.4's reason: the server did
  ## not fail, the two ends disagreed about the bytes, and `pkTransport` is the
  ## one kind the contract reserves for what only this side can observe.
  try:
    succeeded(decode(payload))
  except ProtocolError as e:
    failed[T](pkTransport, verb & ": the endpoint's reply could not be read",
              e.msg)

proc callRemote[T](transport: RemoteTransport; verb: string; args: JsonNode;
                   decode: proc(payload: JsonNode): T
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
        if r.ok: newCompletedFuture(decoded(verb, r.payload, decode))
        else: newCompletedFuture(failed[T](r.errorKind, r.errorMessage, r.detail))
    else:
      result = newPromise(proc(resolve: proc(v: PlatformOutcome[T])) =
        discard response.then(proc(r: RemoteResponse) =
          if r.ok: resolve(decoded(verb, r.payload, decode))
          else: resolve(failed[T](r.errorKind, r.errorMessage, r.detail))))
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
          if r.ok: promise.complete(decoded(verb, r.payload, decode))
          else: promise.complete(failed[T](r.errorKind, r.errorMessage, r.detail)))
    result = promise

proc decodeNothing(payload: JsonNode): Nothing = nothing
  ## The one decoder `endpoint_codec` does not carry, and deliberately: a verb
  ## that returns nothing has no value type to agree about, so there is nothing
  ## for the two ends to get wrong.

# ---------------------------------------------------------------------------
# The instantiation
# ---------------------------------------------------------------------------

proc newContainerPlatform*(transport: RemoteTransport;
                           profile: PlatformProfile): Platform =
  ## Every facade field, satisfied by one round trip.
  ##
  ## **The profile has no default, and that is the point of §6.3.** It used to
  ## default to `containerProfile`, a compiled-in constant — and a compiled-in
  ## constant can always be the wrong one, which is exactly the defect WD1b was
  ## opened on: the served page reached `newPlatform(webProfile)` through a
  ## fallback written for a dev server and advertised three capabilities every
  ## facade then refused. A required parameter makes each call site say where
  ## its profile came from: the overload below says "the server declared it",
  ## and a suite that passes `containerProfile` is visibly choosing it rather
  ## than inheriting it.
  result = newPlatform(profile)

  # -- filesystem ---------------------------------------------------------
  result.fs.readText = proc(path: string): auto =
    callRemote[string](transport, "fs.readText", %*{"path": path}, decodeText)
  result.fs.readBytes = proc(path: string): auto =
    callRemote[seq[byte]](transport, "fs.readBytes", %*{"path": path},
                          decodeBytes)
  result.fs.writeText = proc(path, content: string): auto =
    callRemote[Nothing](transport, "fs.writeText",
                        %*{"path": path, "content": content}, decodeNothing)
  result.fs.writeBytes = proc(path: string; content: seq[byte]): auto =
    callRemote[Nothing](transport, "fs.writeBytes",
                        %*{"path": path, "content": encodeBytes(content)},
                        decodeNothing)
  result.fs.appendText = proc(path, content: string): auto =
    callRemote[Nothing](transport, "fs.appendText",
                        %*{"path": path, "content": content}, decodeNothing)
  result.fs.stat = proc(path: string): auto =
    callRemote[FsStat](transport, "fs.stat", %*{"path": path}, decodeFsStat)
  result.fs.listDir = proc(path: string): auto =
    callRemote[seq[FsDirEntry]](transport, "fs.listDir", %*{"path": path},
                                decodeFsDirEntries)
  result.fs.createDir = proc(path: string): auto =
    callRemote[Nothing](transport, "fs.createDir", %*{"path": path},
                        decodeNothing)
  result.fs.remove = proc(path: string; recursive: bool): auto =
    callRemote[Nothing](transport, "fs.remove",
                        %*{"path": path, "recursive": recursive},
                        decodeNothing)
  result.fs.copy = proc(source, destination: string): auto =
    callRemote[Nothing](transport, "fs.copy",
                        %*{"source": source, "destination": destination},
                        decodeNothing)
  result.fs.move = proc(source, destination: string): auto =
    callRemote[Nothing](transport, "fs.move",
                        %*{"source": source, "destination": destination},
                        decodeNothing)
  result.fs.realPath = proc(path: string): auto =
    callRemote[string](transport, "fs.realPath", %*{"path": path}, decodeText)
  result.fs.makeTempDir = proc(prefix: string): auto =
    callRemote[string](transport, "fs.makeTempDir", %*{"prefix": prefix},
                       decodeText)
  result.fs.watch = proc(path: string; recursive: bool;
                         onEvent: proc(event: FsWatchEvent)): auto =
    # The callback stays on this side of the wire; the endpoint streams §6.2
    # `event` frames keyed on the handle this returns. That the SIGNATURE
    # accommodates that without change is the point — a watch that had returned
    # an OS handle could not.
    callRemote[FsWatchHandle](transport, "fs.watch",
                              %*{"path": path, "recursive": recursive},
                              decodeFsWatchHandle)
  result.fs.unwatch = proc(handle: FsWatchHandle): auto =
    callRemote[Nothing](transport, "fs.unwatch",
                        %*{"handle": encodeFsWatchHandle(handle)},
                        decodeNothing)
  result.fs.certificateStoreRoots = proc(): auto =
    # The CONTAINER's store, resolved by the container process from its own
    # environment and account: that is where its test runs wrote. The tab's
    # machine has no say in it.
    callRemote[CertificateStoreRoots](transport, "fs.certificateStoreRoots",
                                      newJObject(),
                                      decodeCertificateStoreRoots)

  # -- process ------------------------------------------------------------
  result.process.run = proc(spec: ProcessSpec): auto =
    callRemote[ProcessRunResult](transport, "process.run",
                                 %*{"spec": encodeProcessSpec(spec)},
                                 decodeProcessRunResult)
  result.process.start = proc(spec: ProcessSpec;
                              onOutput: proc(chunk: ProcessOutputChunk);
                              onExit: proc(exit: ProcessExit)): auto =
    callRemote[ProcessHandle](transport, "process.start",
                              %*{"spec": encodeProcessSpec(spec)},
                              decodeProcessHandle)
  result.process.signal = proc(handle: ProcessHandle; signal: ProcessSignal): auto =
    callRemote[Nothing](transport, "process.signal",
                        %*{"handle": encodeProcessHandle(handle),
                           "signal": encodeProcessSignal(signal)},
                        decodeNothing)
  result.process.writeStdin = proc(handle: ProcessHandle; text: string): auto =
    callRemote[Nothing](transport, "process.writeStdin",
                        %*{"handle": encodeProcessHandle(handle),
                           "text": text},
                        decodeNothing)
  result.process.closeStdin = proc(handle: ProcessHandle): auto =
    callRemote[Nothing](transport, "process.closeStdin",
                        %*{"handle": encodeProcessHandle(handle)},
                        decodeNothing)
  result.process.isRunning = proc(handle: ProcessHandle): auto =
    callRemote[bool](transport, "process.isRunning",
                     %*{"handle": encodeProcessHandle(handle)}, decodeFlag)
  result.process.which = proc(program: string): auto =
    callRemote[string](transport, "process.which", %*{"program": program},
                       decodeText)

  # -- vcs ----------------------------------------------------------------
  result.vcs.isRepository = proc(path: string): auto =
    callRemote[bool](transport, "vcs.isRepository", %*{"path": path},
                     decodeFlag)
  result.vcs.repositoryRoot = proc(path: string): auto =
    callRemote[string](transport, "vcs.repositoryRoot", %*{"path": path},
                       decodeText)
  result.vcs.status = proc(repository: string): auto =
    callRemote[VcsStatus](transport, "vcs.status",
                          %*{"repository": repository}, decodeVcsStatus)
  result.vcs.log = proc(repository: string; maxCount: int; path: string): auto =
    callRemote[seq[VcsCommit]](transport, "vcs.log",
                               %*{"repository": repository,
                                  "maxCount": maxCount, "path": path},
                               decodeVcsCommits)
  result.vcs.readBlob = proc(repository, path: string; source: VcsBlobSource): auto =
    callRemote[string](transport, "vcs.readBlob",
                       %*{"repository": repository, "path": path,
                          "source": encodeVcsBlobSource(source)},
                       decodeText)
  result.vcs.readBlobAt = proc(repository, path, revision: string): auto =
    callRemote[string](transport, "vcs.readBlobAt",
                       %*{"repository": repository, "path": path,
                          "revision": revision},
                       decodeText)
  result.vcs.diff = proc(repository: string; paths: seq[string]; staged: bool;
                         contextLines: int): auto =
    callRemote[string](transport, "vcs.diff",
                       %*{"repository": repository,
                          "paths": encodeTextSeq(paths), "staged": staged,
                          "contextLines": contextLines},
                       decodeText)
  result.vcs.contentId = proc(repository: string; state: VcsBlobSource;
                              algorithm: string; scope: seq[string]
                             ): PlatformFuture[PlatformOutcome[VcsContentId]] =
    # Refused HERE, without a round trip, when the profile this client was
    # built from lacks `capVcsRead`: that profile is the server's declaration
    # (§6.3), so a call it does not cover would be refused there too, and
    # this side can name the capability without asking. The endpoint gates
    # the verb as well, for a client that does not.
    if not profile.hasAll(ContentIdRequires):
      return resolved(contentIdRefusal(profile))
    callRemote[VcsContentId](transport, "vcs.contentId",
                             %*{"repository": repository,
                                "state": encodeVcsBlobSource(state),
                                "algorithm": algorithm,
                                "scope": encodeTextSeq(scope)},
                             decodeVcsContentId)
  result.vcs.stage = proc(repository: string; paths: seq[string]): auto =
    callRemote[Nothing](transport, "vcs.stage",
                        %*{"repository": repository,
                           "paths": encodeTextSeq(paths)},
                        decodeNothing)
  result.vcs.unstage = proc(repository: string; paths: seq[string]): auto =
    callRemote[Nothing](transport, "vcs.unstage",
                        %*{"repository": repository,
                           "paths": encodeTextSeq(paths)},
                        decodeNothing)
  result.vcs.discardChanges = proc(repository: string; paths: seq[string]): auto =
    callRemote[Nothing](transport, "vcs.discardChanges",
                        %*{"repository": repository,
                           "paths": encodeTextSeq(paths)},
                        decodeNothing)
  result.vcs.applyPatch = proc(repository, patch: string; reverse: bool): auto =
    callRemote[Nothing](transport, "vcs.applyPatch",
                        %*{"repository": repository, "patch": patch,
                           "reverse": reverse},
                        decodeNothing)
  result.vcs.commit = proc(repository, message, authorName, authorEmail: string): auto =
    callRemote[VcsCommit](transport, "vcs.commit",
                          %*{"repository": repository, "message": message,
                             "authorName": authorName,
                             "authorEmail": authorEmail},
                          decodeVcsCommit)
  result.vcs.initRepository = proc(path: string): auto =
    callRemote[Nothing](transport, "vcs.initRepository", %*{"path": path},
                        decodeNothing)
  result.vcs.fetch = proc(repository, remote: string): auto =
    callRemote[Nothing](transport, "vcs.fetch",
                        %*{"repository": repository, "remote": remote},
                        decodeNothing)
  result.vcs.push = proc(repository, remote, refspec: string): auto =
    callRemote[Nothing](transport, "vcs.push",
                        %*{"repository": repository, "remote": remote,
                           "refspec": refspec},
                        decodeNothing)

  # -- settings -----------------------------------------------------------
  result.settings.get = proc(scope: SettingsScope; key: string): auto =
    callRemote[string](transport, "settings.get",
                       %*{"scope": encodeSettingsScope(scope), "key": key},
                       decodeText)
  result.settings.set = proc(scope: SettingsScope; key, value: string): auto =
    callRemote[Nothing](transport, "settings.set",
                        %*{"scope": encodeSettingsScope(scope), "key": key,
                           "value": value},
                        decodeNothing)
  result.settings.delete = proc(scope: SettingsScope; key: string): auto =
    callRemote[Nothing](transport, "settings.delete",
                        %*{"scope": encodeSettingsScope(scope), "key": key},
                        decodeNothing)
  result.settings.keys = proc(scope: SettingsScope; prefix: string): auto =
    callRemote[seq[string]](transport, "settings.keys",
                            %*{"scope": encodeSettingsScope(scope),
                               "prefix": prefix},
                            decodeTextSeq)
  result.settings.environment = proc(name: string): auto =
    callRemote[string](transport, "settings.environment", %*{"name": name},
                       decodeText)
  result.settings.getSecret = proc(account, key: string): auto =
    callRemote[string](transport, "settings.getSecret",
                       %*{"account": account, "key": key}, decodeText)
  result.settings.setSecret = proc(account, key, value: string): auto =
    callRemote[Nothing](transport, "settings.setSecret",
                        %*{"account": account, "key": key, "value": value},
                        decodeNothing)
  result.settings.deleteSecret = proc(account, key: string): auto =
    callRemote[Nothing](transport, "settings.deleteSecret",
                        %*{"account": account, "key": key}, decodeNothing)

  # -- clipboard ----------------------------------------------------------
  result.clipboard.writeText = proc(text: string): auto =
    callRemote[Nothing](transport, "clipboard.writeText", %*{"text": text},
                        decodeNothing)
  result.clipboard.readText = proc(): auto =
    callRemote[string](transport, "clipboard.readText", newJObject(),
                       decodeText)
  result.clipboard.writeHtml = proc(html, plainText: string): auto =
    callRemote[Nothing](transport, "clipboard.writeHtml",
                        %*{"html": html, "plainText": plainText},
                        decodeNothing)

  # -- download -----------------------------------------------------------
  result.download.offerFile = proc(suggestedName: string; content: seq[byte];
                                   mimeType: string): auto =
    callRemote[Nothing](transport, "download.offerFile",
                        %*{"suggestedName": suggestedName,
                           "content": encodeBytes(content),
                           "mimeType": mimeType},
                        decodeNothing)
  result.download.offerText = proc(suggestedName, content, mimeType: string): auto =
    callRemote[Nothing](transport, "download.offerText",
                        %*{"suggestedName": suggestedName,
                           "content": content, "mimeType": mimeType},
                        decodeNothing)
  result.download.openFileDialog = proc(options: OpenDialogOptions): auto =
    callRemote[seq[string]](transport, "download.openFileDialog",
                            %*{"options": encodeOpenDialogOptions(options)},
                            decodeTextSeq)
  result.download.saveFileDialog = proc(options: SaveDialogOptions): auto =
    callRemote[string](transport, "download.saveFileDialog",
                       %*{"options": encodeSaveDialogOptions(options)},
                       decodeText)
  result.download.pickDirectory = proc(options: OpenDialogOptions): auto =
    callRemote[string](transport, "download.pickDirectory",
                       %*{"options": encodeOpenDialogOptions(options)},
                       decodeText)

  # -- shell --------------------------------------------------------------
  result.shell.openExternalUrl = proc(url: string): auto =
    callRemote[Nothing](transport, "shell.openExternalUrl", %*{"url": url},
                        decodeNothing)
  result.shell.revealInFileManager = proc(path: string): auto =
    callRemote[Nothing](transport, "shell.revealInFileManager",
                        %*{"path": path}, decodeNothing)
  result.shell.windowState = proc(): auto =
    callRemote[WindowState](transport, "shell.windowState", newJObject(),
                            decodeWindowState)
  result.shell.minimizeWindow = proc(): auto =
    callRemote[Nothing](transport, "shell.minimizeWindow", newJObject(),
                        decodeNothing)
  result.shell.toggleMaximizeWindow = proc(): auto =
    callRemote[Nothing](transport, "shell.toggleMaximizeWindow", newJObject(),
                        decodeNothing)
  result.shell.closeWindow = proc(): auto =
    callRemote[Nothing](transport, "shell.closeWindow", newJObject(),
                        decodeNothing)
  result.shell.setFullscreen = proc(fullscreen: bool): auto =
    callRemote[Nothing](transport, "shell.setFullscreen",
                        %*{"fullscreen": fullscreen}, decodeNothing)
  result.shell.openSessionWindow = proc(sessionId: string): auto =
    callRemote[Nothing](transport, "shell.openSessionWindow",
                        %*{"sessionId": sessionId}, decodeNothing)
  # `onWindowStateChanged` is a subscription with no return value, so there is
  # nothing to round-trip: the endpoint pushes an §6.2 `event` frame, and this
  # side registers. It is left as `newPlatform`'s no-op rather than given a
  # fake registration, because the registry belongs to whoever owns the duplex
  # channel and a platform that pretended to subscribe would assert something
  # untrue.

proc newContainerPlatform*(transport: RemoteTransport;
                           welcome: WelcomeFrame): Platform =
  ## §6.3's path, and the one shipping code should take: the capability set is
  ## whatever the process that will answer the calls said it serves. Spelled as
  ## an overload rather than as a default argument so that "the server declared
  ## it" is legible at the call site — the alternative reads identically to
  ## having assumed one.
  newContainerPlatform(transport, welcome.profile)

proc newContainerPlatform*(transport: RemoteTransport; tab: BrowserTabBridge;
                           profile: PlatformProfile): Platform =
  ## §6.6's constructor: **a verb the tab can answer, the tab answers.**
  ##
  ## The container deployment is a tab AND a container, and the sixteen
  ## operations whose subject is the tab — all three `clipboard.*`, all five
  ## `download.*`, all eight `shell.*` — are answered here rather than sent.
  ## Measured at codetracer `7739d096f`: the client routed all sixteen over the
  ## transport, the server correctly refused every one of them, and the
  ## capability was *gone* rather than served by the side that owns it.
  ##
  ## **The three facades are overwritten wholesale rather than the wire
  ## versions being skipped field by field.** Writing it as a branch inside the
  ## big constructor would have put sixteen `if` statements where the question
  ## is not per-field at all — a facade either has the tab as its subject or it
  ## does not, and all three of these do, entirely. Replacing the whole facade
  ## also means the day a `ShellFacade` grows a field, that field is built by
  ## `buildBrowserShell` with everything else rather than silently inheriting
  ## the wire form nobody re-examined.
  ##
  ## The profile is the UNION, and `withBrowserTab` is where the degradations
  ## are reconciled with it; see its comment for why only the stale direction
  ## can be violated here.
  let composed = profile.withBrowserTab()
  result = newContainerPlatform(transport, composed)
  result.clipboard = buildBrowserClipboard(tab, composed)
  result.download = buildBrowserDownload(tab, composed)
  result.shell = buildBrowserShell(tab, composed)

proc newContainerPlatform*(transport: RemoteTransport; tab: BrowserTabBridge;
                           welcome: WelcomeFrame): Platform =
  ## The shipping path: §6.3's "the server declares the profile" for the half
  ## the server owns, §6.6's union for the half it does not. Spelled as an
  ## overload for the reason the two-argument pair is — "the server declared
  ## it" has to be legible at the call site, because the alternative reads
  ## identically to having assumed one.
  newContainerPlatform(transport, tab, welcome.profile)
