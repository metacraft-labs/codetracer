## host_session_guard_test.nim
##
## The pieces of `ct host`'s admission rule (`index/host_session_guard.nim`)
## that the end-to-end suite
## (`src/tests/ct_host/test_ct_host_socket_requires_session_secret_and_origin.nim`)
## cannot reach from outside one run: a supervisor's secret (accepted, removed
## from the environment, never printed, refused when weak without being
## quoted), the origin lists for each kind of bind address, and
## `CODETRACER_HOST_ALLOWED_ORIGINS`.
##
## What is real: the module's own code under node, with node's `crypto`, `os`
## and `URL`. Requests are plain objects with the two fields the guard reads
## (`headers`, `url`), the shape node's `http.IncomingMessage` has; the
## end-to-end suite sends real ones.
##
## Lane: `main-process` (`nim js -d:nodejs -d:ctIndex -d:server`).

import std/[unittest, jsffi, strutils]

import ../index/host_session_guard

# One line: `ci/lib/run-nim-test-lane.sh` reads this spelling as the runtime
# assertion count.
const ExpectedAssertions = 43

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc setEnv(key, value: cstring) {.importjs: "process.env[#] = #".}
proc unsetEnv(key: cstring) {.importjs: "(delete process.env[#])".}
proc envIsSet(key: cstring): bool {.importjs: "(process.env[#] !== undefined)".}
proc fakeRequest(url: cstring; headers: JsObject): JsObject {.importjs:
  "({ url: #, headers: # })".}

const Supplied = "supervisor-chosen-secret-0123456789-abcdefghij"

proc noHeaders(): JsObject = newJsObject()

proc headers(pairs: openArray[(string, string)]): JsObject =
  result = newJsObject()
  for (k, v) in pairs:
    result[k.cstring] = v.cstring

suite "ct host session secret":
  setup:
    unsetEnv(SessionSecretEnv.cstring)
    unsetEnv(AllowedOriginsEnv.cstring)

  test "a supplied secret is used, removed from the environment and not printed":
    setEnv(SessionSecretEnv.cstring, Supplied.cstring)
    let guard = newHostSessionGuard()
    ck guard.supplied
    ck not envIsSet(SessionSecretEnv.cstring)
    ck guard.secretMatches(Supplied)
    ck not guard.secretMatches(Supplied & "x")
    ck not guard.secretMatches("")
    ck guard.sessionUrl("127.0.0.1", 4000) == "http://127.0.0.1:4000"

  test "a generated secret is 256 bits of base64url, differs per run, and is printed":
    let a = newHostSessionGuard()
    let b = newHostSessionGuard()
    ck not a.supplied
    let url = a.sessionUrl("127.0.0.1", 4000)
    ck url.startsWith("http://127.0.0.1:4000/?" & SessionQueryParam & "=")
    let secret = url.split("=")[^1]
    ck secret.len == 43
    ck a.secretMatches(secret)
    ck not b.secretMatches(secret)

  test "a weak or malformed supplied secret is refused without quoting it":
    for bad in ["short", "x".repeat(MinSecretLen - 1),
                "has spaces and is long enough to pass length", "a".repeat(MaxSecretLen + 1)]:
      setEnv(SessionSecretEnv.cstring, bad.cstring)
      var message = ""
      try:
        discard newHostSessionGuard()
      except HostSessionError as e:
        message = e.msg
      ck message.len > 0
      ck bad notin message
      ck not envIsSet(SessionSecretEnv.cstring)

suite "ct host origins":
  setup:
    unsetEnv(SessionSecretEnv.cstring)
    unsetEnv(AllowedOriginsEnv.cstring)

  test "a loopback bind is reached as localhost, 127.0.0.1 and [::1]":
    let origins = pageOriginsFor("127.0.0.1", 4000)
    ck "http://127.0.0.1:4000" in origins
    ck "http://localhost:4000" in origins
    ck "http://[::1]:4000" in origins
    ck origins.len == 3

  test "another bind is reached at its own address only":
    ck pageOriginsFor("10.1.2.3", 4000) == @["http://10.1.2.3:4000"]

  test "a wildcard bind adds the interface addresses":
    let origins = pageOriginsFor("0.0.0.0", 4000)
    ck "http://127.0.0.1:4000" in origins
    ck "http://localhost:4000" in origins

  test "allowed origins are parsed as origins, and anything else is an error":
    ck parseAllowedOrigins("https://ci.example.com, http://Proxy.Example:8080/") ==
      @["https://ci.example.com", "http://proxy.example:8080"]
    for bad in ["ci.example.com", "https://ci.example.com/replay", "ftp://x.example",
                "https://user@ci.example.com", "https://ci.example.com/?a=1"]:
      expect HostSessionError:
        discard parseAllowedOrigins(bad)

  test "requests: the origin and the secret are both required":
    setEnv(SessionSecretEnv.cstring, Supplied.cstring)
    setEnv(AllowedOriginsEnv.cstring, "https://ci.example.com")
    let guard = newHostSessionGuard()
    # Before the page's port is known no page origin is accepted.
    ck guard.refusal(fakeRequest(cstring("/?ct_session=" & Supplied),
      headers({"origin": "http://127.0.0.1:4000"}))) == "origin not allowed"
    guard.setPagePort("127.0.0.1", 4000)
    let own = headers({"origin": "http://localhost:4000"})
    ck guard.refusal(fakeRequest(cstring("/?ct_session=" & Supplied), own)) == ""
    ck guard.refusal(fakeRequest(cstring"/", headers({
      "origin": "http://localhost:4000", SessionHeader: Supplied}))) == ""
    ck guard.refusal(fakeRequest(cstring("/?ct_session=" & Supplied),
      headers({"origin": "https://ci.example.com"}))) == ""
    # No Origin: a client that is not a browser page; the secret decides.
    ck guard.refusal(fakeRequest(cstring("/?ct_session=" & Supplied), noHeaders())) == ""
    ck guard.refusal(fakeRequest(cstring"/", own)) == "missing or wrong session secret"
    ck guard.refusal(fakeRequest(cstring("/?ct_session=" & Supplied & "&ct_session=" & Supplied),
      own)) == "missing or wrong session secret"
    for foreign in ["http://evil.example", "null", "http://localhost:4001",
                    "https://localhost:4000", "http://localhost:4000/"]:
      ck guard.refusal(fakeRequest(cstring("/?ct_session=" & Supplied),
        headers({"origin": foreign}))) == "origin not allowed"

suite "assertion count":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
