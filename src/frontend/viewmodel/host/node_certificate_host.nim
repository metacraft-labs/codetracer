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
## FAILURES ARE VALUES. Every node call that can throw is caught here — with a
## bare `except:` where Nim code calls node, because on the JS backend a typed
## arm does not catch a node `Error` (see `desktop_electron.jsGuard`) — and
## turned into the `GitReply` / `HostFileResult` the recipe reads. Nothing
## escapes to a caller.

when not defined(js):
  {.error: "node_certificate_host.nim is the node host; native builds use " &
           "ct_test/certificate_content_id_native.nim".}

import std/jsffi

import ../../../ct_test/certificate_content_id
import ../../../ct_test/certificate_store_roots

export certificate_content_id.ContentIdHost
export certificate_store_roots.CertificateStoreRoots

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

proc bytesOf(buffer: JsObject): string =
  ## A node `Buffer` as the bytes it holds. Not `toString('utf8')`: a blob
  ## read for `manifest-v1-sha256` is arbitrary bytes, and a UTF-8 decode
  ## would replace every invalid sequence and change the digest.
  if isNullish(buffer):
    return ""
  let length = buffer["length"].to(int)
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char(buffer[i].to(int))

proc nodeGitRunner(captureLimit: int): ContentGitRunner =
  result = proc(call: GitCall): GitReply {.closure, gcsafe.} =
    var argv: seq[cstring] = @[]
    for a in call.argv:
      argv.add cstring(a)
    var env: seq[seq[cstring]] = @[]
    for (key, value) in call.env:
      env.add @[cstring(key), cstring(value)]
    let raw = ctContentIdSpawn(argv, cstring(call.cwd), env, captureLimit)
    let errorCode = $(raw["errorCode"].to(cstring))
    let errorMessage = $(raw["errorMessage"].to(cstring))
    let status = raw["status"].to(int)
    let signal = $(raw["signal"].to(cstring))
    if errorCode == "ENOBUFS":
      # node cut the output at `maxBuffer`: an answer that LOOKS complete
      # and is not, which the recipe must treat as a failure.
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

proc nodeContentIdHost*(tempRoot = "";
                        captureLimit = NodeContentIdCaptureLimit): ContentIdHost =
  ## A host running git through node's `spawnSync`, with its temporary
  ## indexes in fresh directories under `tempRoot` (default: `os.tmpdir()`),
  ## outside every repository.
  let root = tempRoot
  ContentIdHost(
    git: nodeGitRunner(captureLimit),
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

proc nodeCertificateStoreRoots*(): CertificateStoreRoots =
  ## Both store roots as this node process resolves them now (Transport
  ## §2.1): its `process.env`, `process.platform` and `process.getuid()`.
  ## Read on every call, so a changed variable is seen by the next one.
  var uid = ""
  try:
    uid = $(nodeUidRaw().to(cstring))
  except:
    uid = ""
  resolveCertificateStoreRoots(
    storeRootPlatformFor($nodeOsName()),
    proc(name: string): string =
      let raw = nodeEnvRaw(cstring(name))
      if isNullish(raw): "" else: $(raw.to(cstring)),
    uid)
