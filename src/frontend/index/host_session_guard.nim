## Admission control for `ct host`'s two listeners: the page server and the
## socket.io server that carries the index IPC surface.
##
## A hosted session is reachable by anything that can open a TCP connection to
## its address: other users of the same machine, and any web page the
## operator's browser opens, which can make the browser send requests to
## `127.0.0.1`. The socket carries filesystem reads, searches and process
## starts, so reaching it must take more than knowing the port.
##
## Two checks, applied to every request that starts a session:
##
## - **The session secret.** One random value per `ct host` run (32 bytes from
##   the operating system's CSPRNG, base64url), or the value a supervising
##   process put in `CODETRACER_HOST_SESSION_SECRET`. A client presents it as
##   the `ct_session` query parameter or the `X-CodeTracer-Session` header. It
##   is compared through SHA-256 digests with `crypto.timingSafeEqual`, so the
##   comparison takes the same time for every candidate of any length.
## - **The origin.** A request that carries an `Origin` header (every browser
##   sends one on a WebSocket and on a cross-origin request) must come from the
##   page this server serves, or from an origin the supervisor listed in
##   `CODETRACER_HOST_ALLOWED_ORIGINS` (a proxy in front of the server). A
##   request without one is a non-browser client or a same-origin navigation,
##   and the secret alone decides it.
##
## The secret is never written to a log. It leaves the process in one place
## only: the `CODETRACER_HOST_URL=` line on stdout, and only when this process
## generated it, because then that line is the only way the operator can learn
## it. A supplied secret is removed from the process environment as soon as it
## is read, so the replay and tool processes the index starts do not inherit it.
##
## Origins follow RFC 6454 as the WHATWG URL parser serializes them
## (https://url.spec.whatwg.org/#origin): scheme, lower-cased host, and the
## port only when it is not the scheme's default.

import std/[jsffi, strutils]

const
  SessionSecretEnv* = "CODETRACER_HOST_SESSION_SECRET"
    ## A supervisor's secret for this run; read once, then removed.
  AllowedOriginsEnv* = "CODETRACER_HOST_ALLOWED_ORIGINS"
    ## Extra page origins (comma or whitespace separated), for a proxy that
    ## serves the page under its own origin.
  SessionQueryParam* = "ct_session"
  SessionHeader* = "x-codetracer-session"
  MinSecretLen* = 32
    ## base64url characters: 192 bits. A generated secret has 43 (256 bits).
  MaxSecretLen* = 512

type
  HostSessionGuard* = ref object
    secret: cstring           # kept only to build the printed URL
    digest: JsObject          # SHA-256 of the secret, a Buffer
    supplied*: bool           # true when a supervisor provided the secret
    extraOrigins: seq[string] # from AllowedOriginsEnv, normalized
    pageOrigins: seq[string]  # the page server's own, once its port is known

  HostSessionError* = object of CatchableError

proc envValue(name: cstring): JsObject {.importjs: "process.env[#]".}
proc envDelete(name: cstring) {.importjs: "(delete process.env[#])".}
proc generatedSecret(): cstring {.importjs:
  "require('crypto').randomBytes(32).toString('base64url')".}
proc sha256Digest(value: cstring): JsObject {.importjs:
  "require('crypto').createHash('sha256').update(#, 'utf8').digest()".}
proc digestsEqual(a, b: JsObject): bool {.importjs:
  "require('crypto').timingSafeEqual(#, #)".}

proc serializedOrigin(text: cstring): cstring {.importjs: """(function (text) {
  // The origin of an `http(s)` URL that names nothing but an origin (an
  // optional trailing `/`), or "" for anything else: another scheme, user
  // information, a path, a query or a fragment.
  try {
    var u = new URL(text);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    if (u.username !== '' || u.password !== '') return '';
    if (u.pathname !== '/' || u.search !== '' || u.hash !== '') return '';
    return u.origin;
  } catch (e) {
    return '';
  }
})(#)""".}

proc headerText(request: JsObject; name: cstring): cstring {.importjs: """(function (req, name) {
  var v = req && req.headers ? req.headers[name] : undefined;
  if (Array.isArray(v)) return v.length === 1 ? String(v[0]) : '';
  return typeof v === 'string' ? v : '';
})(#, #)""".}

proc queryText(request: JsObject; name: cstring): cstring {.importjs: """(function (req, name) {
  try {
    var all = new URL(req.url, 'http://ct-host.invalid').searchParams.getAll(name);
    return all.length === 1 ? all[0] : '';
  } catch (e) {
    return '';
  }
})(#, #)""".}

proc hasHeader(request: JsObject; name: cstring): bool {.importjs: """(function (req, name) {
  return !!(req && req.headers) && req.headers[name] !== undefined;
})(#, #)""".}

proc localAddresses(): seq[cstring] {.importjs: """(function () {
  var os = require('os'), out = [], all = os.networkInterfaces();
  Object.keys(all).forEach(function (k) {
    (all[k] || []).forEach(function (a) { out.push(a.address); });
  });
  out.push(os.hostname());
  return out;
})()""".}

proc isValidSecret(value: string): bool =
  if value.len < MinSecretLen or value.len > MaxSecretLen:
    return false
  for c in value:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '-', '_'}:
      return false
  true

proc normalizeOrigin*(text: string): string =
  ## The serialized origin `text` names, or "" when it is not one.
  $serializedOrigin(text.cstring)

proc hostForUrl(host: string): string =
  if host.contains(':') and not host.startsWith("["): "[" & host & "]"
  else: host

proc isLoopbackHost(host: string): bool =
  host == "localhost" or host == "::1" or host == "[::1]" or host.startsWith("127.")

proc isWildcardHost(host: string): bool =
  host.len == 0 or host == "0.0.0.0" or host == "::" or host == "[::]"

proc pageOriginsFor*(bindAddress: string; port: int): seq[string] =
  ## The origins a browser shows for a page this server serves on `port`.
  ##
  ## A loopback bind is reached as `localhost`, `127.0.0.1` or `[::1]`; a
  ## wildcard bind additionally through each local interface address and the
  ## host name; any other bind through that address only. A page reached
  ## through some other name (a proxy, a port mapping, a DNS name) is listed by
  ## the supervisor in `CODETRACER_HOST_ALLOWED_ORIGINS`.
  var hosts: seq[string]
  let bindHost = bindAddress.strip()
  if isWildcardHost(bindHost):
    hosts.add ["localhost", "127.0.0.1", "::1"]
    for address in localAddresses():
      hosts.add $address
  elif isLoopbackHost(bindHost):
    hosts.add ["localhost", "127.0.0.1", "::1", bindHost]
  else:
    hosts.add bindHost
  for host in hosts:
    let origin = normalizeOrigin("http://" & hostForUrl(host) & ":" & $port)
    if origin.len > 0 and origin notin result:
      result.add origin

proc parseAllowedOrigins*(text: string): seq[string] =
  ## `CODETRACER_HOST_ALLOWED_ORIGINS`: origins separated by commas or
  ## whitespace. A value that is not an origin is an error, not a value to
  ## skip: an operator who wrote one expects it to be honoured.
  for part in text.split({',', ' ', '\t', '\n'}):
    if part.len == 0:
      continue
    let origin = normalizeOrigin(part)
    if origin.len == 0:
      raise newException(HostSessionError,
        AllowedOriginsEnv & ": not an http(s) origin: " & part)
    if origin notin result:
      result.add origin

proc newHostSessionGuard*(): HostSessionGuard =
  ## Reads (and removes) the supervisor's secret, or generates one; reads the
  ## extra origins. Raises `HostSessionError` for a supplied secret that is
  ## too short or not base64url, without quoting it.
  result = HostSessionGuard()
  let supplied = envValue(SessionSecretEnv.cstring)
  envDelete(SessionSecretEnv.cstring)
  if not supplied.isUndefined and not supplied.isNull and
      ($supplied.to(cstring)).len > 0:
    let value = $supplied.to(cstring)
    if not isValidSecret(value):
      raise newException(HostSessionError,
        SessionSecretEnv & " must be " & $MinSecretLen & " to " & $MaxSecretLen &
        " base64url characters (A-Z a-z 0-9 - _); the value given is not")
    result.secret = value.cstring
    result.supplied = true
  else:
    result.secret = generatedSecret()
  result.digest = sha256Digest(result.secret)
  let extra = envValue(AllowedOriginsEnv.cstring)
  if not extra.isUndefined and not extra.isNull:
    result.extraOrigins = parseAllowedOrigins($extra.to(cstring))

proc setPagePort*(guard: HostSessionGuard; bindAddress: string; port: int) =
  ## Called once the page server's port is known (with `--port 0` that is
  ## inside its listen callback). Until then no page origin is accepted.
  guard.pageOrigins = pageOriginsFor(bindAddress, port)

proc allowedOrigins*(guard: HostSessionGuard): seq[string] =
  result = guard.pageOrigins
  for origin in guard.extraOrigins:
    if origin notin result:
      result.add origin

proc originAllowed*(guard: HostSessionGuard; origin: string): bool =
  ## An `Origin` header value is accepted when it is exactly one of the
  ## allowed origins as serialized. `null` (an opaque origin) never is.
  origin in guard.allowedOrigins()

proc secretMatches*(guard: HostSessionGuard; candidate: string): bool =
  ## Constant-time with respect to the candidate: both sides are hashed to 32
  ## bytes before `timingSafeEqual`, so neither the length nor the content of
  ## the secret shows in the time taken.
  if candidate.len == 0:
    return false
  digestsEqual(sha256Digest(candidate.cstring), guard.digest)

proc presentedSecret*(request: JsObject): string =
  ## The secret a request presents: the `X-CodeTracer-Session` header, else
  ## the `ct_session` query parameter. A repeated header or parameter
  ## presents nothing.
  let header = $headerText(request, SessionHeader.cstring)
  if header.len > 0:
    return header
  $queryText(request, SessionQueryParam.cstring)

proc refusal*(guard: HostSessionGuard; request: JsObject): string =
  ## Why `request` may not start a session, or "" when it may. The reason
  ## never quotes the presented secret.
  if hasHeader(request, cstring"origin"):
    let origin = $headerText(request, cstring"origin")
    if not guard.originAllowed(origin):
      return "origin not allowed"
  if not guard.secretMatches(presentedSecret(request)):
    return "missing or wrong session secret"
  ""

proc sessionUrl*(guard: HostSessionGuard; bindAddress: string; port: int): string =
  ## The URL `ct host` prints. It carries the secret only when this process
  ## generated it: a supervisor that supplied the secret already holds it, and
  ## its log of our stdout should not.
  result = "http://" & bindAddress & ":" & $port
  if not guard.supplied:
    result.add "/?" & SessionQueryParam & "=" & $guard.secret
