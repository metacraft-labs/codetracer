## THE ONE MODULE IN `ct` THAT OPENS A SOCKET TO AN ISSUER.
##
## `viewmodel/identity/` is pure by design and says so in every header: it
## parses a discovery document, classifies a poll response and verifies a
## signature, and it must not be handed something that can fetch. `session.nim`
## gives the reason — *"a module that can await can be handed something that
## fetches, and this one must not be"* — and `device_grant.nim` repeats it for
## the polling loop. So the network lives here, outside that directory, and the
## pure modules are driven from `oidc.nim` next door.
##
## ## Why this is not in nim-everywhere
##
## `nim_everywhere/http.nim` already defines `HttpAsyncTransport`, implements
## it over `fetch` on the JS target, and on native returns a future that fails
## with *"native fetch transport is not attached"*. That sentence is an
## invitation, not a gap: the native arm is left to the consumer because the
## right client depends on the consumer's async backend, and nim-everywhere
## supports three (`asyncdispatch`, `chronos`, `none`). Attaching one there
## would decide chronos policy for every other consumer of that library.
##
## `ct` is `asyncdispatch`, so this attaches `std/asynchttpclient`.
##
## ## The CA file is a PARAMETER, and there is no environment variable
##
## A local issuer is served by a development CA that no system trust store
## carries, so a test run has to name that CA. It is a proc argument, threaded
## from the composition root, for the same reason `device_grant.selectFlow`
## takes a measurement and not a setting: an environment variable that changes
## which certificates are trusted is one line from one that trusts all of them,
## and the two are indistinguishable to a reviewer reading the call site.
## `ci/test/identity-no-escape-hatch.sh` asserts the identity modules read no
## environment; this module is held to the same rule by inspection, and
## `oidc_test.nim` asserts it mechanically.
##
## There is deliberately **no** "skip verification" argument. A caller that
## needs a private CA passes its certificate; a caller that wants no
## verification has to write that itself, in the open.

import std/[asyncdispatch, httpclient, net]
import nim_everywhere/http
import nim_everywhere/platform
import nim_everywhere/async_compat

const
  DefaultRequestTimeoutMs* = 20_000
    ## Long enough for a slow issuer, short enough that a device-grant poll
    ## cannot outlive its own interval. RFC 8628's default interval is 5s, so a
    ## request that hung for a minute would stack polls.

  TransportFailureStatus* = 599
    ## What `fetchHttp`'s JS arm answers when the fetch itself fails, reused
    ## here so that a caller distinguishing "the issuer said no" from "the
    ## issuer was not reached" reads the same number on both backends. It is
    ## outside the HTTP status space on purpose.

proc newSslContextOrNil(caFile: string): SslContext =
  ## A context pinned to one CA bundle, or `nil` to mean "the system store".
  ##
  ## `nil` is `std/asynchttpclient`'s own "use the default", so the ordinary
  ## production path adds nothing and a private CA is strictly additive.
  if caFile.len == 0:
    return nil
  newContext(verifyMode = CVerifyPeer, caFile = caFile)

func toStdMethod(m: platform.HttpMethod): httpclient.HttpMethod =
  ## nim-everywhere's four verbs onto `std/httpclient`'s enum. An exhaustive
  ## `case` rather than a name lookup, so adding a verb there is a compile
  ## error here rather than a runtime surprise.
  case m
  of hmGet: httpclient.HttpGet
  of hmPost: httpclient.HttpPost
  of hmPut: httpclient.HttpPut
  of hmDelete: httpclient.HttpDelete

proc performRequest(request: HttpRequest; caFile: string;
                    timeoutMs: int): Future[HttpResponse] {.async.} =
  ## ONE REQUEST, AND IT NEVER RAISES.
  ##
  ## Every failure — DNS, TLS, refused connection, timeout — comes back as a
  ## `TransportFailureStatus` response whose body names what went wrong. The
  ## callers are `oidc.nim`'s discovery and poll loops, and a raised exception
  ## there would have to be caught at every one of them or it would abort a
  ## polling loop that RFC 8628 requires to continue. `PlatformOutcome`'s
  ## header makes the same argument for the facade: errors cross a transport
  ## boundary as values.
  var headers = newHttpHeaders()
  for h in request.headers:
    headers[h.name] = h.value

  var client: AsyncHttpClient
  try:
    client = newAsyncHttpClient(sslContext = newSslContextOrNil(caFile),
                                headers = headers)
  except CatchableError as err:
    # Almost always the CA file: `newContext` raises when it cannot read it,
    # and a caller that mistyped the path should learn that rather than see a
    # connection error.
    return response(TransportFailureStatus,
      "the HTTP client could not be created: " & err.msg)

  try:
    let call = client.request(url = request.url,
                              httpMethod = toStdMethod(request.httpMethod),
                              body = request.body)
    if not await call.withTimeout(timeoutMs):
      return response(TransportFailureStatus,
        "no answer from " & request.url & " within " & $timeoutMs & "ms")
    let reply = call.read()
    var outHeaders: seq[HttpHeader]
    for name, value in reply.headers.pairs:
      outHeaders.add header(name, value)
    return response(reply.code.int, await reply.body, outHeaders)
  except CatchableError as err:
    return response(TransportFailureStatus,
      "the request to " & request.url & " failed: " & err.msg)
  finally:
    try: client.close()
    except CatchableError: discard

proc newIssuerHttpTransport*(caFile = ""; timeoutMs = DefaultRequestTimeoutMs
                            ): HttpAsyncTransport =
  ## The transport `oidc.nim` drives. `caFile` empty means the system trust
  ## store, which is what a production build passes.
  proc(request: HttpRequest): PlatformFuture[HttpResponse] =
    performRequest(request, caFile, timeoutMs)

func isTransportFailure*(reply: HttpResponse): bool =
  ## "The issuer was not reached", as distinct from "the issuer said no".
  ## `oidc.nim` reports the two differently, because a network fault during a
  ## device-grant poll is a reason to keep polling and a 400 is not.
  reply.status == TransportFailureStatus
