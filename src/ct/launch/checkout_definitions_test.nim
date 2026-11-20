## checkout_definitions_test.nim — what a session reads from the checkout it
## opens, over real directories.
##
## `checkout_definitions.readCheckoutDefinitions` is the one call a front-end
## makes when a session opens. This suite builds real checkouts on disk — real
## `.codetracer/` files, real source files, a real trust ledger under a scratch
## launcher user root — and asserts what the call hands back.
##
## NO MOCKS. The one indirection is `CODETRACER_USER_ROOT`, pointed at a
## scratch directory so no case reads or writes the user's own ledger or their
## own definitions; it is the launcher's documented override, not a stand-in.
##
## Compile and run (lane `ct-cli-units`):
##   nim c -r src/ct/launch/checkout_definitions_test.nim

import std/[os, strutils, unittest]

import ../../common/project_wasm_fixtures
import ./checkout_definitions
import ./grant_store
import ./project_trust_store

const At = "2026-11-20T00:00:00Z"

var worldCounter = 0

type World = object
  root: string
  userRoot: string

proc newWorld(name: string): World =
  inc worldCounter
  let base = getTempDir() / ("ct-checkout-defs-" & name & "-" &
                             $getCurrentProcessId() & "-" & $worldCounter)
  removeDir(base)
  createDir(base / "checkout")
  createDir(base / "userroot")
  putEnv(userRootEnvVar, base / "userroot")
  World(root: base / "checkout", userRoot: base / "userroot")

proc write(w: World; rel, text: string) =
  createDir((w.root / rel).parentDir)
  writeFile(w.root / rel, text)

const Router = "import std/strutils\n\nproc handleRequest() =\n  discard\n"

const Points = """
schema = "codetracer.points.v1"

[[collection]]
name = "the request path"
enabled = true

[[collection.point]]
kind = "breakpoint"
path = "src/router.nim"
anchor = "proc handleRequest"

[[collection.point]]
kind = "tracepoint"
path = "src/router.nim"
anchor = "this text is nowhere"
expression = "x"
"""

const Visualisers = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
summary = "{rows}x{cols}"
"""

suite "a session reads its checkout's definitions":

  test "a checkout with no .codetracer/ reads nothing and says so":
    let w = newWorld("absent")
    w.write("src/router.nim", Router)
    let d = readCheckoutDefinitions(w.root)
    check not d.present
    check d.resolutions.len == 0
    check d.visualisers.len == 0
    check d.pending.len == 0
    check describeCheckout(d).contains("declares no project definitions")

  test "the launcher's own user root is not a project's .codetracer/":
    # `$HOME/.codetracer` holds the launcher's registry and the trust ledgers;
    # a session opened from the home directory must not read it as a project.
    let w = newWorld("home")
    let home = w.root.parentDir / "home"
    createDir(home / ".codetracer")
    writeFile(home / ".codetracer/visualisers.toml", Visualisers)
    putEnv(userRootEnvVar, home / ".codetracer")
    let d = readCheckoutDefinitions(home)
    check not d.present
    check d.visualisers.len == 0
    putEnv(userRootEnvVar, w.userRoot)

  test "collections are resolved against the checkout's own files, per point":
    let w = newWorld("points")
    w.write("src/router.nim", Router)
    w.write(".codetracer/points.toml", Points)
    let d = readCheckoutDefinitions(w.root)
    check d.present
    check d.resolutions.len == 1
    let r = d.resolutions[0]
    # BOTH points are there — the one that resolves and the one that does not.
    check r.points.len == 2
    check r.points[0].outcome == prResolved
    check r.points[0].line == 3
    check r.points[1].outcome == prUnresolved
    check r.points[1].line == 0
    check describeCheckout(d).contains("collection 'the request path'")

  test "an edit to the source file moves the resolved point":
    let w = newWorld("moved")
    w.write("src/router.nim", Router)
    w.write(".codetracer/points.toml", Points)
    check readCheckoutDefinitions(w.root).resolutions[0].points[0].line == 3
    w.write("src/router.nim", "# one\n# two\n" & Router)
    let after = readCheckoutDefinitions(w.root).resolutions[0].points[0]
    check after.line == 5
    check after.outcome in {prResolved, prMoved}

  test "visualiser rules become the presenter's visualisers":
    let w = newWorld("vis")
    w.write(".codetracer/visualisers.toml", Visualisers)
    let d = readCheckoutDefinitions(w.root)
    check d.visualisers.len == 1
    check d.visualisers[0].typeMatch == "Matrix"
    check d.visualisers[0].id == "project:.codetracer/visualisers.toml#0"

  test "package scopes come from the recorded program's own files":
    let w = newWorld("scopes")
    w.write("packages/net/src/router.nim", Router)
    w.write("packages/net/.codetracer/visualisers.toml", Visualisers)
    w.write("packages/ui/src/view.nim", "discard\n")
    let scopes = packageScopesFor(w.root,
      [w.root / "packages/net/src/router.nim", w.root / "packages/ui/src/view.nim",
       "/somewhere/else/entirely.nim"])
    check scopes == @["packages/net"]
    let d = readCheckoutDefinitions(w.root,
                                    [w.root / "packages/net/src/router.nim"])
    # No root `.codetracer/`, and the package's own one is still found.
    check d.present
    check d.scopes == @["packages/net"]
    check d.visualisers.len == 1

  test "the stamp changes when a definition file is edited, and only then":
    let w = newWorld("stamp")
    w.write(".codetracer/visualisers.toml", Visualisers)
    let first = readCheckoutDefinitions(w.root).stamp
    check readCheckoutDefinitions(w.root).stamp == first
    w.write(".codetracer/visualisers.toml", Visualisers & "\n# a longer file\n")
    check readCheckoutDefinitions(w.root).stamp != first

suite "the executable tier, as a session meets it":

  test "an ungranted definition is pending, unread, and reviewable":
    let w = newWorld("pending")
    w.write(".codetracer/visualisers.toml", Visualisers)
    w.write(".codetracer/visualisers.wasm", echoLengthModule())
    let d = readCheckoutDefinitions(w.root, trustRoot = w.userRoot)
    check d.executable.definitions.len == 0
    check d.pending.len == 1
    check d.pending[0].file == ".codetracer/visualisers.wasm"
    check d.pending[0].kind == dfkVisualiserCode
    # Nothing ran: no admitted definition means no computed visualiser.
    let (vis, ran, _) = computedVisualiser(d, [PValue(kind: pvkInt,
                                                     text: "7")], w.userRoot)
    check not ran
    check vis.computed.len == 0
    # The review reads the bytes to digest them, because the user asked.
    let (review, disclosure) = reviewPending(d, d.pending[0])
    check review.digest == contentDigest(echoLengthModule())
    check disclosure.contains("You are being asked to trust 'visualisers.wasm'")
    check disclosure.contains(review.digest)
    check disclosure.contains(w.root)

  test "a granted visualiser runs over the values on screen":
    let w = newWorld("granted")
    w.write(".codetracer/visualisers.wasm", echoLengthModule())
    let digest = contentDigest(echoLengthModule())
    check grantExecutableTier(w.userRoot, w.root, dfkVisualiserCode, digest,
                              At) == ""
    let d = readCheckoutDefinitions(w.root, trustRoot = w.userRoot)
    check d.pending.len == 0
    check d.executable.definitions.len == 1
    let value = PValue(kind: pvkString, typeName: "str", text: "hello")
    let (vis, ran, problems) = computedVisualiser(d, [value], w.userRoot)
    check ran
    check problems.len == 0
    check vis.computedDeclared
    check vis.computed.len == 1
    check vis.computed[0].input == executableInputOf(value)
    # `echoLengthModule` answers the decimal length of its input.
    let expected = align($executableInputOf(value).len, 2, '0')
    check vis.computed[0].text == expected
    # And the pipeline renders it, attributed to the definition.
    let p = present(value, StatePanelBudget,
                    presenters = withVisualisers(@[vis]))
    check p.root.text == expected
    check p.attribution.presenter == "project:.codetracer/visualisers.wasm#ct_visualise"
    # Revoking stops a handle the session is already holding.
    check revokeExecutableTier(w.userRoot, w.root, dfkVisualiserCode, At) == ""
    let (after, ranAfter, why) = computedVisualiser(d, [value], w.userRoot)
    check ranAfter
    check after.computed.len == 0
    check why.len > 0

suite "the trust ledger's identity and upkeep":

  test "a checkout's identity carries its birth marker":
    let w = newWorld("birth")
    let id = checkoutIdentity(w.root)
    check birthMarker(w.root).len > 0
    check id.startsWith("fs2:")
    check id.endsWith(":" & birthMarker(w.root))
    # A rename keeps the identity (the same directory, born once).
    let moved = w.root & "-moved"
    moveDir(w.root, moved)
    check checkoutIdentity(moved) == id
    # A copy is born now, and is a different checkout.
    copyDir(moved, w.root)
    check checkoutIdentity(w.root) != id

  test "upkeep forgets only what can never be admitted again":
    let w = newWorld("upkeep")
    let id = checkoutIdentity(w.root)
    let parts = id.split(':')
    # A legacy entry for THIS directory, from before the birth marker: same
    # device and inode, so no directory anywhere still carries that identity.
    let legacy = "fs1:" & parts[1] & ":" & parts[2]
    # An entry for a checkout recorded at a path that is now gone: it may have
    # moved, so it must survive.
    let elsewhere = "fs2:1:2:3.4"
    check updateProjectTrust(w.userRoot, proc(l: var ProjectTrustLedger) =
      discard l.grant(legacy, dfkVisualiserCode, "sha256:aa", At, w.root)
      discard l.grant(elsewhere, dfkDiffCode, "sha256:bb", At,
                      w.root & "-was-here")
      discard l.grant(id, dfkVisualiserCode, "sha256:cc", At, "/old/path")) == ""
    let u = keepProjectTrust(w.userRoot, [(id, w.root)])
    check u.failure == ""
    check u.forgotten == @[legacy]
    check u.reannotated == 1
    let after = loadProjectTrust(w.userRoot).ledger
    check legacy notin after.identities
    check elsewhere in after.identities
    check id in after.identities
    for e in after.entries:
      if e.identity == id: check e.note == w.root
    check describeUpkeep(u).contains("forgot 1")
    # Nothing left to do: the ledger is not rewritten again.
    let again = keepProjectTrust(w.userRoot, [(id, w.root)])
    check again.forgotten.len == 0
    check again.reannotated == 0
