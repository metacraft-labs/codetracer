## THE SERVER HALF OF THE ENDPOINT CONTRACT — the verb dispatcher that turns a
## §6.2 `call` frame into a `reply` frame, and declares the profile it will
## honour in `welcome`.
##
## `Architecture/UI-Bundle-And-Endpoints.md` §6 is the contract.
## `platform/endpoint_protocol.nim` is its envelope and
## `platform/endpoint_codec.nim` is its value codec; both are used here
## unchanged, because they were written to be used by BOTH ends and a second
## encoder on this side would be the drift the campaign exists to remove.
## `host/container_platform.nim` is the client this module answers: its verb
## names and its argument field names are the contract, and every handler below
## reads the fields that module writes.
##
## ## The design decision: THE PROFILE IS COMPUTED FROM THE TABLE
##
## `welcome.profile` is not written down anywhere as a constant. It is
## `containerProfile` — the deployment class's declaration, which is the
## CEILING — intersected with the capabilities the dispatch table actually
## implements, which is the FLOOR. Each entry declares the capabilities it is
## evidence for; a capability with no implemented verb behind it, or with even
## one refused verb among its evidence, is withdrawn.
##
## So the defect WD1b was opened on cannot recur here by the route it took
## there. `ct host` advertised `webProfile` — `capFilesystemRead`,
## `capVcsRead`, `capProcessSpawn` — while all seven facades refused, because
## the profile was a compiled-in constant reached through a fallback. A profile
## derived from the table cannot claim a capability the table does not serve,
## because there is nowhere to write the claim.
##
## ## Why that does NOT make WD1b's verification vacuous
##
## Say this plainly, because a computed profile looks at first glance like it
## proves the thing the milestone asks a test to prove, and it does not:
##
##   * What the computation proves is **self-consistency**: the table and the
##     advertisement agree. It is a statement about two things in this file.
##   * What WD1b's `test_container_platform_advertises_only_what_it_serves`
##     claims is **different**: that each advertised verb actually SUCCEEDS
##     against a real `ct host`. A verb that is present in the table, wired to
##     a handler, and broken — a wrong field name, a git argument that changed,
##     a path joined the wrong way — is advertised by this computation and
##     fails that test.
##
## The two failures are independent, and only the first is closed here. The
## second is step 4 of WD1b's sequence and is deliberately not in this file.
##
## ## Why the dispatcher is SYNCHRONOUS, and why that is a boundary rather than
## ## a shortcut
##
## `dispatch` is a function from a `call` frame to a `reply` frame. It performs
## node's *synchronous* filesystem calls and `child_process.spawnSync`, and
## every verb it serves is bounded by construction.
##
## The verbs that are NOT bounded are exactly the verbs it refuses.
## `fs.watch`, `process.start` and everything reachable only from a started
## child (`signal`, `writeStdin`, `closeStdin`, `isRunning`) deliver their
## real content through §6.2 `event` frames, and **the client has no registry
## for those yet** — `container_platform.nim`'s header says so in as many
## words: "Wiring that registry is the duplex channel's job, not this
## module's". Serving them here would mint a handle the client could never
## receive an event against, which is the "advertised and silently dropped"
## failure this milestone exists to remove, arriving from the other side.
##
## So the synchronous boundary and the capability boundary are the same line
## drawn twice, and that is why a synchronous dispatcher is honest rather than
## expedient.
##
## **The cost, stated rather than hidden:** `process.run` of an unbounded
## command blocks the index process's event loop, and §6.1 puts the existing
## index IPC surface on the same connection. `ProcessSpec.timeoutMs` is
## threaded into `spawnSync`'s `timeout`, so a caller that bounds its command
## is bounded; a caller that does not, is not. Making this asynchronous means
## giving `dispatch` a future-returning signature and is a real change to make
## when a caller needs it — not a defect being papered over here.
##
## ## Errors are mapped ONCE, at the boundary — §6.4
##
## `errorKindForNodeCode` is the only place a node errno becomes a
## `PlatformErrorKind`, exactly as `host/desktop_native.nim`'s `osErrorOutcome`
## is the only place an `OSError` does. `pkTransport` is never produced here:
## §6.4 reserves it for the side that observed a reply that never arrived, and
## a server that answered cannot have observed that.
##
## ## What this module deliberately does not do
##
## No socket, no `hello` handshake policy, no authentication. `handleFrame`
## takes frame text and returns frame text, so whoever owns the connection
## decides what a connection is — and §6.6 says plainly that the socket
## authenticates nothing today and that WD1a narrowing the binding did not
## close that.

import std/[json, jsffi, strutils]

import ../viewmodel/platform/capabilities
import ../viewmodel/platform/outcome
import ../viewmodel/platform/fs
import ../viewmodel/platform/process
import ../viewmodel/platform/vcs
import ../viewmodel/platform/settings
import ../viewmodel/platform/endpoint_codec
import ../viewmodel/host/node_certificate_host

export endpoint_codec

# ---------------------------------------------------------------------------
# Node, bound directly.
#
# NOT through `lib/electron_lib.nim`, and the reason is specific rather than
# stylistic: what this module needs is node's SYNCHRONOUS fs, `spawnSync`, and
# — above all — the `code` property of the error a failed call throws, because
# that string is the entire basis of §6.4's mapping. `electron_lib`'s
# `NodeFilesystem` is the promise-shaped subset the product's async IPC needs
# and carries none of the three. It also reaches for `electron`, which this
# module must not, since it has to load in `ct host` and in a suite with no
# Electron at all.
# ---------------------------------------------------------------------------

{.emit: """
// One try/catch, in JS, because a node error's `code` is the field §6.4 maps
// and Nim's `except:` on the JS backend gives back a message and loses it.
// Returns a plain record rather than throwing, so every call site below is a
// value test instead of an exception handler.
function ctFacadeAttempt(thunk) {
  try {
    return {ok: true, value: thunk()};
  } catch (e) {
    return {
      ok: false,
      code: (e && e.code !== undefined && e.code !== null) ? String(e.code) : "",
      message: String((e && e.message) || e)
    };
  }
}
""".}

proc ctFacadeAttempt(thunk: proc(): JsObject): JsObject {.importjs: "ctFacadeAttempt(#)".}

proc require(module: cstring): JsObject {.importjs: "require(#)".}
proc jsFloor(value: JsObject): JsObject {.importjs: "Math.floor(#)".}
proc bufferFrom(bytes: seq[byte]): JsObject {.importjs: "Buffer.from(#)".}
proc isNullish(value: JsObject): bool {.importjs: "((#) == null)".}
proc assignOver(target, source: JsObject): JsObject {.importjs: "Object.assign(#, #)".}

var nodeProcess {.importc: "process".}: JsObject

let
  nfs = require("fs")
  npath = require("path")
  nos = require("os")
  nchild = require("child_process")

type
  NodeAttempt = object
    ## What `ctFacadeAttempt` handed back, in Nim's vocabulary.
    ok: bool
    value: JsObject
    code: string
      ## The errno name (`ENOENT`, `EACCES`, …), or "" when the throw carried
      ## none. This is what §6.4 maps, and it is the reason the try/catch is
      ## in JS rather than in Nim.
    message: string

proc attempt(thunk: proc(): JsObject): NodeAttempt =
  let raw = ctFacadeAttempt(thunk)
  result.ok = raw["ok"].to(bool)
  if result.ok:
    result.value = raw["value"]
  else:
    result.code = $(raw["code"].to(cstring))
    result.message = $(raw["message"].to(cstring))

proc envValue(name: string): string =
  let raw = nodeProcess["env"][cstring name]
  if isNullish(raw): "" else: $(raw.to(cstring))

proc envIsSet(name: string): bool =
  not isNullish(nodeProcess["env"][cstring name])

proc joinPath(parts: varargs[string]): string =
  ## `path.join`, so the separator is node's rather than a guess. A string
  ## concatenation with `/` works on the container's Linux and quietly does not
  ## on a developer's Windows checkout, which is where a suite would find it.
  var current = ""
  for part in parts:
    current = if current.len == 0: part
              else: $(npath.join(cstring current, cstring part).to(cstring))
  current

# ---------------------------------------------------------------------------
# §6.4 — node errno to `PlatformErrorKind`, in ONE place.
# ---------------------------------------------------------------------------

func errorKindForNodeCode*(code: string): PlatformErrorKind =
  ## The mirror of `desktop_native.osErrorOutcome`, for the codes node puts on
  ## the errors its synchronous calls throw.
  ##
  ## `pkNotFound` in particular has to be reliable for the reason that comment
  ## gives: callers branch on it to tell "no file" from "cannot read the file",
  ## and the two want different UI.
  ##
  ## Two mappings are deliberately NOT the obvious ones:
  ##
  ##   * `ENOTSUP`/`EOPNOTSUPP` map to `pkFailed`, not to `pkNotSupported`.
  ##     §6.3 makes `pkNotSupported` mean exactly one thing — "this deployment
  ##     does not serve this capability" — and a client loops over
  ##     `welcome.profile` on that meaning. An operating system refusing one
  ##     operation on one filesystem would make that loop report a capability
  ##     absence that the profile does not agree with.
  ##   * `pkTransport` appears nowhere. §6.4 reserves it for the side that
  ##     observed a reply that never arrived, and a server that answered
  ##     cannot be that side.
  ##
  ## NODE HAS TWO CODE NAMESPACES and both arrive here. Most synchronous `fs`
  ## calls throw the C errno (`ENOENT`); some throw node's own
  ## (`ERR_FS_EISDIR`, which is what `rmSync` on a directory without
  ## `recursive` gives — never `EISDIR`, and never `ENOTEMPTY`). A mapping that
  ## covered only the errno half would answer `pkFailed` for a refusal the
  ## caller can act on.
  case code
  of "ENOENT", "ENOTDIR", "ENXIO", "ESRCH": pkNotFound
  of "EACCES", "EPERM", "EROFS": pkAccessDenied
  of "EEXIST": pkAlreadyExists
  of "ENOSPC", "EDQUOT", "EFBIG": pkQuotaExceeded
  of "ENOTEMPTY", "EBUSY": pkConflict
  of "EISDIR", "EINVAL", "ENAMETOOLONG", "ERR_FS_EISDIR": pkInvalidArgument
  of "ETIMEDOUT": pkTimeout
  of "ECANCELED": pkCancelled
  else: pkFailed

# ---------------------------------------------------------------------------
# The reply a handler produces.
# ---------------------------------------------------------------------------

type
  VerbReply* = object
    ok*: bool
    payload*: JsonNode
    errorKind*: PlatformErrorKind
    errorMessage*: string
    detail*: string

proc replyOk(payload: JsonNode): VerbReply =
  VerbReply(ok: true, payload: payload)

proc replyNothing(): VerbReply =
  ## The answer to a verb whose client-side decoder is `decodeNothing`. The
  ## payload is null rather than absent because `encodeReply` writes a `null`
  ## for a nil node anyway, and saying so here keeps the two spellings one.
  VerbReply(ok: true, payload: newJNull())

proc replyErr(kind: PlatformErrorKind; message: string;
              detail = ""): VerbReply =
  VerbReply(ok: false, errorKind: kind, errorMessage: message, detail: detail)

proc replyFromNode(action, subject: string; a: NodeAttempt): VerbReply =
  ## Every failed node call becomes a reply here and nowhere else.
  ##
  ## The message is NEUTRAL and the diagnostic goes in `detail`, which is the
  ## split `PlatformError` has always had: a message a user could be shown, and
  ## the originating text a log needs. §6.2's `reply` frame carries `detail`
  ## since 2026-09-30 for exactly this — an earlier version of this proc
  ## appended the errno text to the message because the frame had nowhere else
  ## to put it, which made every container failure read differently from the
  ## same failure in-process.
  ##
  ## The node `code` is kept in `detail` even when a message is present.
  ## `ENOENT` and `ERR_FS_EISDIR` are what someone greps for, and node does not
  ## always put the code in the message text.
  let kind = errorKindForNodeCode(a.code)
  var detail = a.message
  if a.code.len > 0:
    detail = if detail.len > 0: a.code & ": " & detail else: a.code
  replyErr(kind, action & " failed for " & subject, detail)

# ---------------------------------------------------------------------------
# Arguments. A missing or wrongly-typed field RAISES, and `dispatch` turns the
# raise into `pkInvalidArgument` — the same reasoning
# `endpoint_protocol.requireX` gives: a default would put a zero where the
# sender put nothing, and the sender is a client whose field names are the
# contract.
# ---------------------------------------------------------------------------

proc argText(args: JsonNode; key: string): string =
  let field = jrequire(args, key)
  if field.kind != JString:
    raise newException(ProtocolError, "'" & key & "' must be a string")
  field.getStr

proc argFlag(args: JsonNode; key: string): bool =
  let field = jrequire(args, key)
  if field.kind != JBool:
    raise newException(ProtocolError, "'" & key & "' must be a boolean")
  field.getBool

proc argCount(args: JsonNode; key: string): int =
  let field = jrequire(args, key)
  if field.kind != JInt:
    raise newException(ProtocolError, "'" & key & "' must be an integer")
  field.getInt

# ---------------------------------------------------------------------------
# The endpoint's own state.
# ---------------------------------------------------------------------------

type
  FacadeEndpoint* = ref object
    settingsRoot*: string
      ## Where `settings.*` keeps its three scopes.
      ##
      ## A parameter rather than a global, for a reason that is about honesty
      ## and not only about testing: a container's settings belong to the
      ## container, so the deployment has to be able to say where they are —
      ## and a suite that exercised the real verb against a compiled-in
      ## `$XDG_CONFIG_HOME/codetracer` would write into the developer's own
      ## configuration to prove it works.
    tempRoot*: string
      ## Where `fs.makeTempDir` puts its directories; `os.tmpdir()` by
      ## default.
    deployment*: JsonNode
      ## §6.3's opaque half, echoed into `welcome`. WD1c owns its shape (§7);
      ## this module carries it and reads nothing in it.
    granted*: CapabilitySet
      ## The capabilities this endpoint may exercise for its caller. A verb
      ## whose capabilities (`FacadeVerb.serves`) are not all granted is
      ## refused with `pkNotSupported` NAMING the missing ones, and is not
      ## advertised in `welcome`. Defaults to everything the table serves, so
      ## an endpoint nobody narrowed behaves exactly as the table says; a
      ## deployment that must not, say, read version control starts one
      ## without `capVcsRead`, and `vcs.contentId` — which writes loose objects
      ## into `.git/objects` — is then refused rather than run.

proc defaultSettingsRoot(): string =
  # `$CODETRACER_HOME/config`, else `$XDG_CONFIG_HOME/codetracer`, else
  # `~/.config/codetracer` — `common/ct_home.ctConfigDir`'s rule, spelt with
  # this module's own node bindings (it imports nothing from `common/`).
  let ctHome = envValue("CODETRACER_HOME")
  if ctHome.len > 0:
    return joinPath($(npath.resolve(cstring ctHome).to(cstring)), "config",
                    "endpoint")
  let base =
    if envIsSet("XDG_CONFIG_HOME") and envValue("XDG_CONFIG_HOME").len > 0:
      envValue("XDG_CONFIG_HOME")
    else:
      joinPath($(nos.homedir().to(cstring)), ".config")
  joinPath(base, "codetracer", "endpoint")

proc newFacadeEndpoint*(settingsRoot = ""; tempRoot = "";
                        deployment: JsonNode = nil;
                        granted: CapabilitySet = allCapabilities
                       ): FacadeEndpoint =
  ## `granted` defaults to EVERY capability, which the dispatcher reads as
  ## "everything the table serves": the table, not this default, is what
  ## bounds an un-narrowed endpoint.
  FacadeEndpoint(
    settingsRoot: if settingsRoot.len > 0: settingsRoot
                  else: defaultSettingsRoot(),
    tempRoot: if tempRoot.len > 0: tempRoot else: $(nos.tmpdir().to(cstring)),
    deployment: if deployment.isNil: newJObject() else: deployment,
    granted: granted)

proc grantedProfile(ep: FacadeEndpoint): PlatformProfile =
  ## The profile a handler that drives a shared facade implementation
  ## (`vcs.contentIdOver`) checks against: the container class, narrowed to
  ## what this endpoint was granted.
  result = containerProfile.withCapabilities(
    containerProfile.capabilities * ep.granted, containerProfile.degradations)
  result.displayName = "container (ct host endpoint)"

# ---------------------------------------------------------------------------
# Filesystem handlers.
# ---------------------------------------------------------------------------

proc fsEntryKindOf(stats: JsObject): FsEntryKind =
  if stats.isSymbolicLink().to(bool): fekSymlink
  elif stats.isDirectory().to(bool): fekDirectory
  elif stats.isFile().to(bool): fekFile
  else: fekOther

proc hFsReadText(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  let a = attempt(proc(): JsObject = nfs.readFileSync(cstring path, cstring"utf8"))
  if not a.ok: return replyFromNode("read", path, a)
  replyOk(encodeText($(a.value.to(cstring))))

proc hFsReadBytes(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  let a = attempt(proc(): JsObject = nfs.readFileSync(cstring path))
  if not a.ok: return replyFromNode("read", path, a)
  # Buffer -> seq[byte] -> `encodeBytes`, rather than node's own
  # `buffer.toString('base64')`. The two produce the same bytes today, and the
  # day they stop the codec is the one place both ends read, so the codec is
  # what has to say what base64 means here.
  let buffer = a.value
  let length = buffer["length"].to(int)
  var bytes = newSeq[byte](length)
  for i in 0 ..< length:
    bytes[i] = byte(buffer[i].to(int))
  replyOk(encodeBytes(bytes))

proc hFsWriteText(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  let content = argText(args, "content")
  let a = attempt(proc(): JsObject =
    nfs.writeFileSync(cstring path, cstring content, cstring"utf8"))
  if not a.ok: return replyFromNode("write", path, a)
  replyNothing()

proc hFsWriteBytes(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  let bytes = decodeBytes(jrequire(args, "content"))
  let a = attempt(proc(): JsObject =
    nfs.writeFileSync(cstring path, bufferFrom(bytes)))
  if not a.ok: return replyFromNode("write", path, a)
  replyNothing()

proc hFsAppendText(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  let content = argText(args, "content")
  let a = attempt(proc(): JsObject =
    nfs.appendFileSync(cstring path, cstring content, cstring"utf8"))
  if not a.ok: return replyFromNode("append to", path, a)
  replyNothing()

proc hFsStat(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  let a = attempt(proc(): JsObject = nfs.lstatSync(cstring path))
  if not a.ok:
    # A MISSING PATH IS A SUCCESSFUL STAT. `fs.exists` is `stat` mapped through
    # `kind != fekMissing` (platform/fs.nim), so answering `pkNotFound` here
    # would turn "does this exist?" into an error at every call site that asks.
    # `desktop_native` answers the same way.
    if errorKindForNodeCode(a.code) == pkNotFound:
      return replyOk(encodeFsStat(FsStat(kind: fekMissing)))
    return replyFromNode("stat", path, a)
  let stats = a.value
  # `mtimeMs` is fractional in node and `size` is not, but both go through
  # `Math.floor` so the JSON carries an integer either way: `jint64` reads a
  # `JInt` and a `JFloat` would decode as zero on the other end.
  replyOk(encodeFsStat(FsStat(
    kind: fsEntryKindOf(stats),
    size: jsFloor(stats["size"]).to(BiggestInt),
    modifiedMs: jsFloor(stats["mtimeMs"]).to(BiggestInt),
    readOnly: (stats["mode"].to(int) and 0o200) == 0)))

proc hFsListDir(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  let a = attempt(proc(): JsObject =
    nfs.readdirSync(cstring path, js{withFileTypes: true}))
  if not a.ok: return replyFromNode("list", path, a)
  let raw = a.value
  let length = raw["length"].to(int)
  var entries: seq[FsDirEntry] = @[]
  for i in 0 ..< length:
    let entry = raw[i]
    entries.add FsDirEntry(
      name: $(entry["name"].to(cstring)), kind: fsEntryKindOf(entry))
  replyOk(encodeFsDirEntries(entries))

proc hFsCreateDir(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  # `recursive: true` makes this both parent-creating and idempotent, which is
  # what `std/os.createDir` does and therefore what the desktop instantiation
  # already means by this verb.
  let a = attempt(proc(): JsObject =
    nfs.mkdirSync(cstring path, js{recursive: true}))
  if not a.ok: return replyFromNode("create directory", path, a)
  replyNothing()

proc hFsRemove(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  let recursive = argFlag(args, "recursive")
  let a = attempt(proc(): JsObject =
    nfs.rmSync(cstring path, js{recursive: recursive, force: false}))
  if not a.ok: return replyFromNode("remove", path, a)
  replyNothing()

proc hFsCopy(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let source = argText(args, "source")
  let destination = argText(args, "destination")
  # `copyFileSync`, not `cpSync`: the facade's `copy(source, destination)` has
  # no `recursive` argument, so there is no way for a caller to ASK for a tree
  # copy and no way for this side to know one was meant. A directory therefore
  # fails with `EISDIR` -> `pkInvalidArgument`, which says what happened.
  let a = attempt(proc(): JsObject =
    nfs.copyFileSync(cstring source, cstring destination))
  if not a.ok: return replyFromNode("copy", source, a)
  replyNothing()

proc hFsMove(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let source = argText(args, "source")
  let destination = argText(args, "destination")
  let a = attempt(proc(): JsObject =
    nfs.renameSync(cstring source, cstring destination))
  if not a.ok:
    # `EXDEV` — a rename across filesystems — is a real case in a container,
    # where the project volume and `/tmp` are routinely different mounts. It
    # is reported rather than silently turned into copy+delete, because the
    # two differ in what survives a failure half way.
    return replyFromNode("move", source, a)
  replyNothing()

proc hFsRealPath(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  let a = attempt(proc(): JsObject = nfs.realpathSync(cstring path))
  if not a.ok: return replyFromNode("resolve", path, a)
  replyOk(encodeText($(a.value.to(cstring))))

proc hFsMakeTempDir(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let prefix = argText(args, "prefix")
  let stem = joinPath(ep.tempRoot, prefix)
  let a = attempt(proc(): JsObject = nfs.mkdtempSync(cstring stem))
  if not a.ok: return replyFromNode("create a temporary directory", prefix, a)
  replyOk(encodeText($(a.value.to(cstring))))

proc hFsCertificateStoreRoots(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  ## The local certificate store's two roots (Transport §2.1), as THIS process
  ## resolves them: the container's environment and account, which is where
  ## the container's test runs wrote.
  replyOk(encodeCertificateStoreRoots(nodeCertificateStoreRoots()))

# ---------------------------------------------------------------------------
# Processes — and, through them, git.
# ---------------------------------------------------------------------------

type
  RunOutcome = object
    ## The result of actually starting something. `ran` is about the SPAWN,
    ## never about the exit code: a command that ran and exited 1 ran, and
    ## `process.run` reports that as a success carrying a non-zero exit —
    ## which is what `desktop_native` does and what every caller of the facade
    ## is written against.
    ran: bool
    kind: PlatformErrorKind
    message: string
    result: ProcessRunResult

proc runSpec(spec: ProcessSpec): RunOutcome =
  ## The one spawn in this module. `process.run` is a thin wrapper over it and
  ## so is every `vcs.*` verb — the milestone's note, made structural: there is
  ## no VCS message in the index IPC surface because product VCS is `git` run
  ## as a process, so `vcs.*` is served by running `git`, the same way
  ## `process.run` is, through the same code and the same error mapping.
  let options = newJsObject()
  options["encoding"] = cstring"utf8"
  # 64 MiB. `spawnSync`'s default is 1 MiB and `git log` over a real repository
  # passes it, at which point node reports ENOBUFS and truncates — a failure
  # that looks like a git failure and is not.
  options["maxBuffer"] = 64 * 1024 * 1024
  options["windowsHide"] = true
  if spec.workingDir.len > 0:
    options["cwd"] = cstring spec.workingDir
  if spec.timeoutMs > 0:
    options["timeout"] = spec.timeoutMs
  if spec.stdinText.len > 0:
    options["input"] = cstring spec.stdinText
  if spec.clearEnv or spec.env.len > 0:
    let env = newJsObject()
    if not spec.clearEnv:
      discard assignOver(env, nodeProcess["env"])
    for pair in spec.env:
      env[cstring pair.key] = cstring pair.value
    options["env"] = env

  var argv: seq[cstring] = @[]
  for a in spec.args:
    argv.add cstring(a)

  let attempted = attempt(proc(): JsObject =
    nchild.spawnSync(cstring spec.command, argv, options))
  if not attempted.ok:
    return RunOutcome(ran: false, kind: errorKindForNodeCode(attempted.code),
                      message: "cannot run " & spec.command & ": " &
                               attempted.message)

  let raw = attempted.value
  if not isNullish(raw["error"]):
    # `spawnSync` reports a failed spawn and a timeout as a value rather than
    # as a throw, so this arm is not a duplicate of the one above: ENOENT for a
    # command that is not there, and ETIMEDOUT when `timeoutMs` bit, both land
    # here.
    let code = if isNullish(raw["error"]["code"]): ""
               else: $(raw["error"]["code"].to(cstring))
    let text = if isNullish(raw["error"]["message"]): ""
               else: $(raw["error"]["message"].to(cstring))
    return RunOutcome(ran: false, kind: errorKindForNodeCode(code),
                      message: "cannot run " & spec.command & ": " & text)

  let signalled = not isNullish(raw["signal"])
  result.ran = true
  result.result = ProcessRunResult(
    exit: ProcessExit(
      exitCode: if isNullish(raw["status"]): -1 else: raw["status"].to(int),
      signalled: signalled,
      signalName: if signalled: $(raw["signal"].to(cstring)) else: ""),
    stdout: if isNullish(raw["stdout"]): "" else: $(raw["stdout"].to(cstring)),
    stderr: if isNullish(raw["stderr"]): "" else: $(raw["stderr"].to(cstring)))

proc hProcessRun(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let spec = decodeProcessSpec(jrequire(args, "spec"))
  if spec.command.len == 0:
    return replyErr(pkInvalidArgument, "process.run was given no command")
  let outcome = runSpec(spec)
  if not outcome.ran:
    return replyErr(outcome.kind, outcome.message)
  replyOk(encodeProcessRunResult(outcome.result))

proc isExecutableFile(path: string): bool =
  let executable = attempt(proc(): JsObject =
    nfs.accessSync(cstring path, nfs["constants"]["X_OK"]))
  if not executable.ok: return false
  # `access(X_OK)` succeeds for a directory, so the kind has to be checked
  # too — otherwise a directory named `git` earlier on `PATH` would be
  # reported as the program.
  let stats = attempt(proc(): JsObject = nfs.statSync(cstring path))
  stats.ok and stats.value.isFile().to(bool)

proc hProcessWhich(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let program = argText(args, "program")
  if program.len == 0:
    return replyErr(pkInvalidArgument, "process.which was given no program")
  if program.contains('/') or program.contains('\\'):
    # An explicit path is not a search. Resolving it against `PATH` would
    # answer a different question from the one asked.
    if isExecutableFile(program):
      return replyOk(encodeText(program))
    return replyErr(pkNotFound, program & " is not an executable file")
  let separator = $(npath["delimiter"].to(cstring))
  for directory in envValue("PATH").split(separator):
    if directory.len == 0: continue
    let candidate = joinPath(directory, program)
    if isExecutableFile(candidate):
      return replyOk(encodeText(candidate))
  # `PATHEXT` is not consulted. The container deployment is Linux by
  # definition (§1's table: "processes and a filesystem in the container"), and
  # a half-done Windows search would be worse than none — it would answer for
  # `git` and not for `git.cmd`.
  replyErr(pkNotFound, program & " is not on the search path")

# ---------------------------------------------------------------------------
# Version control — `git`, through `runSpec`.
#
# The ARGUMENTS are `host/native_vcs.nim`'s, verbatim, because that module is
# the same facade over the same binary for the native process. Two spellings of
# `git status --porcelain=v2 --branch` would be two answers to "what does this
# facade mean by a status", and `parsePorcelainV2` is imported from
# `platform/vcs.nim` rather than re-written for the same reason.
# ---------------------------------------------------------------------------

type
  GitOutcome = object
    ok: bool
    output: string
    kind: PlatformErrorKind
    message: string

proc git(repository: string; args: seq[string]; stdinText = ""): GitOutcome =
  var spec = processSpec("git", args, workingDir = repository)
  spec.stdinText = stdinText
  let outcome = runSpec(spec)
  if not outcome.ran:
    return GitOutcome(ok: false, kind: pkNotFound, message: outcome.message)
  if outcome.result.exit.exitCode != 0:
    return GitOutcome(
      ok: false, kind: pkFailed,
      message: "git " & args.join(" ") & " failed: " &
        outcome.result.stderr.strip())
  GitOutcome(ok: true, output: outcome.result.stdout)

template gitText(body: untyped): untyped =
  let outcome = body
  if not outcome.ok: return replyErr(outcome.kind, outcome.message)
  outcome.output

proc hVcsIsRepository(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  let outcome = git(path, @["rev-parse", "--is-inside-work-tree"])
  # A non-repository is a `false`, not a failure — `native_vcs` answers the
  # same way, and a caller asking "is this a repository" has already accounted
  # for "no".
  replyOk(encodeFlag(outcome.ok and outcome.output.strip() == "true"))

proc hVcsRepositoryRoot(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  let output = gitText git(path, @["rev-parse", "--show-toplevel"])
  replyOk(encodeText(output.strip()))

proc hVcsStatus(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let repository = argText(args, "repository")
  let output = gitText git(repository, @["status", "--porcelain=v2", "--branch"])
  replyOk(encodeVcsStatus(parsePorcelainV2(output)))

proc hVcsLog(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let repository = argText(args, "repository")
  let maxCount = argCount(args, "maxCount")
  let path = argText(args, "path")
  var arguments = @["log", "--max-count=" & $maxCount,
    "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b%x1e"]
  if path.len > 0:
    arguments.add "--"
    arguments.add path
  let output = gitText git(repository, arguments)
  var commits: seq[VcsCommit] = @[]
  for record in output.split('\x1e'):
    let trimmed = record.strip()
    if trimmed.len == 0: continue
    let fields = trimmed.split('\x1f')
    if fields.len < 8: continue
    var authoredAt: int64 = 0
    try: authoredAt = parseBiggestInt(fields[5]) * 1000
    except ValueError: discard
    commits.add VcsCommit(
      id: fields[0], shortId: fields[1],
      parents: if fields[2].len > 0: fields[2].split(' ') else: @[],
      authorName: fields[3], authorEmail: fields[4],
      authoredAtMs: authoredAt, subject: fields[6], body: fields[7])
  replyOk(encodeVcsCommits(commits))

proc hVcsReadBlob(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let repository = argText(args, "repository")
  let path = argText(args, "path")
  case decodeVcsBlobSource(jrequire(args, "source"))
  of vbsWorkingTree:
    let full = joinPath(repository, path)
    let a = attempt(proc(): JsObject = nfs.readFileSync(cstring full, cstring"utf8"))
    if not a.ok: return replyFromNode("read the working-tree copy of", path, a)
    replyOk(encodeText($(a.value.to(cstring))))
  of vbsIndex:
    replyOk(encodeText(gitText git(repository, @["show", ":" & path])))
  of vbsHead:
    replyOk(encodeText(gitText git(repository, @["show", "HEAD:" & path])))

proc hVcsReadBlobAt(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let repository = argText(args, "repository")
  let path = argText(args, "path")
  let revision = argText(args, "revision")
  replyOk(encodeText(gitText git(repository, @["show", revision & ":" & path])))

proc hVcsDiff(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let repository = argText(args, "repository")
  let paths = decodeTextSeq(jrequire(args, "paths"))
  let staged = argFlag(args, "staged")
  let contextLines = argCount(args, "contextLines")
  var arguments = @["diff", "--unified=" & $contextLines]
  if staged: arguments.add "--cached"
  if paths.len > 0:
    arguments.add "--"
    for p in paths: arguments.add p
  replyOk(encodeText(gitText git(repository, arguments)))

proc hVcsContentId(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  ## `vcs.contentId` — the content id of W, H or S (Status-Bar.md), by the ONE
  ## recipe (`ct_test/certificate_content_id`, through `vcs.contentIdOver`)
  ## with node's `spawnSync` as its git and the endpoint's temp root for its
  ## temporary index.
  ##
  ## REQUIRES `capVcsRead` (`vcs.ContentIdRequires`). WHAT IT WRITES: loose,
  ## content-addressed blob and tree objects into the repository's
  ## `.git/objects`, and nothing else — no ref, no index (only a copy of it,
  ## outside the repository, is written), no working-tree file.
  let repository = argText(args, "repository")
  let state = decodeVcsBlobSource(jrequire(args, "state"))
  let algorithm = argText(args, "algorithm")
  let scopeField = jrequire(args, "scope")
  if scopeField.kind != JArray:
    raise newException(ProtocolError, "'scope' must be a list of paths")
  let scope = decodeTextSeq(scopeField)
  let outcome = contentIdOver(nodeContentIdHost(ep.tempRoot), ep.grantedProfile(),
                              repository, state, algorithm, scope)
  if not outcome.ok:
    return replyErr(outcome.error.kind, outcome.error.message,
                    outcome.error.detail)
  replyOk(encodeVcsContentId(outcome.value))

proc hVcsStage(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let repository = argText(args, "repository")
  let paths = decodeTextSeq(jrequire(args, "paths"))
  discard gitText git(repository, @["add", "--"] & paths)
  replyNothing()

proc hVcsUnstage(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let repository = argText(args, "repository")
  let paths = decodeTextSeq(jrequire(args, "paths"))
  discard gitText git(repository, @["restore", "--staged", "--"] & paths)
  replyNothing()

proc hVcsDiscardChanges(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let repository = argText(args, "repository")
  let paths = decodeTextSeq(jrequire(args, "paths"))
  discard gitText git(repository, @["restore", "--"] & paths)
  replyNothing()

proc hVcsApplyPatch(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let repository = argText(args, "repository")
  let patch = argText(args, "patch")
  let reverse = argFlag(args, "reverse")
  var arguments = @["apply"]
  if reverse: arguments.add "--reverse"
  arguments.add "-"
  let outcome = git(repository, arguments, stdinText = patch)
  if not outcome.ok:
    # `pkConflict` rather than `pkFailed`, as `native_vcs` has it: a patch that
    # does not apply is a state disagreement the caller can act on, and it is
    # the one git failure here that is routinely not a bug.
    let kind = if outcome.kind == pkFailed: pkConflict else: outcome.kind
    return replyErr(kind, outcome.message)
  replyNothing()

proc hVcsCommit(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let repository = argText(args, "repository")
  let message = argText(args, "message")
  let authorName = argText(args, "authorName")
  let authorEmail = argText(args, "authorEmail")
  var arguments = @["commit", "-m", message]
  if authorName.len > 0 and authorEmail.len > 0:
    arguments.add "--author=" & authorName & " <" & authorEmail & ">"
  discard gitText git(repository, arguments)
  let head = gitText git(repository, @["rev-parse", "HEAD"])
  replyOk(encodeVcsCommit(VcsCommit(id: head.strip(), subject: message)))

proc hVcsInitRepository(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let path = argText(args, "path")
  discard gitText git(path, @["init", "-q"])
  replyNothing()

proc hVcsFetch(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let repository = argText(args, "repository")
  let remote = argText(args, "remote")
  discard gitText git(repository, @["fetch", remote])
  replyNothing()

proc hVcsPush(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let repository = argText(args, "repository")
  let remote = argText(args, "remote")
  let refspec = argText(args, "refspec")
  discard gitText git(repository, @["push", remote, refspec])
  replyNothing()

# ---------------------------------------------------------------------------
# Settings.
# ---------------------------------------------------------------------------

proc scopeDirectory(ep: FacadeEndpoint; scope: SettingsScope): string =
  case scope
  of ssUser: joinPath(ep.settingsRoot, "user")
  of ssWorkspace: joinPath(ep.settingsRoot, "workspace")
  of ssSession: joinPath(ep.settingsRoot, "session")

proc keyFileName(key: string): string =
  ## The key is a flat NAME, never a path fragment — `desktop_native`'s rule,
  ## and it is load-bearing here for a reason it is not there: this key arrives
  ## over a socket that §6.6 says authenticates nothing, so a key containing
  ## `..` would be a write anywhere the container process can reach.
  var safe = ""
  for c in key:
    safe.add(if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}: c else: '_')
  safe & ".txt"

proc hSettingsGet(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let scope = decodeSettingsScope(jrequire(args, "scope"))
  let key = argText(args, "key")
  let path = joinPath(ep.scopeDirectory(scope), keyFileName(key))
  let a = attempt(proc(): JsObject = nfs.readFileSync(cstring path, cstring"utf8"))
  if not a.ok:
    if errorKindForNodeCode(a.code) == pkNotFound:
      return replyErr(pkNotFound, "no setting named " & key)
    return replyFromNode("read setting", key, a)
  replyOk(encodeText($(a.value.to(cstring))))

proc hSettingsSet(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let scope = decodeSettingsScope(jrequire(args, "scope"))
  let key = argText(args, "key")
  let value = argText(args, "value")
  let directory = ep.scopeDirectory(scope)
  let made = attempt(proc(): JsObject =
    nfs.mkdirSync(cstring directory, js{recursive: true}))
  if not made.ok: return replyFromNode("create the settings directory", directory, made)
  let path = joinPath(directory, keyFileName(key))
  let written = attempt(proc(): JsObject =
    nfs.writeFileSync(cstring path, cstring value, cstring"utf8"))
  if not written.ok: return replyFromNode("write setting", key, written)
  replyNothing()

proc hSettingsDelete(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let scope = decodeSettingsScope(jrequire(args, "scope"))
  let key = argText(args, "key")
  let path = joinPath(ep.scopeDirectory(scope), keyFileName(key))
  let a = attempt(proc(): JsObject = nfs.rmSync(cstring path, js{force: true}))
  # `force: true` makes a delete of something absent a success, which is what
  # `desktop_native` does: a caller deleting a setting wants it gone, and it is
  # gone.
  if not a.ok: return replyFromNode("delete setting", key, a)
  replyNothing()

proc hSettingsKeys(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let scope = decodeSettingsScope(jrequire(args, "scope"))
  let prefix = argText(args, "prefix")
  let directory = ep.scopeDirectory(scope)
  let a = attempt(proc(): JsObject = nfs.readdirSync(cstring directory))
  if not a.ok:
    if errorKindForNodeCode(a.code) == pkNotFound:
      return replyOk(encodeTextSeq(@[]))
    return replyFromNode("list settings in", directory, a)
  let raw = a.value
  let length = raw["length"].to(int)
  var found: seq[string] = @[]
  for i in 0 ..< length:
    let name = $(raw[i].to(cstring))
    if not name.endsWith(".txt"): continue
    let key = name[0 ..< name.len - 4]
    if prefix.len == 0 or key.startsWith(prefix):
      found.add key
  replyOk(encodeTextSeq(found))

proc hSettingsEnvironment(ep: FacadeEndpoint; args: JsonNode): VerbReply =
  let name = argText(args, "name")
  if not envIsSet(name):
    return replyErr(pkNotFound, name & " is not set")
  replyOk(encodeText(envValue(name)))

# ---------------------------------------------------------------------------
# The table.
# ---------------------------------------------------------------------------

type
  VerbHandler* = proc(ep: FacadeEndpoint; args: JsonNode): VerbReply {.closure.}

  FacadeVerb* = object
    verb*: string
      ## The dotted name `container_platform.nim` sends. §6.2 fixes the
      ## vocabulary and this side does not get to spell it differently.
    serves*: CapabilitySet
      ## THE CAPABILITIES THIS VERB IS EVIDENCE FOR — the only input to the
      ## advertised profile.
      ##
      ## Read it as "if this verb is refused, these capabilities are withdrawn
      ## from `welcome.profile`". That is why `fs.watch` is evidence for
      ## `capFilesystemWatch` and NOT for `capFilesystemArbitraryPaths`:
      ## thirteen implemented filesystem verbs already resolve any absolute
      ## path they are given, and withdrawing that on account of a missing
      ## watcher would understate what this endpoint does.
    handler*: VerbHandler
      ## `nil` means DECLARED AND REFUSED — the verb exists in the contract,
      ## this endpoint answers `pkNotSupported` for it by name, and everything
      ## in `serves` is withdrawn from the profile.
    unservedBecause*: string
      ## Why, in the refusal. A `pkNotSupported` that says only "not
      ## supported" sends whoever is reading the log to this file; one that
      ## says which thing is missing does not.

proc served(verb: string; serves: CapabilitySet;
            handler: VerbHandler): FacadeVerb =
  FacadeVerb(verb: verb, serves: serves, handler: handler)

proc refused(verb: string; serves: CapabilitySet;
             because: string): FacadeVerb =
  FacadeVerb(verb: verb, serves: serves, handler: nil, unservedBecause: because)

const
  NoClientEventRegistry =
    "this endpoint serves no streaming verb: §6.2's `event` frames have no " &
    "client-side registry yet, so a handle minted here could never be " &
    "delivered against"
  BelongsToTheTab =
    "the browser tab owns this, not the container process: a clipboard, a " &
    "file chooser, a download and a window frame are all the page's, and a " &
    "container endpoint that answered would be answering for something it " &
    "cannot see"
  NoKeychain =
    "the container has no user keychain (containerProfile says so); " &
    "credentials reach the deployment as short-lived, per-request grants"

let facadeVerbs*: seq[FacadeVerb] = @[
  # -- filesystem ---------------------------------------------------------
  served("fs.readText", {capFilesystemRead, capFilesystemArbitraryPaths}, hFsReadText),
  served("fs.readBytes", {capFilesystemRead, capFilesystemArbitraryPaths}, hFsReadBytes),
  served("fs.writeText", {capFilesystemWrite, capFilesystemArbitraryPaths}, hFsWriteText),
  served("fs.writeBytes", {capFilesystemWrite, capFilesystemArbitraryPaths}, hFsWriteBytes),
  served("fs.appendText", {capFilesystemWrite, capFilesystemArbitraryPaths}, hFsAppendText),
  served("fs.stat", {capFilesystemRead, capFilesystemArbitraryPaths}, hFsStat),
  served("fs.listDir", {capFilesystemRead, capFilesystemArbitraryPaths}, hFsListDir),
  served("fs.createDir", {capFilesystemWrite, capFilesystemArbitraryPaths}, hFsCreateDir),
  served("fs.remove", {capFilesystemWrite, capFilesystemArbitraryPaths}, hFsRemove),
  served("fs.copy", {capFilesystemWrite, capFilesystemArbitraryPaths}, hFsCopy),
  served("fs.move", {capFilesystemWrite, capFilesystemArbitraryPaths}, hFsMove),
  served("fs.realPath", {capFilesystemRead, capFilesystemArbitraryPaths}, hFsRealPath),
  served("fs.makeTempDir", {capFilesystemTemp}, hFsMakeTempDir),
  refused("fs.watch", {capFilesystemWatch}, NoClientEventRegistry),
  refused("fs.unwatch", {capFilesystemWatch}, NoClientEventRegistry),
  served("fs.certificateStoreRoots", {capFilesystemRead}, hFsCertificateStoreRoots),

  # -- process ------------------------------------------------------------
  #
  # `run` is the bounded form and it is what `capProcessSpawn` means —
  # "launch *something* and get output and an exit status back"
  # (capabilities.nim). The four verbs reachable only from a STARTED child are
  # refused together with `start` itself, because a handle nobody can receive
  # events against is worse than a refusal.
  served("process.run", {capProcessSpawn, capProcessArbitraryPrograms}, hProcessRun),
  served("process.which", {capProcessArbitraryPrograms}, hProcessWhich),
  refused("process.start", {}, NoClientEventRegistry),
  refused("process.signal", {capProcessSignal, capProcessGracefulSignal},
          NoClientEventRegistry),
  refused("process.writeStdin", {capProcessInteractiveStdin}, NoClientEventRegistry),
  refused("process.closeStdin", {capProcessInteractiveStdin}, NoClientEventRegistry),
  refused("process.isRunning", {}, NoClientEventRegistry),

  # -- version control ----------------------------------------------------
  served("vcs.isRepository", {capVcsRead}, hVcsIsRepository),
  served("vcs.repositoryRoot", {capVcsRead}, hVcsRepositoryRoot),
  served("vcs.status", {capVcsRead}, hVcsStatus),
  served("vcs.log", {capVcsRead}, hVcsLog),
  served("vcs.readBlob", {capVcsRead}, hVcsReadBlob),
  served("vcs.readBlobAt", {capVcsRead}, hVcsReadBlobAt),
  served("vcs.diff", {capVcsRead}, hVcsDiff),
  # REQUIRES capVcsRead, and WRITES: computing a content id stores loose,
  # content-addressed blob and tree objects in the repository's `.git/objects`
  # (that is how git computes a tree id), and nothing else — no ref, no index,
  # no working-tree file. A read in the facade's sense; see `vcs.contentId`.
  served("vcs.contentId", ContentIdRequires, hVcsContentId),
  served("vcs.stage", {capVcsWrite}, hVcsStage),
  served("vcs.unstage", {capVcsWrite}, hVcsUnstage),
  served("vcs.discardChanges", {capVcsWrite}, hVcsDiscardChanges),
  served("vcs.applyPatch", {capVcsWrite}, hVcsApplyPatch),
  served("vcs.commit", {capVcsWrite}, hVcsCommit),
  served("vcs.initRepository", {capVcsWrite}, hVcsInitRepository),
  served("vcs.fetch", {capVcsRemote}, hVcsFetch),
  served("vcs.push", {capVcsRemote}, hVcsPush),

  # -- settings -----------------------------------------------------------
  served("settings.get", {capSettingsRead}, hSettingsGet),
  served("settings.set", {capSettingsWrite}, hSettingsSet),
  served("settings.delete", {capSettingsWrite}, hSettingsDelete),
  served("settings.keys", {capSettingsRead}, hSettingsKeys),
  served("settings.environment", {capSettingsRead}, hSettingsEnvironment),
  refused("settings.getSecret", {capSecretStore}, NoKeychain),
  refused("settings.setSecret", {capSecretStore}, NoKeychain),
  refused("settings.deleteSecret", {capSecretStore}, NoKeychain),

  # -- clipboard, download, shell -----------------------------------------
  #
  # ALL of these are the tab's. `containerProfile` claims several of them
  # because the DEPLOYMENT has them — the tab is part of the deployment — but
  # the endpoint is the container process and it does not, so the computed
  # profile withdraws them. That gap is real and is recorded rather than
  # papered over: serving them needs the client to answer some verbs locally
  # instead of sending them, which `container_platform.nim` does not do today.
  refused("clipboard.writeText", {capClipboardWrite}, BelongsToTheTab),
  refused("clipboard.readText", {capClipboardRead}, BelongsToTheTab),
  refused("clipboard.writeHtml", {capClipboardWrite}, BelongsToTheTab),
  refused("download.offerFile", {capDownloadFile}, BelongsToTheTab),
  refused("download.offerText", {capDownloadFile}, BelongsToTheTab),
  refused("download.openFileDialog", {capOpenFileDialog}, BelongsToTheTab),
  refused("download.saveFileDialog", {capSaveFileDialog}, BelongsToTheTab),
  refused("download.pickDirectory", {capDirectoryPicker}, BelongsToTheTab),
  refused("shell.openExternalUrl", {capOpenExternalUrl}, BelongsToTheTab),
  refused("shell.revealInFileManager", {capRevealInFileManager}, BelongsToTheTab),
  refused("shell.windowState", {}, BelongsToTheTab),
  refused("shell.minimizeWindow", {capWindowControls}, BelongsToTheTab),
  refused("shell.toggleMaximizeWindow", {capWindowControls}, BelongsToTheTab),
  refused("shell.closeWindow", {capWindowControls}, BelongsToTheTab),
  refused("shell.setFullscreen", {capWindowFullscreen}, BelongsToTheTab),
  refused("shell.openSessionWindow", {capMultiWindow}, BelongsToTheTab)]

proc findVerb*(verb: string): int =
  ## The index of `verb` in the table, or -1. A linear scan over sixty-three
  ## entries, once per call frame, against a filesystem or a subprocess on the
  ## other side of it: a hash table here would be optimising the wrong end.
  for i, entry in facadeVerbs:
    if entry.verb == verb: return i
  -1

# ---------------------------------------------------------------------------
# §6.3 — the profile, computed.
# ---------------------------------------------------------------------------

proc servedCapabilities*(table: seq[FacadeVerb] = facadeVerbs): CapabilitySet =
  ## A capability is served when the table has evidence for it and owes nothing
  ## against it: at least one implemented verb declares it, and NO refused verb
  ## does.
  ##
  ## The second half is the important one. "At least one implemented verb"
  ## alone would advertise `capFilesystemWrite` off `fs.writeText` while
  ## `fs.copy` refused — a capability that answers "may I" with yes and the
  ## call with `pkNotSupported`, which is precisely the disagreement
  ## `capabilities.nim` exists to prevent.
  ##
  ## **The table is a PARAMETER so that the second half can be tested at all.**
  ## No capability in `facadeVerbs` today is claimed by both a served and a
  ## refused verb, so with the shipping table the subtraction is inert and a
  ## suite reading only `servedCapabilities()` would be asserting nothing about
  ## it — a guard that cannot fail, which is the shape this repository has
  ## learned to distrust. A suite can now hand in a table with that overlap and
  ## watch the capability go.
  var evidenced: CapabilitySet = {}
  var owed: CapabilitySet = {}
  for entry in table:
    if entry.handler.isNil: owed = owed + entry.serves
    else: evidenced = evidenced + entry.serves
  evidenced - owed

proc withdrawnBehaviour(capability: PlatformCapability): string =
  ## What the user gets instead, for each capability the table withdraws from
  ## `containerProfile`.
  ##
  ## Returns "" for anything not listed, and `servedProfile` then adds NO rule
  ## — which makes `undeclaredDegradations(servedProfile())` a real assertion
  ## rather than one that cannot fail. A `case` with an `else` returning
  ## boilerplate would satisfy the check for every capability forever, which is
  ## the shape of guard this repository has learned to distrust.
  case capability
  of capFilesystemWatch:
    "nothing tells this page when a file changes underneath it, so a file " &
    "you edit elsewhere is picked up the next time it is opened"
  of capProcessSignal:
    "a command here runs to completion or to its own timeout; there is no " &
    "Stop button, because there is no handle to stop"
  of capProcessGracefulSignal:
    "a command cannot be asked to stop cooperatively, so nothing here " &
    "offers to interrupt one"
  of capProcessInteractiveStdin:
    "a command's input has to be given before it starts. Nothing can be " &
    "typed into a run that is already going"
  of capProcessTerminal:
    "output appears in a scrolling pane rather than a terminal. Colours " &
    "survive; full-screen terminal programs do not"
  of capClipboardWrite:
    "copying is your browser's own, from the page. There is no Copy item here"
  of capDownloadFile:
    "write the file into the project instead; the container has nowhere to " &
    "hand a download to"
  of capOpenFileDialog, capSaveFileDialog, capDirectoryPicker:
    "no chooser can be shown from the container; pick the entry in the " &
    "project tree, or type the path"
  of capOpenExternalUrl:
    "links are opened by your browser from the page rather than by the " &
    "container"
  of capWindowFullscreen:
    "your browser owns the window, so full screen is its own control rather " &
    "than one drawn here"
  of capShareLink:
    "this session's link is the one you were given; the container publishes " &
    "no new one"
  else: ""

proc servedProfile*(table: seq[FacadeVerb] = facadeVerbs): PlatformProfile =
  ## `containerProfile` is the CEILING and the table is the FLOOR.
  ##
  ## Intersecting keeps the deployment class's declaration authoritative about
  ## what a container may claim — a table that grew evidence for something
  ## `containerProfile` does not have would not smuggle it into the wire — and
  ## keeps the table authoritative about what this build actually answers.
  result = containerProfile
  result.displayName = "container (ct host endpoint)"
  result.capabilities = containerProfile.capabilities * servedCapabilities(table)
  # `containerProfile`'s own rules are all for capabilities it LACKS, and this
  # profile lacks a superset of those, so none of them goes stale here.
  result.degradations = containerProfile.degradations
  for capability in containerProfile.capabilities - result.capabilities:
    let behaviour = withdrawnBehaviour(capability)
    if behaviour.len > 0:
      result.degradations.add DegradationRule(
        capability: capability, behaviour: behaviour)

const
  ServedContractMin* = 1
  ServedContractMax* = EndpointContractVersion
    ## §6.5's inclusive range. One version today; the constant is the bundle's
    ## own, so a build that moves the contract moves the server's ceiling with
    ## it and cannot answer `welcome` with a range it does not implement.

proc welcomeFrame*(ep: FacadeEndpoint; session = ""): WelcomeFrame =
  ## `session` is ECHOED, never chosen here. The client names the conversation
  ## it is opening and this endpoint answers the one it was asked about; a
  ## server that assigned the name instead would have to be consulted before a
  ## client could address anything, and a client driving several sessions would
  ## have no way to tell two welcomes apart until after it had acted on one.
  var profile = servedProfile()
  # Narrowed to what this endpoint was GRANTED, so the welcome never
  # advertises a capability `dispatch` would then refuse.
  for capability in profile.capabilities - ep.granted:
    profile.capabilities.excl capability
    profile.degradations.add DegradationRule(capability: capability,
      behaviour: "this deployment does not grant it, so every verb that " &
                 "needs it is refused")
  WelcomeFrame(
    session: session,
    contractMin: ServedContractMin,
    contractMax: ServedContractMax,
    profile: profile,
    deployment: ep.deployment)

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------

proc dispatch*(ep: FacadeEndpoint; call: CallFrame): ReplyFrame =
  ## One `call` frame in, one `reply` frame out. The `(session, id)` PAIR is
  ## copied back and nothing else correlates them.
  ##
  ## §6.2 says `id`, and that was complete while a connection carried one
  ## conversation. It does not survive several: ids are allocated per client
  ## from 1, so a reply carrying only an `id` can be claimed by a client that
  ## is waiting on that number in a DIFFERENT session — which completes the
  ## wrong call with the right-looking payload. Echoing the session is this
  ## side's whole part in preventing that, and it is unconditional: an empty
  ## session echoes as empty, which is the single-session wire unchanged.
  # NO `result.id = ...` / `result.session = ...` HERE. Every path below either
  # `return`s a fresh `ReplyFrame` or falls into the final `if`, which builds
  # one -- so an assignment to `result` at the top is dead on all of them. It
  # was dead for `id` before the session was added, and reading as though it
  # set a default is exactly how a path that forgot to copy the pair would look
  # correct. Each literal carries both, and the suite checks them on the
  # refusal paths too.
  let index = findVerb(call.verb)
  if index < 0:
    # A verb this endpoint has never heard of. `pkNotSupported` by name, with a
    # message that is DISTINCT from the declared-but-refused one below: the two
    # are different faults — one is a client speaking a vocabulary this build
    # does not have, the other is this build choosing not to serve a verb it
    # knows about — and a suite that cannot tell them apart cannot notice a
    # verb missing from the table.
    return ReplyFrame(
      session: call.session, id: call.id, ok: false, errorKind: pkNotSupported,
      errorMessage: "this endpoint declares no verb named '" & call.verb & "'")

  let entry = facadeVerbs[index]
  if entry.handler.isNil:
    return ReplyFrame(
      session: call.session, id: call.id, ok: false, errorKind: pkNotSupported,
      errorMessage: entry.verb & " is declared by the contract and not " &
        "served here: " & entry.unservedBecause)

  let ungranted = entry.serves - ep.granted
  if ungranted.len > 0:
    # Declared and implemented, but this endpoint was not granted what it
    # needs. Named, so the caller can tell "this deployment withholds
    # capVcsRead" from "this build does not have the verb".
    var names: seq[string] = @[]
    for capability in ungranted: names.add $capability
    return ReplyFrame(
      session: call.session, id: call.id, ok: false, errorKind: pkNotSupported,
      errorMessage: entry.verb & " requires " & names.join(", ") &
        ", which this endpoint was not granted")

  var reply: VerbReply
  try:
    reply = entry.handler(ep, if call.args.isNil: newJObject() else: call.args)
  except ProtocolError as err:
    # The client sent a field this build cannot read — a missing name, a
    # string where a number belongs, an enum value from another version.
    return ReplyFrame(
      session: call.session, id: call.id, ok: false, errorKind: pkInvalidArgument,
      errorMessage: entry.verb & ": " & err.msg)
  except CatchableError as err:
    return ReplyFrame(
      session: call.session, id: call.id, ok: false, errorKind: pkFailed,
      errorMessage: entry.verb & " failed: " & err.msg)
  except:
    # THE BARE `except:` IS DELIBERATE, for `endpoint_protocol`'s measured
    # reason: on the JS backend a throw from V8 or from a node binding is not
    # a Nim exception type, so `except CatchableError` catches nothing and the
    # exception escapes — here, out of a socket handler, taking the connection
    # with it. A dispatcher must answer even when a handler misbehaves.
    return ReplyFrame(
      session: call.session, id: call.id, ok: false, errorKind: pkFailed,
      errorMessage: entry.verb & " failed: " & getCurrentExceptionMsg())

  if reply.ok:
    ReplyFrame(session: call.session, id: call.id, ok: true,
               payload: if reply.payload.isNil: newJNull() else: reply.payload)
  else:
    ReplyFrame(session: call.session, id: call.id, ok: false,
               errorKind: reply.errorKind,
               errorMessage: reply.errorMessage, detail: reply.detail)

proc handleFrame*(ep: FacadeEndpoint; text: string): string =
  ## Frame text in, frame text out; "" when the text is not a frame this
  ## endpoint owns.
  ##
  ## §6.1 puts the facade and the existing index IPC surface on ONE connection,
  ## distinguished by frame kind rather than by port. So a message that is not
  ## a `hello` or a `call` is not an error here — it is somebody else's — and
  ## answering "" rather than raising is what lets the two share the socket.
  ##
  ## `hello` is always answered with `welcome`, whatever version it named:
  ## §6.5 puts the refusal in the CLIENT, because the stale artefact is the
  ## client, and a server that refused instead would leave the page with
  ## nothing to name the two numbers from.
  case frameKind(text)
  of FrameHello:
    var hello: HelloFrame
    try:
      hello = decodeHello(text)
    except ProtocolError:
      return ""
    encodeWelcome(ep.welcomeFrame(hello.session))
  of FrameCall:
    var call: CallFrame
    try:
      call = decodeCall(text)
    except ProtocolError:
      # There is no `id` to answer under, so there is no reply to send. A
      # `reply` with a made-up id would be answered by whichever call happened
      # to own that number.
      return ""
    encodeReply(ep.dispatch(call))
  else:
    ""
