## THE FACADE'S VALUE TYPES, ON THE WIRE.
##
## `endpoint_protocol.nim` carries the envelope — §6.2's four frame kinds and
## §6.5's version rule. This module carries what rides inside it: every value
## type a facade operation takes or returns, encoded to and from `JsonNode`.
##
## ## One module, both ends, on purpose
##
## The client encodes arguments and decodes payloads; the server does the
## reverse. Written once, those are the same functions read backwards, and
## written twice they are two places to disagree about whether a `FsStat`'s
## timestamp is seconds or milliseconds. Every codec here is used by both
## sides, so "the two ends agree" is a property of the build rather than of a
## review.
##
## ## Enums travel by NAME and an unknown one RAISES
##
## `endpoint_protocol.nim` keeps an unknown *capability* rather than raising,
## because a capability this build does not know is one it simply cannot use.
## A value enum is different: `vfsDeleted` decoded as `vfsUnmodified` would
## show a file as unchanged, and `psStderr` decoded as `psStdout` would put a
## compiler's diagnostics in the wrong stream. Within a negotiated contract
## version the two ends agree by construction, so an unrecognised name means
## something is wrong, and a value that is silently wrong is worse than a
## refusal that says so.
##
## ## Bytes are base64 — §6.2
##
## `fs.readBytes` and `fs.writeBytes` are the only binary verbs and their
## subject is source files. Trace data never crosses this channel; it goes over
## the replay path that already exists.
##
## ## The distinct handles stay opaque
##
## `FsWatchHandle` and `ProcessHandle` are `distinct string` precisely so the
## server can mint them and the client can only quote them back. They encode as
## the string they are, and nothing here interprets one.

import std/[base64, enumutils, json]

import ./fs
import ./process
import ./vcs
import ./settings
import ./download
import ./shell
import ./endpoint_protocol

export endpoint_protocol

# ---------------------------------------------------------------------------
# Field access. Missing OPTIONAL fields default; missing REQUIRED ones raise,
# for the reason `endpoint_protocol`'s `requireX` gives — a default would put a
# zero where the sender put nothing.
# ---------------------------------------------------------------------------
proc jstr*(n: JsonNode; key: string; default = ""): string =
  let f = n{key}
  if f.isNil or f.kind != JString: default else: f.getStr

proc jint*(n: JsonNode; key: string; default = 0): int =
  let f = n{key}
  if f.isNil or f.kind != JInt: default else: f.getInt

proc jint64*(n: JsonNode; key: string; default: int64 = 0): int64 =
  let f = n{key}
  if f.isNil or f.kind != JInt: default else: f.getBiggestInt

proc jbool*(n: JsonNode; key: string; default = false): bool =
  let f = n{key}
  if f.isNil or f.kind != JBool: default else: f.getBool

proc jrequire*(n: JsonNode; key: string): JsonNode =
  let f = if n.isNil: nil else: n{key}
  if f.isNil:
    raise newException(ProtocolError, "the payload has no '" & key & "'")
  f

proc jstrSeq*(n: JsonNode; key: string): seq[string] =
  for e in n{key}.getElems():
    if e.kind == JString: result.add e.getStr

proc jstrArray*(values: openArray[string]): JsonNode =
  result = newJArray()
  for v in values: result.add(%v)

# ---------------------------------------------------------------------------
# Enums. `$` yields the declared identifier, so there is no table to keep in
# step with the declaration.
# ---------------------------------------------------------------------------
template enumCodec(T: typedesc; encName, decName: untyped) =
  func encName*(v: T): JsonNode = %($v)
  func decName*(n: JsonNode): T =
    let text = if n.isNil or n.kind != JString: "" else: n.getStr
    for candidate in T:
      if $candidate == text: return candidate
    raise newException(ProtocolError,
      "'" & text & "' is not a value of " & $T)

enumCodec(FsEntryKind, encodeFsEntryKind, decodeFsEntryKind)
enumCodec(FsWatchEventKind, encodeFsWatchEventKind, decodeFsWatchEventKind)
enumCodec(ProcessStream, encodeProcessStream, decodeProcessStream)
enumCodec(ProcessSignal, encodeProcessSignal, decodeProcessSignal)
enumCodec(VcsFileStatus, encodeVcsFileStatus, decodeVcsFileStatus)
enumCodec(VcsBlobSource, encodeVcsBlobSource, decodeVcsBlobSource)
enumCodec(SettingsScope, encodeSettingsScope, decodeSettingsScope)
enumCodec(VcsContentIdKind, encodeVcsContentIdKind, decodeVcsContentIdKind)

# `NoContentIdCondition` carries a SENTENCE as its string value (it is the
# recipe's message text), so `$` would put prose on the wire. It travels by
# its identifier like every other enum here, through `symbolName`.
func encodeNoContentIdCondition*(v: NoContentIdCondition): JsonNode =
  %symbolName(v)

func decodeNoContentIdCondition*(n: JsonNode): NoContentIdCondition =
  let text = if n.isNil or n.kind != JString: "" else: n.getStr
  for candidate in NoContentIdCondition:
    if symbolName(candidate) == text: return candidate
  raise newException(ProtocolError,
    "'" & text & "' is not a value of NoContentIdCondition")

# ---------------------------------------------------------------------------
# Bytes.
# ---------------------------------------------------------------------------
func encodeBytes*(b: seq[byte]): JsonNode =
  var s = newString(b.len)
  for i, v in b: s[i] = char(v)
  %encode(s)

func decodeBytes*(n: JsonNode): seq[byte] =
  let text = if n.isNil or n.kind != JString: "" else: n.getStr
  var decoded: string
  try:
    decoded = base64.decode(text)
  except CatchableError:
    # base64 decoding is Nim's own, on both backends, and raises a
    # `ValueError` on both — so the narrow form is correct here, unlike around
    # `parseJson`, where the JS arm defers to V8.
    raise newException(ProtocolError, "the payload is not base64")
  result = newSeq[byte](decoded.len)
  for i, c in decoded: result[i] = byte(c)

# ---------------------------------------------------------------------------
# Filesystem.
# ---------------------------------------------------------------------------
func encodeCertificateStoreRoots*(v: CertificateStoreRoots): JsonNode =
  %*{"available": v.available, "user": v.user, "system": v.system,
     "problems": jstrArray(v.problems)}

proc decodeCertificateStoreRoots*(n: JsonNode): CertificateStoreRoots =
  # `available` is REQUIRED: defaulting it would turn a reply this build cannot
  # read into "there is no store here", which is an answer, not a refusal.
  let available = jrequire(n, "available")
  if available.kind != JBool:
    raise newException(ProtocolError, "'available' must be a boolean")
  CertificateStoreRoots(
    available: available.getBool,
    user: jstr(n, "user"), system: jstr(n, "system"),
    problems: jstrSeq(n, "problems"))

func encodeFsStat*(v: FsStat): JsonNode =
  %*{"kind": encodeFsEntryKind(v.kind), "size": v.size,
     "modifiedMs": v.modifiedMs, "readOnly": v.readOnly}

proc decodeFsStat*(n: JsonNode): FsStat =
  FsStat(kind: decodeFsEntryKind(jrequire(n, "kind")),
         size: jint64(n, "size"),
         modifiedMs: jint64(n, "modifiedMs"),
         readOnly: jbool(n, "readOnly"))

func encodeFsDirEntry*(v: FsDirEntry): JsonNode =
  %*{"name": v.name, "kind": encodeFsEntryKind(v.kind)}

proc decodeFsDirEntry*(n: JsonNode): FsDirEntry =
  FsDirEntry(name: jstr(n, "name"), kind: decodeFsEntryKind(jrequire(n, "kind")))

func encodeFsDirEntries*(v: seq[FsDirEntry]): JsonNode =
  result = newJArray()
  for e in v: result.add encodeFsDirEntry(e)

proc decodeFsDirEntries*(n: JsonNode): seq[FsDirEntry] =
  for e in n.getElems(): result.add decodeFsDirEntry(e)

func encodeFsWatchEvent*(v: FsWatchEvent): JsonNode =
  %*{"kind": encodeFsWatchEventKind(v.kind), "path": v.path,
     "previousPath": v.previousPath}

proc decodeFsWatchEvent*(n: JsonNode): FsWatchEvent =
  FsWatchEvent(kind: decodeFsWatchEventKind(jrequire(n, "kind")),
               path: jstr(n, "path"), previousPath: jstr(n, "previousPath"))

func encodeFsWatchHandle*(v: FsWatchHandle): JsonNode = %string(v)
proc decodeFsWatchHandle*(n: JsonNode): FsWatchHandle =
  FsWatchHandle(if n.isNil or n.kind != JString: "" else: n.getStr)

# ---------------------------------------------------------------------------
# Processes.
# ---------------------------------------------------------------------------
func encodeProcessHandle*(v: ProcessHandle): JsonNode = %string(v)
proc decodeProcessHandle*(n: JsonNode): ProcessHandle =
  ProcessHandle(if n.isNil or n.kind != JString: "" else: n.getStr)

func encodeProcessSpec*(v: ProcessSpec): JsonNode =
  result = %*{"command": v.command, "args": jstrArray(v.args),
              "workingDir": v.workingDir, "clearEnv": v.clearEnv,
              "stdinText": v.stdinText, "timeoutMs": v.timeoutMs,
              "env": newJArray()}
  for pair in v.env:
    result["env"].add(%*{"key": pair.key, "value": pair.value})

proc decodeProcessSpec*(n: JsonNode): ProcessSpec =
  result.command = jstr(n, "command")
  result.args = jstrSeq(n, "args")
  result.workingDir = jstr(n, "workingDir")
  result.clearEnv = jbool(n, "clearEnv")
  result.stdinText = jstr(n, "stdinText")
  result.timeoutMs = jint(n, "timeoutMs")
  for e in n{"env"}.getElems():
    result.env.add (key: jstr(e, "key"), value: jstr(e, "value"))

func encodeProcessExit*(v: ProcessExit): JsonNode =
  %*{"exitCode": v.exitCode, "signalled": v.signalled,
     "signalName": v.signalName}

proc decodeProcessExit*(n: JsonNode): ProcessExit =
  ProcessExit(exitCode: jint(n, "exitCode"), signalled: jbool(n, "signalled"),
              signalName: jstr(n, "signalName"))

func encodeProcessRunResult*(v: ProcessRunResult): JsonNode =
  %*{"exit": encodeProcessExit(v.exit), "stdout": v.stdout, "stderr": v.stderr}

proc decodeProcessRunResult*(n: JsonNode): ProcessRunResult =
  ProcessRunResult(exit: decodeProcessExit(jrequire(n, "exit")),
                   stdout: jstr(n, "stdout"), stderr: jstr(n, "stderr"))

func encodeProcessOutputChunk*(v: ProcessOutputChunk): JsonNode =
  %*{"stream": encodeProcessStream(v.stream), "text": v.text}

proc decodeProcessOutputChunk*(n: JsonNode): ProcessOutputChunk =
  ProcessOutputChunk(stream: decodeProcessStream(jrequire(n, "stream")),
                     text: jstr(n, "text"))

# ---------------------------------------------------------------------------
# Version control.
# ---------------------------------------------------------------------------
func encodeVcsContentId*(v: VcsContentId): JsonNode =
  result = %*{"kind": encodeVcsContentIdKind(v.kind), "id": v.id,
              "algorithm": v.algorithm, "reason": v.reason,
              "conditions": newJArray()}
  for state in v.conditions:
    result["conditions"].add %*{
      "condition": encodeNoContentIdCondition(state.condition),
      "paths": jstrArray(state.paths)}

proc decodeVcsContentId*(n: JsonNode): VcsContentId =
  result.kind = decodeVcsContentIdKind(jrequire(n, "kind"))
  result.id = jstr(n, "id")
  result.algorithm = jstr(n, "algorithm")
  result.reason = jstr(n, "reason")
  for e in n{"conditions"}.getElems():
    result.conditions.add NoContentIdState(
      condition: decodeNoContentIdCondition(jrequire(e, "condition")),
      paths: jstrSeq(e, "paths"))
  if result.kind == vcikComputed and result.id.len == 0:
    # A computed id with no id would read as "computed, and empty" — a value
    # no caller could tell from a match against an empty record field.
    raise newException(ProtocolError, "a computed content id carries no id")

func encodeVcsFileChange*(v: VcsFileChange): JsonNode =
  %*{"path": v.path, "previousPath": v.previousPath,
     "indexStatus": encodeVcsFileStatus(v.indexStatus),
     "workingTreeStatus": encodeVcsFileStatus(v.workingTreeStatus)}

proc decodeVcsFileChange*(n: JsonNode): VcsFileChange =
  VcsFileChange(path: jstr(n, "path"), previousPath: jstr(n, "previousPath"),
                indexStatus: decodeVcsFileStatus(jrequire(n, "indexStatus")),
                workingTreeStatus: decodeVcsFileStatus(
                  jrequire(n, "workingTreeStatus")))

func encodeVcsStatus*(v: VcsStatus): JsonNode =
  result = %*{"branch": v.branch, "upstream": v.upstream, "ahead": v.ahead,
              "behind": v.behind, "detached": v.detached,
              "changes": newJArray()}
  for c in v.changes: result["changes"].add encodeVcsFileChange(c)

proc decodeVcsStatus*(n: JsonNode): VcsStatus =
  result.branch = jstr(n, "branch")
  result.upstream = jstr(n, "upstream")
  result.ahead = jint(n, "ahead")
  result.behind = jint(n, "behind")
  result.detached = jbool(n, "detached")
  for e in n{"changes"}.getElems(): result.changes.add decodeVcsFileChange(e)

func encodeVcsCommit*(v: VcsCommit): JsonNode =
  %*{"id": v.id, "shortId": v.shortId, "parents": jstrArray(v.parents),
     "authorName": v.authorName, "authorEmail": v.authorEmail,
     "authoredAtMs": v.authoredAtMs, "subject": v.subject, "body": v.body}

proc decodeVcsCommit*(n: JsonNode): VcsCommit =
  VcsCommit(id: jstr(n, "id"), shortId: jstr(n, "shortId"),
            parents: jstrSeq(n, "parents"), authorName: jstr(n, "authorName"),
            authorEmail: jstr(n, "authorEmail"),
            authoredAtMs: jint64(n, "authoredAtMs"),
            subject: jstr(n, "subject"), body: jstr(n, "body"))

func encodeVcsCommits*(v: seq[VcsCommit]): JsonNode =
  result = newJArray()
  for c in v: result.add encodeVcsCommit(c)

proc decodeVcsCommits*(n: JsonNode): seq[VcsCommit] =
  for e in n.getElems(): result.add decodeVcsCommit(e)

# ---------------------------------------------------------------------------
# Dialogs.
# ---------------------------------------------------------------------------
func encodeFileFilter*(v: FileFilter): JsonNode =
  %*{"name": v.name, "extensions": jstrArray(v.extensions)}

proc decodeFileFilter*(n: JsonNode): FileFilter =
  FileFilter(name: jstr(n, "name"), extensions: jstrSeq(n, "extensions"))

func encodeFileFilters*(v: seq[FileFilter]): JsonNode =
  result = newJArray()
  for f in v: result.add encodeFileFilter(f)

proc decodeFileFilters*(n: JsonNode): seq[FileFilter] =
  for e in n.getElems(): result.add decodeFileFilter(e)

func encodeOpenDialogOptions*(v: OpenDialogOptions): JsonNode =
  %*{"title": v.title, "defaultPath": v.defaultPath,
     "filters": encodeFileFilters(v.filters),
     "allowMultiple": v.allowMultiple}

proc decodeOpenDialogOptions*(n: JsonNode): OpenDialogOptions =
  OpenDialogOptions(title: jstr(n, "title"),
                    defaultPath: jstr(n, "defaultPath"),
                    filters: decodeFileFilters(n{"filters"}),
                    allowMultiple: jbool(n, "allowMultiple"))

func encodeSaveDialogOptions*(v: SaveDialogOptions): JsonNode =
  %*{"title": v.title, "suggestedName": v.suggestedName,
     "defaultDirectory": v.defaultDirectory,
     "filters": encodeFileFilters(v.filters)}

proc decodeSaveDialogOptions*(n: JsonNode): SaveDialogOptions =
  SaveDialogOptions(title: jstr(n, "title"),
                    suggestedName: jstr(n, "suggestedName"),
                    defaultDirectory: jstr(n, "defaultDirectory"),
                    filters: decodeFileFilters(n{"filters"}))

# ---------------------------------------------------------------------------
# Window state.
# ---------------------------------------------------------------------------
func encodeWindowState*(v: WindowState): JsonNode =
  %*{"maximized": v.maximized, "minimized": v.minimized,
     "fullscreen": v.fullscreen, "focused": v.focused}

proc decodeWindowState*(n: JsonNode): WindowState =
  WindowState(maximized: jbool(n, "maximized"),
              minimized: jbool(n, "minimized"),
              fullscreen: jbool(n, "fullscreen"),
              focused: jbool(n, "focused"))

# ---------------------------------------------------------------------------
# Scalars, named so a call site reads the same on both ends.
# ---------------------------------------------------------------------------
func encodeText*(v: string): JsonNode = %v
proc decodeText*(n: JsonNode): string =
  if n.isNil or n.kind != JString: "" else: n.getStr

func encodeFlag*(v: bool): JsonNode = %v
proc decodeFlag*(n: JsonNode): bool =
  not n.isNil and n.kind == JBool and n.getBool

func encodeTextSeq*(v: seq[string]): JsonNode = jstrArray(v)
proc decodeTextSeq*(n: JsonNode): seq[string] =
  for e in n.getElems():
    if e.kind == JString: result.add e.getStr
