## What a deployment tells the bundle about itself, on both backends.
##
## `UI-Bundle-And-Endpoints.md` §7, the PER-SESSION half. The per-build half
## already exists as `web_deployment.DeploymentDescriptor`, published at
## `/build-id.txt`, and is tested where it lives.
##
## What is worth testing here is not that the two groups round-trip but that
## the DEFAULTS are the safe ones, because every one of them decides something
## a user notices:
##
##   * an absent runtime declaration is `prkStatic`, so an unconfigured project
##     is served by the static bundle rather than allocating a container;
##   * a runtime kind this build does not know RAISES, because `prkStatic`
##     would silently deny a project its backend and `prkSession` would
##     allocate for one that never asked;
##   * a session runtime with an EMPTY image reference is refused, because an
##     empty reference reaches the substrate as "no preference" and is served
##     the base image — §3.1's *"a session started from the wrong environment
##     looks healthy everywhere except in the user's editor"*, one step earlier.
##
## Runs in `vm-unit` (C) and `vm-unit-js` (node). The malformed-input cases are
## why both: on JS, `parseJson` defers to V8, whose `SyntaxError` matches no Nim
## exception type, so a narrow `except CatchableError` would catch nothing and
## the throw would escape into the renderer.

import std/[json, strutils, unittest]

import ../../platform/deployment_descriptor

const ExpectedAssertions = 30
var counted = 0
template ck(cond: untyped) =
  inc counted
  check cond

template raisesDescriptorError(body: untyped) =
  inc counted
  var raised = false
  try:
    body
  except DescriptorError:
    raised = true
  except CatchableError:
    raised = false
  check raised

proc sampleDescriptor(): SessionDescriptor =
  SessionDescriptor(
    session: SessionCoordinates(
      traceId: "01932f00-0000-7000-8000-000000000000",
      projectId: "vellum--atlas",
      runtime: ProjectRuntime(kind: prkSession, imageRef: "codetracer-host:42",
                              flavour: "s2")),
    connection: ConnectionParameters(
      frontendSocketPort: 5001, frontendSocketParameters: "?token=abc",
      backendSocketPort: 5002))

suite "the whole descriptor round-trips":
  test "both groups survive, with the runtime declaration":
    let got = decodeDescriptor($encodeDescriptor(sampleDescriptor()))
    ck got.session.traceId == "01932f00-0000-7000-8000-000000000000"
    ck got.session.projectId == "vellum--atlas"
    ck got.session.runtime.kind == prkSession
    ck got.session.runtime.imageRef == "codetracer-host:42"
    ck got.session.runtime.flavour == "s2"
    ck got.connection.frontendSocketPort == 5001
    ck got.connection.frontendSocketParameters == "?token=abc"
    ck got.connection.backendSocketPort == 5002

suite "the runtime declaration, which decides whether a container is allocated":
  test "ABSENT is static — the default that keeps the anonymous path":
    # `ci/test/noir-studio-signed-out.sh` depends on this and so does every
    # project nobody has configured, which is all of them today.
    let got = decodeDescriptor("""{"session": {"traceId": "t"}}""")
    ck got.session.runtime.kind == prkStatic
    ck got.session.runtime.imageRef == ""

  test "a descriptor with no session at all is static too":
    let got = decodeDescriptor("{}")
    ck got.session.runtime.kind == prkStatic
    ck got.session.traceId == ""

  test "prkStatic is the ZERO value, so a record nobody filled in is static":
    # Asserted because it is a property of the DECLARATION ORDER and an
    # innocent-looking reorder would take it away. Nim zero-initialises, and a
    # default meaning "allocate" would turn every unconfigured project into a
    # container.
    var blank: ProjectRuntime
    ck blank.kind == prkStatic
    ck ord(prkStatic) == 0

  test "an explicit static declaration carries no image or flavour":
    # A static project holding an image reference is a statement nothing acts
    # on, and the next reader would reasonably wonder which field decided.
    let text = $encodeDescriptor(SessionDescriptor(
      session: SessionCoordinates(runtime: ProjectRuntime(
        kind: prkStatic, imageRef: "left-over:1", flavour: "s2"))))
    ck not text.contains("left-over")
    ck decodeDescriptor(text).session.runtime.imageRef == ""

  test "a SESSION runtime with no image reference is REFUSED":
    # The assertion this module exists for. An empty reference reaches the
    # substrate as "no preference" and is served its own base image — the wrong
    # environment, presented as a working one.
    raisesDescriptorError:
      discard decodeDescriptor(
        """{"session": {"runtime": {"kind": "prkSession"}}}""")
    raisesDescriptorError:
      discard decodeDescriptor(
        """{"session": {"runtime": {"kind": "prkSession", "imageRef": ""}}}""")

  test "and one WITH a reference is accepted, flavour or not":
    # The flavour may legitimately be absent — the substrate has a default for
    # it and `admit` gates what a principal may ask for. The image has no such
    # fallback that is not a wrong answer.
    let got = decodeDescriptor(
      """{"session": {"runtime": {"kind": "prkSession", "imageRef": "i:1"}}}""")
    ck got.session.runtime.kind == prkSession
    ck got.session.runtime.imageRef == "i:1"
    ck got.session.runtime.flavour == ""

  test "a runtime kind this build does not know RAISES":
    # Deliberately unlike the ABSENT case above. "This deployment said nothing"
    # is static by design; "this deployment said something I cannot read" is a
    # deployment and a bundle that disagree, and guessing either way is wrong.
    raisesDescriptorError:
      discard decodeDescriptor(
        """{"session": {"runtime": {"kind": "prkQuantum"}}}""")
    raisesDescriptorError:
      discard decodeDescriptor("""{"session": {"runtime": {"kind": ""}}}""")

suite "malformed input raises on BOTH backends":
  test "text that is not JSON":
    raisesDescriptorError: discard decodeDescriptor("{not json")
    raisesDescriptorError: discard decodeDescriptor("")
    raisesDescriptorError: discard decodeDescriptor("undefined")

  test "JSON that is not an object":
    raisesDescriptorError: discard decodeDescriptor("[1,2,3]")
    raisesDescriptorError: discard decodeDescriptor("42")

  test "a session group that is not an object is not a session group":
    # `optStr` tolerates a missing field; it must not tolerate a `session` that
    # is a string or a number, because then `runtime` is unreadable and the
    # descriptor would silently read as static.
    let fromString = decodeDescriptor("""{"session": "nonsense"}""")
    ck fromString.session.runtime.kind == prkStatic
    ck fromString.session.traceId == ""

suite "the tally":
  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
