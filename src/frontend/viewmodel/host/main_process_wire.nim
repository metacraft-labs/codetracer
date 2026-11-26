## What the Electron renderer's facade asks the main process, on the wire.
##
## The certificate facts (content ids and declared scopes) are served by the
## main process. This module is the one spelling of their channels and
## messages, shared by the renderer (`desktop_electron.nim`), the main process
## (`index/content_id_service.nim`) and the content-id worker
## (`index/content_id_worker.nim`), so the ends cannot disagree.
##
## ## The certificate facts
##
## The status bar's certificate indicator asks for three content ids (W, H
## and S) and the repository's declared scopes on every refresh. Computing
## them reads every tracked file through git, so the desktop computes them in
## a node worker thread of the MAIN process (`index/content_id_service.nim`,
## `index/content_id_worker.nim`): neither the renderer's thread, which is
## the UI, nor main's event loop, which answers every other IPC request,
## waits for git. This module's half below is what crosses those two hops.
##
## A request names what to compute; an answer is a `PlatformOutcome` in JSON,
## its value in `endpoint_codec`'s encoding (the encoding `ct host`'s
## `vcs.contentId` already uses), and carries the request's `id` back.
##
## Failures are values on every hop. An answer that cannot be decoded is a
## `pkTransport` outcome, never a raise, so a caller always settles.

import std/json

import ../platform/outcome
import ../platform/vcs
import ../platform/endpoint_codec
import ../platform/endpoint_protocol

const
  ContentIdChannel* = "CODETRACER::content-id"
    ## Renderer -> main: `{id, request}`, `request` being `encodeRequest`'s
    ## JSON text for an `OpContentId` request.
  ContentIdReceivedChannel* = "CODETRACER::content-id-received"
    ## Main -> the renderer that asked: `{id, outcome}`, `outcome` being the
    ## outcome's JSON text.
  DeclaredScopesChannel* = "CODETRACER::declared-scopes"
    ## Renderer -> main: `{id, request}`, for an `OpDeclaredScopes` request.
  DeclaredScopesReceivedChannel* = "CODETRACER::declared-scopes-received"
    ## Main -> the renderer that asked: `{id, outcome}`.

  OpContentId* = "content-id"
  OpDeclaredScopes* = "declared-scopes"
    ## The `op` of a request to the worker.

type
  ContentIdRequest* = object
    ## One question for the worker. `op` is `OpContentId` or
    ## `OpDeclaredScopes`; the other fields are what that operation takes.
    op*: string
    repository*: string
    state*: VcsBlobSource
    algorithm*: string
    scope*: seq[string]

proc encodeRequest*(request: ContentIdRequest): JsonNode =
  result = %*{"op": request.op, "repository": request.repository}
  if request.op == OpContentId:
    result["state"] = encodeVcsBlobSource(request.state)
    result["algorithm"] = %request.algorithm
    result["scope"] = jstrArray(request.scope)

proc requestText*(request: ContentIdRequest): string =
  ## `encodeRequest` as the text a message carries.
  $encodeRequest(request)

proc decodeRequest*(node: JsonNode): ContentIdRequest =
  ## Raises `ProtocolError` (or a JSON error) for a malformed request; the
  ## worker answers that as a failure for the request's `id`.
  result.op = jstr(node, "op")
  result.repository = jstr(node, "repository")
  if result.op == OpContentId:
    result.state = decodeVcsBlobSource(jrequire(node, "state"))
    result.algorithm = jstr(node, "algorithm")
    result.scope = jstrSeq(node, "scope")
  elif result.op != OpDeclaredScopes:
    raise newException(ProtocolError, "unknown content-id operation `" &
      result.op & "`")

proc encodeOutcome*[T](outcome: PlatformOutcome[T];
                       encode: proc(value: T): JsonNode): JsonNode =
  if outcome.ok:
    %*{"ok": true, "value": encode(outcome.value)}
  else:
    %*{"ok": false, "kind": errorKindName(outcome.error.kind),
       "message": outcome.error.message, "detail": outcome.error.detail}

proc decodeOutcome*[T](node: JsonNode;
                       decode: proc(node: JsonNode): T): PlatformOutcome[T] =
  ## The outcome `encodeOutcome` wrote, or a `pkTransport` failure naming
  ## what was wrong with it.
  try:
    if node.isNil or node.kind != JObject:
      return failed[T](pkTransport, "the content-id answer is not an object")
    if jbool(node, "ok"):
      return succeeded(decode(jrequire(node, "value")))
    failed[T](parseErrorKind(jstr(node, "kind")), jstr(node, "message"),
              jstr(node, "detail"))
  except:
    # Bare: on the JS backend `JSON.parse` throws a JS `SyntaxError`,
    # which a typed arm re-throws.
    failed[T](pkTransport, "the content-id answer could not be read",
              getCurrentExceptionMsg())

proc encodeContentIdOutcome*(outcome: PlatformOutcome[VcsContentId]): string =
  $encodeOutcome(outcome, proc(value: VcsContentId): JsonNode =
    encodeVcsContentId(value))

proc decodeContentIdOutcome*(text: string): PlatformOutcome[VcsContentId] =
  var node: JsonNode = nil
  try:
    node = parseJson(text)
  except:
    # Bare: on the JS backend `JSON.parse` throws a JS `SyntaxError`,
    # which a typed arm re-throws.
    return failed[VcsContentId](pkTransport,
      "the content-id answer is not JSON", getCurrentExceptionMsg())
  decodeOutcome(node, proc(n: JsonNode): VcsContentId = decodeVcsContentId(n))

proc encodeDeclaredScopesOutcome*(
    outcome: PlatformOutcome[VcsDeclaredScopes]): string =
  $encodeOutcome(outcome, proc(value: VcsDeclaredScopes): JsonNode =
    encodeVcsDeclaredScopes(value))

proc decodeDeclaredScopesOutcome*(
    text: string): PlatformOutcome[VcsDeclaredScopes] =
  var node: JsonNode = nil
  try:
    node = parseJson(text)
  except:
    # Bare: on the JS backend `JSON.parse` throws a JS `SyntaxError`,
    # which a typed arm re-throws.
    return failed[VcsDeclaredScopes](pkTransport,
      "the declared-scopes answer is not JSON", getCurrentExceptionMsg())
  decodeOutcome(node, proc(n: JsonNode): VcsDeclaredScopes =
    decodeVcsDeclaredScopes(n))
