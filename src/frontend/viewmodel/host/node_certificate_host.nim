## node's answers to the two questions the certificate facts ask of a host:
## "run git for the content-id recipe" and "where is the local certificate
## store".
##
## Shared by the two JS hosts that have node underneath them — the Electron
## renderer (`desktop_electron.nim`) and the container endpoint
## (`index/facade_endpoint.nim`, which runs in `ct host` and in the Electron
## main process) — so both drive `ct_test/certificate_content_id` and
## `ct_test/certificate_store_roots` with one binding to node rather than two.
## The native equivalents are `ct_test/certificate_content_id_native` and
## `ct_test/certificate_store_roots_native`.
##
## Host-side by design, like everything in `viewmodel/host/`: it reaches
## `require('child_process')`, `require('fs')` and `process`.
##
## ## Two git runners, one outcome mapping
##
## `nodeContentIdHost` runs git through `spawnSync`, which blocks the calling
## thread for the whole round trip. That is right for the container endpoint,
## whose verbs are answered one at a time, and wrong for the Electron
## renderer, whose thread is the UI: each certificate-indicator refresh froze
## input and redraw for up to 1.2 s (Status-Bar.md, "A refresh never stalls
## the window"). `nodeAsyncContentIdHost` runs the same commands through
## `child_process.spawn` and answers when the child closes, and
## `certificate_content_id.runResumable` drives the one recipe over it. Both
## runners fold node's outcomes into a `GitReply` through `replyOf`, so a
## launch error, a signal and an over-long output mean the same thing on both.
##
## FAILURES ARE VALUES. Every node call that can throw is caught here — with a
## bare `except:` where Nim code calls node, because on the JS backend a typed
## arm does not catch a node `Error` (see `desktop_electron.jsGuard`) — and
## turned into the `GitReply` / `HostFileResult` the recipe reads. Nothing
## escapes to a caller.

when not defined(js):
  {.error: "node_certificate_host.nim is the node host; native builds use " &
           "ct_test/certificate_content_id_native.nim".}

import std/[jsffi, strutils]

import ../../../ct_test/certificate_content_id
import ../../../ct_test/certificate_store_roots

export certificate_content_id.ContentIdHost,
       certificate_content_id.AsyncContentIdHost,
       certificate_content_id.AsyncContentGitRunner,
       certificate_content_id.GitCall, certificate_content_id.GitReply
export certificate_store_roots.CertificateStoreRoots,
       certificate_store_roots.StoreRootPlatform,
       certificate_store_roots.StoreEnvironment

{.emit: """
// One spawn, every outcome as a plain record: node's `spawnSync` reports a
// failed launch, a timeout and an over-long output through `error`, and can
// still THROW for an invalid argument, so both are folded in here.
function ctContentIdSpawn(argv, cwd, extraEnv, maxBuffer) {
  try {
    var env = Object.assign({}, process.env);
    for (var i = 0; i < extraEnv.length; i++) {
      env[extraEnv[i][0]] = extraEnv[i][1];
    }
    var options = {env: env, maxBuffer: maxBuffer, windowsHide: true};
    if (cwd) { options.cwd = cwd; }
    var r = require('child_process').spawnSync(argv[0], argv.slice(1), options);
    return {
      status: (r.status === null || r.status === undefined) ? -1 : r.status,
      signal: r.signal ? String(r.signal) : "",
      stdout: r.stdout || null,
      stderr: r.stderr || null,
      errorCode: r.error ? String(r.error.code || "") : "",
      errorMessage: r.error ? String(r.error.message || r.error) : ""
    };
  } catch (e) {
    return {status: -1, signal: "", stdout: null, stderr: null,
            errorCode: String((e && e.code) || ""),
            errorMessage: String((e && e.message) || e)};
  }
}

// The same command through `spawn`: the child runs while the event loop goes
// on, and `done` receives a record of the SAME shape `ctContentIdSpawn`
// returns, so one Nim mapping (`replyOf`) reads both. The differences from
// `spawnSync` that this has to reproduce by hand:
//
//  * a failed launch (ENOENT for a missing git, a missing working directory)
//    arrives as an `error` event — and node may emit `close` after it, so
//    `done` is guarded to run exactly once;
//  * there is no `maxBuffer`: output is counted as it arrives and, past the
//    bound, the child is killed and the record carries ENOBUFS, which is
//    what `spawnSync` reports for the same condition (an answer that LOOKS
//    complete and is not);
//  * stdin is `ignore` (/dev/null): `spawnSync` with no `input` gives the
//    child an empty pipe, and EOF on either is the same to git.
//
// https://nodejs.org/api/child_process.html#child_processspawncommand-args-options
// https://nodejs.org/api/child_process.html#event-close
function ctContentIdSpawnAsync(argv, cwd, extraEnv, maxBuffer, done) {
  var finished = false;
  function finish(record) {
    if (finished) { return; }
    finished = true;
    done(record);
  }
  function failure(e) {
    return {status: -1, signal: "", stdout: null, stderr: null,
            errorCode: String((e && e.code) || ""),
            errorMessage: String((e && e.message) || e)};
  }
  try {
    var env = Object.assign({}, process.env);
    for (var i = 0; i < extraEnv.length; i++) {
      env[extraEnv[i][0]] = extraEnv[i][1];
    }
    var options = {env: env, windowsHide: true,
                   stdio: ['ignore', 'pipe', 'pipe']};
    if (cwd) { options.cwd = cwd; }
    var child = require('child_process').spawn(argv[0], argv.slice(1), options);
    var chunks = {stdout: [], stderr: []};
    var sizes = {stdout: 0, stderr: 0};
    var overflowed = false;
    function collect(stream) {
      return function(chunk) {
        if (overflowed) { return; }
        sizes[stream] += chunk.length;
        if (sizes[stream] > maxBuffer) {
          overflowed = true;
          try { child.kill(); } catch (e) {}
          return;
        }
        chunks[stream].push(chunk);
      };
    }
    child.stdout.on('data', collect('stdout'));
    child.stderr.on('data', collect('stderr'));
    child.on('error', function(e) { finish(failure(e)); });
    child.on('close', function(code, signal) {
      finish({
        status: (code === null || code === undefined) ? -1 : code,
        signal: signal ? String(signal) : "",
        stdout: Buffer.concat(chunks.stdout),
        stderr: Buffer.concat(chunks.stderr),
        errorCode: overflowed ? "ENOBUFS" : "",
        errorMessage: overflowed ? ("output exceeded " + maxBuffer + " bytes") : ""
      });
    });
  } catch (e) {
    // `spawn` throws synchronously for an invalid argument. Reported through
    // `done` like every other outcome (inline, which the caller accepts).
    finish(failure(e));
  }
}
""".}

proc ctContentIdSpawn(argv: seq[cstring]; cwd: cstring;
                      extraEnv: seq[seq[cstring]]; maxBuffer: int): JsObject
  {.importjs: "ctContentIdSpawn(#, #, #, #)".}
proc nodeMkdtemp(stem: cstring): cstring
  {.importjs: "require('fs').mkdtempSync(#)".}
proc nodeTmpdir(): cstring {.importjs: "require('os').tmpdir()".}
proc nodePathJoin(a, b: cstring): cstring {.importjs: "require('path').join(#, #)".}
proc nodeExists(path: cstring): bool {.importjs: "require('fs').existsSync(#)".}
proc nodeCopyFile(source, destination: cstring)
  {.importjs: "require('fs').copyFileSync(#, #)".}
proc nodeUtimes(path: cstring; accessed, modified: float)
  {.importjs: "require('fs').utimesSync(#, #, #)".}
proc nodeLstat(path: cstring) {.importjs: "require('fs').lstatSync(#)".}
proc nodeRemoveTree(path: cstring)
  {.importjs: "require('fs').rmSync(#, { recursive: true, force: true })".}
proc nodeEnvRaw(name: cstring): JsObject {.importjs: "process.env[#]".}
proc nodeOsName(): cstring {.importjs: "(process.platform)@".}
proc nodeUidRaw(): JsObject
  {.importjs: "((typeof process.getuid === 'function') ? String(process.getuid()) : '')@".}
proc isNullish(value: JsObject): bool {.importjs: "((#) == null)".}

const NodeContentIdCaptureLimit* = 256 * 1024 * 1024
  ## The per-stream bound, the native host's (`ContentIdCaptureLimit`) for the
  ## same reason: `manifest-v1-sha256` reads every blob through `git
  ## cat-file`, and a cut output must FAIL the computation, never digest a
  ## prefix.

proc ctContentIdSpawnAsync(argv: seq[cstring]; cwd: cstring;
                           extraEnv: seq[seq[cstring]]; maxBuffer: int;
                           done: proc(raw: JsObject))
  {.importjs: "ctContentIdSpawnAsync(#, #, #, #, #)".}

proc bytesOf(buffer: JsObject): string =
  ## A node `Buffer` as the bytes it holds. Not `toString('utf8')`: a blob
  ## read for `manifest-v1-sha256` is arbitrary bytes, and a UTF-8 decode
  ## would replace every invalid sequence and change the digest.
  ##
  ## ONE NATIVE COPY, NOT A LOOP. On the JS backend a Nim `string` IS a plain
  ## JavaScript array of byte values (0..255) — checked against the compiler
  ## this repository builds with (Nim 2.3.1, 2026-10-22: a `string` literal
  ## compiles to `[104, 195, 169, ...]`, `Array.isArray` is true, and `len`,
  ## indexing and `add` work on an array built by `Array.from(buffer)`). So
  ## `Array.from` over the `Uint8Array` IS the conversion, byte for byte. The
  ## loop it replaces crossed `jsffi` twice per byte, which on a
  ## `manifest-v1-sha256` blob read was itself main-thread work proportional
  ## to the repository's size.
  if isNullish(buffer):
    return ""
  {.emit: "`result` = Array.from(`buffer`);".}

proc replyOf(raw: JsObject): GitReply =
  ## A spawn record — `ctContentIdSpawn`'s or `ctContentIdSpawnAsync`'s —
  ## as the recipe's `GitReply`. One mapping for both runners, so "git could
  ## not be launched", "git was killed" and "the output was cut" mean the same
  ## thing whichever ran it.
  let errorCode = $(raw["errorCode"].to(cstring))
  let errorMessage = $(raw["errorMessage"].to(cstring))
  let status = raw["status"].to(int)
  let signal = $(raw["signal"].to(cstring))
  if errorCode == "ENOBUFS":
    # node cut the output at `maxBuffer` (or the async runner killed the
    # child past it): an answer that LOOKS complete and is not, which the
    # recipe must treat as a failure.
    return GitReply(exitCode: (if status >= 0: status else: 1),
                    stdout: bytesOf(raw["stdout"]),
                    stderr: bytesOf(raw["stderr"]), complete: false)
  if errorCode == "ETIMEDOUT":
    return GitReply(exitCode: 1, stderr: errorMessage, complete: false)
  if errorCode.len > 0 or (status < 0 and signal.len == 0):
    # Never launched: ENOENT for a missing git, or a missing working
    # directory. Negative is the recipe's "could not be launched".
    return GitReply(exitCode: -1, stderr: errorMessage, complete: true)
  if signal.len > 0:
    return GitReply(exitCode: -1,
                    stderr: "git was terminated by signal " & signal,
                    complete: true)
  GitReply(exitCode: status, stdout: bytesOf(raw["stdout"]),
           stderr: bytesOf(raw["stderr"]), complete: true)

proc spawnArguments(call: GitCall): tuple[argv: seq[cstring];
                                          env: seq[seq[cstring]]] =
  for a in call.argv:
    result.argv.add cstring(a)
  for (key, value) in call.env:
    result.env.add @[cstring(key), cstring(value)]

proc nodeGitRunner(captureLimit: int): ContentGitRunner =
  result = proc(call: GitCall): GitReply {.closure, gcsafe.} =
    let (argv, env) = spawnArguments(call)
    replyOf(ctContentIdSpawn(argv, cstring(call.cwd), env, captureLimit))

proc nodeAsyncGitRunner*(captureLimit = NodeContentIdCaptureLimit):
    AsyncContentGitRunner =
  ## Git through `child_process.spawn`: the reply arrives on a later turn of
  ## the event loop, and the calling thread runs on meanwhile. Exported for
  ## the one other git read the certificate indicator makes —
  ## `desktop_electron`'s `vcs.repositoryRoot` — so that it, too, never
  ## blocks the renderer.
  ##
  ## `done` is called exactly once. It is called INLINE only when node
  ## throws synchronously inside `spawn` (an invalid argument), which
  ## `runResumable` accepts; every launched child answers later.
  result = proc(call: GitCall; done: proc(reply: GitReply) {.closure, gcsafe.})
               {.closure, gcsafe.} =
    let (argv, env) = spawnArguments(call)
    var answered = false
    try:
      ctContentIdSpawnAsync(argv, cstring(call.cwd), env, captureLimit,
        proc(raw: JsObject) =
          if answered:
            return
          answered = true
          done(replyOf(raw)))
    except:
      # The emitted function catches everything itself; this arm is for a
      # lapse in it, and keeps "failures are values" true regardless.
      if not answered:
        answered = true
        done(GitReply(exitCode: -1, stderr: getCurrentExceptionMsg(),
                      complete: true))

proc nodeFileOperations(tempRoot: string): ContentIdHost =
  ## The recipe's file operations through node's synchronous `fs`, with
  ## temporary indexes in fresh directories under `tempRoot` (default:
  ## `os.tmpdir()`, read when each is made), outside every repository.
  ## Shared by both hosts below; `git` is left for each to fill in.
  ##
  ## Synchronous on purpose, also in the asynchronous host: one `mkdtemp`,
  ## one copy of the index and one `utimes` per computation are not the cost
  ## the renderer was paying, and `runResumable` needs them answered inline.
  let root = tempRoot
  ContentIdHost(
    makeTempDir: proc(): HostFileResult {.closure, gcsafe.} =
      let base = if root.len > 0: cstring(root) else: nodeTmpdir()
      try:
        HostFileResult(ok: true,
          path: $nodeMkdtemp(nodePathJoin(base, cstring"ct-content-id-")))
      except:
        HostFileResult(error: getCurrentExceptionMsg()),
    copyFile: proc(source, destination: string): HostFileResult {.closure, gcsafe.} =
      try:
        if not nodeExists(cstring(source)):
          return HostFileResult(missing: true)
        nodeCopyFile(cstring(source), cstring(destination))
        HostFileResult(ok: true)
      except:
        HostFileResult(error: getCurrentExceptionMsg()),
    setModificationTime: proc(path: string; unixSeconds: int64): HostFileResult
                             {.closure, gcsafe.} =
      # `utimesSync` takes seconds; access and modification time alike (git
      # reads only the modification time).
      try:
        nodeUtimes(cstring(path), float(unixSeconds), float(unixSeconds))
        HostFileResult(ok: true)
      except:
        HostFileResult(error: getCurrentExceptionMsg()),
    pathExists: proc(path: string): bool {.closure, gcsafe.} =
      # `lstat`, not `existsSync`: a dangling symlink is present in the
      # working tree although `existsSync` follows it and says no.
      try:
        nodeLstat(cstring(path))
        true
      except:
        false,
    removeDir: proc(path: string) {.closure, gcsafe.} =
      if path.len > 0:
        try:
          nodeRemoveTree(cstring(path))
        except:
          # Litter, not a wrong answer; the id has already been decided.
          discard)

proc nodeContentIdHost*(tempRoot = "";
                        captureLimit = NodeContentIdCaptureLimit): ContentIdHost =
  ## A host running git through node's `spawnSync`, with its temporary
  ## indexes in fresh directories under `tempRoot` (default: `os.tmpdir()`),
  ## outside every repository. It BLOCKS the calling thread for every git
  ## call: right for the container endpoint, wrong for a UI thread — which
  ## uses `nodeAsyncContentIdHost`.
  result = nodeFileOperations(tempRoot)
  result.git = nodeGitRunner(captureLimit)

proc nodeAsyncContentIdHost*(tempRoot = "";
                             captureLimit = NodeContentIdCaptureLimit):
    AsyncContentIdHost =
  ## The same host with git through `child_process.spawn`, for
  ## `certificate_content_id.runResumable` (via `vcs.contentIdOverAsync`):
  ## the Electron renderer's, whose main thread must not wait for git.
  asyncContentIdHost(nodeFileOperations(tempRoot), nodeAsyncGitRunner(captureLimit))

# ---------------------------------------------------------------------------
# The account the system root is partitioned by (Transport §2.1)
# ---------------------------------------------------------------------------
#
# POSIX: `process.getuid()`. Windows: node has no binding to the process
# token, and `process.getuid` does not exist there, so the SID is asked of
# `whoami /user /fo csv /nh` — the token user's SID, the same account the
# native host reads with `GetTokenInformation(TokenUser)` through the
# reference library (`certificate_store_roots_native`). Without it the
# system root, `%ProgramData%\test-certificates\<SID>`, stays unresolved,
# which makes every lookup incomplete and the indicator *Unverifiable*
# whenever nothing in the user root covers the working tree.
# https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/whoami

type
  AccountCommandRunner* = proc(argv: seq[string]): GitReply {.closure.}
    ## Runs one command to completion and answers with its exit status and
    ## output, in the recipe's `GitReply` shape (negative exit status: it could
    ## not be launched). The seam the suite replaces to answer for a Windows
    ## host on any host (`node_certificate_store_account_test.nim`).

const WhoamiOutputLimit = 64 * 1024
  ## `whoami /user` prints one short line; a bound keeps a misbehaving
  ## program from filling the renderer's memory.

proc windowsSidFromWhoami*(output: string): tuple[sid, problem: string] =
  ## The SID in `whoami /user /fo csv /nh`'s answer: one CSV line,
  ## `"<domain>\<user>","<SID>"`. The SID is the LAST field (a user name may
  ## itself contain a comma, inside its quotes; a SID never does). Anything
  ## that is not exactly one such line holding a valid string SID is a
  ## problem, never a guess: a wrong account would name another user's
  ## partition of the system root.
  var lines: seq[string] = @[]
  for raw in output.splitLines():
    let line = raw.strip()
    if line.len > 0:
      lines.add line
  if lines.len != 1:
    return ("", "`whoami /user` printed " & $lines.len &
      " non-empty lines, not the one CSV line expected")
  let line = lines[0]
  let separator = line.rfind("\",\"")
  if not line.endsWith("\"") or separator < 0:
    return ("", "`whoami /user` printed `" & line &
      "`, not a CSV line of a user and a SID")
  let sid = line[separator + 3 ..< line.len - 1]
  if not isValidAccount(srpWindows, sid):
    return ("", "`whoami /user` printed `" & sid & "`, which is not a SID")
  (sid, "")

proc storeAccountFor*(platform: StoreRootPlatform; uid: string;
                      env: StoreEnvironment;
                      run: AccountCommandRunner): tuple[account, problem: string] =
  ## The account to partition the system root by on `platform`: `uid` on
  ## POSIX systems, the token user's SID on Windows (via `run`). Pure in its
  ## inputs, so the suite can drive the Windows branch on any host.
  case platform
  of srpUnix, srpMacos:
    if uid.len == 0:
      return ("", "the process's uid could not be read")
    (uid, "")
  of srpWindows:
    # `%SystemRoot%\System32\whoami.exe` rather than a `PATH` lookup, so a
    # `whoami` earlier on `PATH` cannot answer for the account.
    var systemRoot = env("SystemRoot")
    if systemRoot.len == 0:
      systemRoot = env("windir")
    if systemRoot.len == 0:
      return ("", "neither %SystemRoot% nor %windir% is set, so " &
        "`whoami.exe` could not be found to read the account's SID")
    let whoami = systemRoot.strip(leading = false, chars = {'\\', '/'}) &
      "\\System32\\whoami.exe"
    let reply = run(@[whoami, "/user", "/fo", "csv", "/nh"])
    if reply.exitCode < 0:
      return ("", "`" & whoami & "` could not be run: " & reply.stderr.strip())
    if not reply.complete:
      return ("", "`" & whoami & " /user`'s output was cut short")
    if reply.exitCode != 0:
      return ("", "`" & whoami & " /user` failed (exit status " &
        $reply.exitCode & "): " & reply.stderr.strip())
    let parsed = windowsSidFromWhoami(reply.stdout)
    if parsed.problem.len > 0:
      return ("", parsed.problem)
    (parsed.sid, "")

proc nodeAccountRunner(): AccountCommandRunner =
  result = proc(argv: seq[string]): GitReply {.closure.} =
    var args: seq[cstring] = @[]
    for a in argv:
      args.add cstring(a)
    replyOf(ctContentIdSpawn(args, cstring(""), @[], WhoamiOutputLimit))

var nodeWindowsSid = ""
  ## The token user's SID, once read: an account does not change for the
  ## life of a process, and `whoami` is a process launch the renderer should
  ## not repeat on every refresh. A failure is NOT remembered, so a transient
  ## one is retried on the next refresh.

proc rootsForAccount*(platform: StoreRootPlatform; env: StoreEnvironment;
                     account: tuple[account, problem: string]):
    CertificateStoreRoots =
  ## Both roots for `platform`, `env` and the account `storeAccountFor` read,
  ## with the reason when it could not be read.
  result = resolveCertificateStoreRoots(platform, env, account.account)
  if account.problem.len > 0:
    result.problems.add "the account's " &
      (if platform == srpWindows: "SID" else: "uid") &
      " could not be read: " & account.problem

proc nodeCertificateStoreRoots*(): CertificateStoreRoots =
  ## Both store roots as this node process resolves them now (Transport
  ## §2.1): its `process.env`, `process.platform`, and its account —
  ## `process.getuid()` on POSIX, the token user's SID on Windows (read once,
  ## see `nodeWindowsSid`). Everything else is read on every call, so a
  ## changed variable is seen by the next one.
  var uid = ""
  try:
    uid = $(nodeUidRaw().to(cstring))
  except:
    uid = ""
  let platform = storeRootPlatformFor($nodeOsName())
  let env = proc(name: string): string =
    let raw = nodeEnvRaw(cstring(name))
    if isNullish(raw): "" else: $(raw.to(cstring))
  if platform == srpWindows and nodeWindowsSid.len > 0:
    return resolveCertificateStoreRoots(platform, env, nodeWindowsSid)
  let account = storeAccountFor(platform, uid, env, nodeAccountRunner())
  if platform == srpWindows and account.problem.len == 0:
    nodeWindowsSid = account.account
  rootsForAccount(platform, env, account)
