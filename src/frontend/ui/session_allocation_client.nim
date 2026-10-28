## THE REQUEST PATH THAT ASKS THE SUBSTRATE FOR A SESSION — WD7.
##
## `viewmodel/platform/session_allocation.nim` decides what to ask and how to
## read the answer and performs no I/O. This module is the other half: the two
## HTTP calls, and the order they go in.
##
## ## Why the transport is here and not there
##
## Two reasons, and the second is the one that made it a separate file.
##
## A module that fetched could only be tested through a fake, and then the
## thing under test would be the fake's fidelity. Splitting them lets
## `test_session_allocation.nim` drive every property of the request and of
## the answer in process, against the real module, with no mock at all — which
## is what the workspace's mock policy asks for and what makes those 118
## assertions worth having.
##
## And `ci/test/noir-studio-signed-out.sh` budgets egress **per site, by
## surface**. Its rule is that every network primitive in the renderer arm
## belongs to a named surface whose count is written down, and *"a `fetch` that
## is none of them"* fails the gate. Two sites in one file, carrying one marker,
## are a surface a classifier can name. The same two scattered through
## `ui_js.nim` would be two more entries in a budget whose largest row is
## already "seven, all in `ui_js.nim`'s importjs blocks".
##
## ## THIS FILE IS RENDERER-ONLY, AND THAT IS A GATE RATHER THAN A CONVENTION
##
## `src/frontend/ui/` is not reachable from `src/frontend/web_main.nim`, the
## Noir Studio arm, which the same gate requires to have **zero** egress sites.
## That zero is what makes write/compile/run/record/export work signed out and
## on a plane, and it is also the construction half of
## `Hosted-Session-Allocation.md` §5's `test_noir_studio_allocates_nothing`:
## Noir Studio does not allocate because the code that allocates is not in its
## bundle. `ci/test/wd7-loop-arm-allocates-nothing.sh` plants an import of
## this module into `web_main.nim` and requires the gate's step 2b to go red,
## so the separation is measured rather than asserted.
##
## ## The order, and why a descriptor comes first
##
##   1. `GET /api/v1/apps/{project}/deployment.json` — WD1c's descriptor, WD4's
##      input, served by the platform's api-server from the platform database.
##      **Not read at the edge** (§3.1a): a Pages Function reading a per-project
##      record would mean an API call on every request to the application
##      shell, before first paint, and a copy published with the deployment is
##      stale by construction.
##   2. `POST /api/v1/projects/{project}/sessions` — the allocation, if and only
##      if the descriptor declares a session runtime.
##
## Both are same-origin and both go through the front door's `/api/v1` rule to
## `API_ORIGIN` (`web_deployment.FrontDoorApiPrefixes`), so the bundle names no
## hostname. That is also what makes D-S13 work without a field: the product is
## fixed by the api-server's own `ISONIM_SESSION_PRODUCT`, and a bundle that
## chose an origin would be a bundle choosing which grant it spends against.
##
## ## A failure here is never fatal and never a refusal of our own
##
## A descriptor that does not arrive leaves the page exactly as a deployment
## without this path serves it — the same rule `fetchDescriptorThen` already
## states, for the same reason: *"blocking the socket on a fetch would turn a
## missing endpoint into a dead page."* And an unreachable substrate is
## reported as unreachable, never as a plan that is exhausted; the substrate
## itself refuses to conflate those two (`substrate_unavailable` exists there
## because *"a developer on a machine without Incus should be told that and not
## told their plan is exhausted"*).

import std/options

import ../viewmodel/platform/session_allocation

export session_allocation

const
  DescriptorPathPrefix* = "/api/v1/apps/"
  DescriptorPathSuffix* = "/deployment.json"
    ## WD4's route, named here as two constants so the one place it is built
    ## can be asserted rather than grepped.

func descriptorPathFor*(projectId: string): string =
  DescriptorPathPrefix & projectId & DescriptorPathSuffix

when defined(js):
  # ONE importjs LITERAL PER CALL, each carrying the marker
  # `CODETRACER_SESSION_ALLOCATION` immediately beside its `fetch(`. The
  # marker is what `ci/test/noir-studio-signed-out.sh`'s `surface_of` reads to
  # classify the site, and it is inside the emitted string rather than in a Nim
  # comment because a Nim comment does not survive into the bundle — a
  # classifier that depended on one would see `UNCLASSIFIED` and fail the gate
  # for the wrong reason.

  proc fetchProjectDescriptor*(path: cstring;
                               done: proc(status: int; body: cstring)
                              ) {.importjs: """
    (function (path, done) {
      /* CODETRACER_SESSION_ALLOCATION: WD1c's descriptor, WD4's input. */
      try {
        fetch(String(path), { credentials: 'same-origin' })
          .then(function (r) {
            return r.text().then(function (t) { done(r.status, t); });
          })
          .catch(function (e) { done(0, String(e && e.message || e)); });
      } catch (e) { done(0, String(e && e.message || e)); }
    })(#, #)
  """.}

  proc postSessionAllocation*(path, body: cstring;
                              done: proc(status: int; body: cstring)
                             ) {.importjs: """
    (function (path, body, done) {
      /* CODETRACER_SESSION_ALLOCATION: the allocation itself. `credentials`
       * is how the principal is named -- the login cookie IS the tenancy's
       * customer_id, and no principal id is sent. No product_id either: it
       * comes from the api-server's deployment (D-S13). */
      try {
        fetch(String(path), {
          method: 'POST',
          credentials: 'same-origin',
          headers: { 'Content-Type': 'application/json' },
          body: String(body)
        })
          .then(function (r) {
            return r.text().then(function (t) { done(r.status, t); });
          })
          .catch(function (e) { done(0, String(e && e.message || e)); });
      } catch (e) { done(0, String(e && e.message || e)); }
    })(#, #, #)
  """.}
else:
  # The renderer arm is the JS backend. These exist so the module compiles
  # under `nim c` for a unit lane and so a native host that one day wants this
  # path has to ATTACH a transport rather than find one already wired: the
  # callback is invoked with status 0, which `readAllocationOutcome` reads as
  # `asUnreachable` — not as a refusal.
  proc fetchProjectDescriptor*(path: cstring;
                               done: proc(status: int; body: cstring)) =
    done(0, cstring"no HTTP transport is attached on this backend")

  proc postSessionAllocation*(path, body: cstring;
                              done: proc(status: int; body: cstring)) =
    done(0, cstring"no HTTP transport is attached on this backend")

type
  SessionStart* = object
    ## What the page is told. Three states and not two, for the same reason
    ## `AllocationStatus` has three: a substrate that did not answer is not a
    ## plan that is exhausted.
    asked*: bool
      ## Whether an allocation was REQUESTED at all. False for a static
      ## project, which is every project written before the runtime fields
      ## existed — and the reason the substrate sees no request from Noir
      ## Studio.
    outcome*: AllocationOutcome

proc startSessionForProject*(projectId: string;
                             onStart: proc(start: SessionStart)) =
  ## Ask the substrate for this project's session, if this project wants one.
  ##
  ## **No allocation is attempted for a static project, and no descriptor
  ## decision is taken here.** `allocationRequestFor` is the only thing that
  ## decides whether to ask, from the descriptor alone; this proc sequences the
  ## two calls and hands back what came out. A branch here on the flavour, the
  ## image, a count of attempts, or an entitlement would be the re-derived
  ## admission check `Hosted-Session-Allocation.md` §3.2 forbids.
  if projectId.len == 0:
    onStart(SessionStart(asked: false))
    return
  fetchProjectDescriptor(descriptorPathFor(projectId).cstring,
    proc(status: int; body: cstring) =
      if status != 200:
        # The descriptor did not arrive. The page keeps working exactly as a
        # deployment without this path serves it, and nothing is claimed about
        # a session — in particular nothing is claimed about entitlement.
        onStart(SessionStart(asked: false))
        return
      var descriptor: SessionDescriptor
      try:
        descriptor = decodeDescriptor($body)
      except CatchableError:
        # A descriptor this build cannot read is NOT a session runtime it may
        # guess at. `decodeRuntime` raises on an unknown kind and on a session
        # runtime with an empty image for exactly this reason.
        onStart(SessionStart(asked: false))
        return
      var request: AllocationRequest
      try:
        let want = allocationRequestFor(descriptor)
        if want.isNone:
          onStart(SessionStart(asked: false))
          return
        request = want.get()
      except CatchableError:
        onStart(SessionStart(asked: false))
        return
      postSessionAllocation(request.path.cstring, request.body.cstring,
        proc(allocStatus: int; allocBody: cstring) =
          onStart(SessionStart(
            asked: true,
            outcome: readAllocationOutcome(allocStatus, $allocBody)))))

func sessionStartFailureText*(start: SessionStart): string =
  ## The sentence to put in front of a person, or empty when there is nothing
  ## to say. **The substrate's own words**, reproduced; see
  ## `allocationFailureText`.
  if not start.asked: ""
  elif start.outcome.status == asAllocated: ""
  else: "This project's session could not be started — " &
        allocationFailureText(start.outcome)
