## WHAT A DEPLOYMENT TELLS THE BUNDLE ABOUT ITSELF.
##
## `Architecture/UI-Bundle-And-Endpoints.md` §7. The bundle is one immutable
## artifact across desktop, web and `ct host`; everything that differs between
## deployments, and everything that differs between sessions, arrives here.
##
## ## Why this exists at all
##
## §2 measured the defect it removes: `ct host` serves its front end from a
## template interpolated per session — `views/server_index.ejs` writes the
## socket port and parameters into the document — so **every session
## re-downloads the whole UI because two fields in it differ**. Once nothing
## session-specific is in the entry document, the document is byte-identical for
## every session of a build, which is the precondition for caching it at all.
##
## The same move is already half-built on the web side and its own source asks
## for the other half — `web_deployment.nim`, on the four bundled assets: *"The
## right long-term answer is to digest them, which needs their URLs moved out of
## the entry-document template and into the deployment descriptor."* A URL
## compiled into the bundle cannot carry a digest of the bundle, which is why
## this move comes before digesting rather than after.
##
## ## HALF OF THIS ALREADY EXISTS, and this module is the other half
##
## §7 as first drafted said the descriptor was missing. It is not.
## `web_deployment.DeploymentDescriptor` — rendered by
## `renderDeploymentDescriptor`, read back by `parseDeploymentDescriptor`,
## published at `/build-id.txt` — already carries the build's identity and its
## `modules[].url` and `assets[]`, and `PublishedAsset`'s own comment is §7.2's
## argument word for word: *"a constant cannot name a file whose name depends
## on its bytes"*.
##
## **The two halves have different cache lives, and that is why they are two
## documents rather than one.** The build half changes when a build is
## deployed and can be cached with the bundle. What is here — which trace,
## which project, which socket — changes every session and cannot. Folding them
## together would make the build identity uncacheable, which is the defect §2
## measured, arriving from the other direction.
##
## So this module does NOT carry an asset list. Asking for a URL is the build
## descriptor's job and it already answers. What remains of §7.2 is extending
## that indirection to the four `damBundled` assets, whose URLs are still Nim
## constants — and `web_deployment.nim` asks for that itself, in the comment on
## `bundledAssetPaths`.
##
## ## One document, two deliveries — §7.3
##
## The container gets it in the `welcome` frame, because the socket is already
## open and a second round trip before first paint is a second round trip. The
## web has no such socket before the bundle runs, so it fetches a small mutable
## pointer — which is `Static-Site-Architecture.md` §2.9's
## immutable-artifact-plus-mutable-pointer structure, unchanged. A deployment
## that needed a different SHAPE would be a UI variant arriving through
## configuration, which §4 forbids as firmly as one arriving through packaging.

import std/[json, strutils]

import ./web_deployment

export web_deployment

type
  DescriptorError* = object of CatchableError
    ## Raised rather than returned. A descriptor that cannot be read means the
    ## bundle does not know what to load or where to connect, and a caller that
    ## forgot to check a result code would proceed against defaults it never
    ## chose — which for `ProjectRuntimeKind` is the difference between serving
    ## a static page and allocating a container.

  ProjectRuntimeKind* = enum
    prkStatic
      ## The static bundle serves this project. **FIRST, so it is the zero
      ## value**, and that is deliberate: a project that declares nothing is
      ## static, which is what keeps the anonymous path and
      ## `ci/test/noir-studio-signed-out.sh` untouched. A default that meant
      ## "allocate" would turn every unconfigured project into a container.
    prkSession
      ## A substrate-allocated session runs this project's backend.

  ProjectRuntime* = object
    ## §3.1's half of the allocation request that belongs to the PROJECT rather
    ## than to the principal: which image, at which flavour. The tenancy tuple
    ## is the caller's and is not carried here.
    kind*: ProjectRuntimeKind
    imageRef*: string
    flavour*: string

  SessionCoordinates* = object
    ## Which trace, and where in it. Changes every session, which is why it is
    ## not in the entry document.
    traceId*: string
    projectId*: string
    runtime*: ProjectRuntime

  ConnectionParameters* = object
    ## The two fields `views/server_index.ejs` interpolates today, and the
    ## reason the served page is uncacheable.
    frontendSocketPort*: int
    frontendSocketParameters*: string
    backendSocketPort*: int

  SessionDescriptor* = object
    ## The per-SESSION half of §7's descriptor. Named for what it carries
    ## rather than for the section, because `DeploymentDescriptor` is taken —
    ## by the per-build half, which is the older and the more literally named
    ## of the two.
    session*: SessionCoordinates
    connection*: ConnectionParameters

func runtimeKindName*(k: ProjectRuntimeKind): string = $k

proc parseRuntimeKind*(name: string): ProjectRuntimeKind =
  ## An unknown kind RAISES. The two values decide whether a container is
  ## allocated, so a name this build does not know must not fall back to either
  ## — `prkStatic` would silently deny a project its backend and `prkSession`
  ## would allocate for one that never asked.
  for k in ProjectRuntimeKind:
    if $k == name: return k
  raise newException(DescriptorError,
    "'" & name & "' is not a project runtime kind this bundle knows")

# ---------------------------------------------------------------------------
# Encoding.
# ---------------------------------------------------------------------------
proc encodeRuntime*(r: ProjectRuntime): JsonNode =
  result = %*{"kind": runtimeKindName(r.kind)}
  # The image and the flavour are written ONLY for a session runtime. A static
  # project carrying an image reference would be a statement nothing acts on,
  # and the next reader would reasonably wonder which of the two fields decided.
  if r.kind == prkSession:
    result["imageRef"] = %r.imageRef
    result["flavour"] = %r.flavour

proc encodeDescriptor*(d: SessionDescriptor): JsonNode =
  result = %*{
    "session": %*{
      "traceId": d.session.traceId,
      "projectId": d.session.projectId,
      "runtime": encodeRuntime(d.session.runtime)},
    "connection": %*{
      "frontendSocketPort": d.connection.frontendSocketPort,
      "frontendSocketParameters": d.connection.frontendSocketParameters,
      "backendSocketPort": d.connection.backendSocketPort}}

# ---------------------------------------------------------------------------
# Decoding.
# ---------------------------------------------------------------------------
proc reqStr(n: JsonNode; key: string): string =
  let f = if n.isNil: nil else: n{key}
  if f.isNil or f.kind != JString:
    raise newException(DescriptorError,
      "the descriptor has no string '" & key & "'")
  f.getStr

proc optStr(n: JsonNode; key: string): string =
  let f = if n.isNil: nil else: n{key}
  if f.isNil or f.kind != JString: "" else: f.getStr

proc optInt(n: JsonNode; key: string): int =
  let f = if n.isNil: nil else: n{key}
  if f.isNil or f.kind != JInt: 0 else: f.getInt

proc decodeRuntime*(n: JsonNode): ProjectRuntime =
  ## An ABSENT runtime is `prkStatic`. That is the default §7 and
  ## `Hosted-Session-Allocation.md` §3.1a both name, and it is why this does
  ## not raise on a missing object: the overwhelming majority of projects
  ## declare nothing, and requiring the field would make the descriptor's
  ## producer write "static" everywhere to say nothing.
  if n.isNil or n.kind != JObject:
    return ProjectRuntime(kind: prkStatic)
  result.kind = parseRuntimeKind(reqStr(n, "kind"))
  if result.kind == prkStatic:
    return
  result.imageRef = optStr(n, "imageRef")
  result.flavour = optStr(n, "flavour")
  # A SESSION RUNTIME WITH NO IMAGE IS REFUSED, and this is the assertion worth
  # having in the whole module. §3.1: a reference the substrate does not hold is
  # refused with `unknown_image` rather than quietly served from the base image,
  # *"a session started from the wrong environment looks healthy everywhere
  # except in the user's editor"*. An EMPTY reference is that same failure one
  # step earlier — it reaches the substrate as "no preference" and gets the base
  # image, which is exactly what the refusal exists to prevent.
  if result.imageRef.len == 0:
    raise newException(DescriptorError,
      "this project declares a session runtime with no image reference; an " &
      "empty reference allocates from the substrate's own base image, which " &
      "is the wrong environment presented as a working one")

proc decodeDescriptor*(text: string): SessionDescriptor =
  var node: JsonNode
  try:
    node = parseJson(text)
  except:
    # THE BARE `except:` IS DELIBERATE and is the measured one every parser in
    # this tree carries: on the C backend `parseJson` raises `JsonParsingError`,
    # a `CatchableError`; on the JS backend it defers to V8's `JSON.parse`,
    # which throws a raw `SyntaxError` that no Nim exception type matches — so
    # the narrow form catches nothing there and the exception escapes into the
    # renderer. This decodes bytes that arrive over a socket.
    raise newException(DescriptorError, "the descriptor is not JSON")
  if node.kind != JObject:
    raise newException(DescriptorError, "the descriptor is not a JSON object")

  let session = node{"session"}
  result.session.traceId = optStr(session, "traceId")
  result.session.projectId = optStr(session, "projectId")
  result.session.runtime = decodeRuntime(
    if session.isNil: nil else: session{"runtime"})

  let connection = node{"connection"}
  result.connection.frontendSocketPort = optInt(connection,
                                                "frontendSocketPort")
  result.connection.frontendSocketParameters = optStr(
    connection, "frontendSocketParameters")
  result.connection.backendSocketPort = optInt(connection, "backendSocketPort")
