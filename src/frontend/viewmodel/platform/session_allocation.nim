## ASKING THE SUBSTRATE FOR A SESSION — WD7.
##
## `Architecture/Hosted-Session-Allocation.md` §3.1. This is the one thing the
## web deployment could not do: WD4 ships the front door that forks on
## signed-in-ness and passes the substrate's refusals through with their
## status, WD1b ships the platform *inside* the container, WD2 ships the image
## — and nothing asked for a session. Every container the product ran in was
## one somebody else started.
##
## ## What this module is allowed to decide, which is almost nothing
##
## §3.2 is three prohibitions and they are the whole design:
##
##   * **It does not own the container.** Lifetime, idle policy, eviction and
##     the warm pool are the substrate's. So there is no spawn here, no runtime
##     name, no container id this code chose — only a request and the answer to
##     it.
##   * **It does not count leases.** Concurrency, flavour admission and budget
##     are enforced per `(customer_id, product_id)` by the substrate, *"which
##     refuses with a reason. CodeTracer surfaces the reason; it does not
##     re-derive the decision."*
##   * **It does not meter.**
##
## The consequence is sharper than it first reads: **this module compares the
## refusal reason to nothing.** There is no list of the six reasons here, and
## that absence is load-bearing rather than an omission. A list would be a
## CodeTracer-side opinion about which refusals exist, and the first thing it
## would do is turn the seventh — the one a substrate three weeks newer than
## this bundle learned to emit — into a generic failure. `unknown_image` is in
## §5's list for exactly that shape of reason: it *"is the one a half-deployed
## producer pipeline actually produces, and reporting it as a generic failure
## is how 'the image was never published' becomes an hour of debugging the
## substrate."*
##
## So the test that matters here drives an INVENTED reason through and requires
## it back byte for byte. A module with an allow-list passes every test written
## with the six real reasons and fails that one.
##
## ## Where the request's fields come from, and the one that is NOT a field
##
## §3.1: an allocation request carries *"an OCI image reference plus a
## flavour"* and the tenancy tuple `(customer_id, product_id, project_id)`.
## Four of those five values are here; the fifth deliberately is not.
##
##   | value | where it comes from |
##   |---|---|
##   | the principal | the login cookie, same-origin. The substrate resolves it with `requireViewer`; the bundle never sees a principal id and must not send one. |
##   | `project_id` | the descriptor's `session.projectId`, which is the platform record's own name. |
##   | the flavour | the descriptor's `session.runtime.flavour`. |
##   | the image reference | the descriptor's `session.runtime.imageRef`. |
##   | `product_id` | **NOT SENT.** See below. |
##
## **`product_id` comes from the deployment, never from the request**, which is
## `metacraft-specs/infrastructure/Shared-Services-Decisions.md` **D-S13**,
## decided 2026-09-30. Admission is keyed on `(customer_id, product_id)` and
## the same meter can carry different rates, so a caller that named its own
## product could rate-shop between two products the same customer legitimately
## holds. The substrate's own `newSessions` says it in as many words — *"a path
## prefix would not do: a caller picking the URL is a caller picking the
## product"* — and the cost it states is the deployment fact this bundle rests
## on: `ide.codetracer.com` reaches a front door whose api-server runs with
## `ISONIM_SESSION_PRODUCT=codetracer`. That is configuration, and it is the
## reason there is nothing to send.
##
## A body that carried `"product_id"` would therefore be a defect rather than a
## redundancy, and the suite asserts its absence.
##
## ## The per-project input is READ, not re-derived — §3.1a
##
## `(image reference, flavour)` is the pair WD4 already carries, in the
## deployment descriptor's `session` group, served by
## `GET /api/v1/apps/:name/deployment.json` and fetched by the bundle. WD4's
## own note says what this must not add: *"a second place the front door
## looks."* So `allocationRequestFor` takes a `SessionDescriptor` and reads it.
## It does not consult settings, a project store, an environment variable or a
## second endpoint, and there is no parameter by which a caller could override
## the pair — an override is a second place.
##
## ## A static project produces NO REQUEST AT ALL
##
## `prkStatic` is the descriptor's zero value and the whole corpus of projects
## written before the field existed reads as static. `allocationRequestFor`
## answers `none` for it, which is what keeps the anonymous path and
## `ci/test/noir-studio-signed-out.sh` untouched — and it is the construction
## half of §5's `test_noir_studio_allocates_nothing`. The observational half
## belongs to the substrate, which must see no request; this is the reason it
## will not.
##
## ## This module performs no I/O
##
## There is no `fetch` here and no transport. It builds a request and reads a
## response, and the single site that puts those on a socket is the caller's —
## which is what lets the suite drive every property in-process, and what keeps
## `ci/test/noir-studio-signed-out.sh`'s per-surface egress budget able to name
## one site rather than a module.

import std/[json, options]

import ./deployment_descriptor

export deployment_descriptor

type
  AllocationRequest* = object
    ## One allocation, as the substrate's HTTP surface takes it
    ## (`isonim-platform` `api-server/src/routes.nim` `handleAllocateSession`,
    ## routed at `POST /api/v1/projects/{app}/sessions`).
    verb*: string
      ## `POST`, and a POST because it ALLOCATES: a container is started and a
      ## `session.concurrent` lease is taken. The substrate's own route comment
      ## gives the reason a GET would be wrong — *"a GET that did this would be
      ## actioned by link prefetch and by every crawler that followed the
      ## dashboard"* — and the verb is a field rather than a constant so the
      ## suite can assert it instead of trusting it.
    path*: string
      ## Same-origin and absolute-from-root. The front door routes `/api/v1`
      ## to `API_ORIGIN` (`web_deployment.FrontDoorApiPrefixes`), so this
      ## reaches the product's own api-server without the bundle knowing its
      ## hostname — which is also what makes D-S13's deployment-fixed product
      ## work without a field.
    body*: string
      ## The serialised JSON body. A string rather than a `JsonNode` because
      ## this is what goes on the wire, and because a test that asserts over
      ## the bytes cannot be satisfied by a node that serialises differently.
    sameOriginCredentials*: bool
      ## Whether the login cookie travels. Always true: the cookie IS how the
      ## principal is named (§3.1's `customer_id`), and a request without it is
      ## answered 401 by `requireViewer`. It is a field so the one place that
      ## must be true is asserted rather than assumed.

  AllocationStatus* = enum
    ## **Three outcomes, not two**, and the third is the one worth naming.
    asAllocated
      ## The substrate allocated a session, or handed back the one this
      ## principal already held on this project. Those are deliberately the
      ## same outcome here: reuse is the substrate's product behaviour
      ## (*"opening a project twice must not start two containers and must not
      ## bill two leases"*) and it reports which happened in `origin`, so a
      ## consumer that treated reuse as a different case would be re-deciding
      ## something already decided.
    asRefused
      ## The substrate refused, and `reason` is ITS word for why, unexamined.
    asUnreachable
      ## No usable answer came back. **This is not a refusal and must never be
      ## presented as one.** A deployment whose api-server is down would
      ## otherwise tell the user their plan is exhausted, which is the shape
      ## the substrate itself refuses to take: `substrate_unavailable` exists
      ## there because *"a developer on a machine without Incus should be told
      ## that and not told their plan is exhausted"*.

  AllocationOutcome* = object
    ## The substrate's answer, carried rather than interpreted.
    status*: AllocationStatus
    httpStatus*: int
      ## Kept because WD4 passes refusals through WITH their status and the two
      ## halves have to agree about what the status was.
    reason*: string
      ## **Verbatim.** Whatever the substrate said, including a reason this
      ## build has never heard of.
    message*: string
      ## Also verbatim. Billing's own vocabulary; re-wording it would give the
      ## product a second name for a decision the entitlement snapshot named.
    sessionId*: string
    instance*: string
    origin*: string
      ## `"new"` or `"existing"` — the substrate's statement about reuse.
    flavour*: string
      ## What was ALLOCATED, which need not be what was asked for and is the
      ## substrate's to say.
    hostname*: string
    startingMessage*: string
    waitedMillis*: int

const
  AllocationVerb* = "POST"
  AllocationPathPrefix* = "/api/v1/projects/"
  AllocationPathSuffix* = "/sessions"

func allocationPathFor*(projectId: string): string =
  ## The substrate's route for this project, built in one place.
  ##
  ## There is no escaping here and that is a deliberate narrowing rather than
  ## an oversight: `projectId` is the platform record's own `name`, which the
  ## descriptor carried from the database, and a value that needed escaping to
  ## be safe in a path is a value this bundle should not have been handed.
  ## `allocationRequestFor` refuses an empty one for the same reason.
  AllocationPathPrefix & projectId & AllocationPathSuffix

proc allocationBodyFor*(runtime: ProjectRuntime): string =
  ## The request body: **both halves of §5's runtime contract and nothing
  ## else.**
  ##
  ## `flavour` and `image` are request fields because neither changes a trust
  ## boundary — both are already admission-gated, a flavour this principal is
  ## not entitled to is refused by `admit` and a reference the daemon does not
  ## hold is refused with `unknown_image`. `product_id` is absent for the
  ## opposite reason (D-S13), and `slot` is absent because this deployment asks
  ## for "the session for this project" and a slot is how a caller says
  ## "another one" — a thing only a caller with several panes open can know.
  let node = %*{"flavour": runtime.flavour, "image": runtime.imageRef}
  $node

proc allocationRequestFor*(d: SessionDescriptor): Option[AllocationRequest] =
  ## The allocation this descriptor asks for, or `none`.
  ##
  ## `none` IN EXACTLY ONE CASE, and it is not an admission decision: the
  ## project declares no session runtime. Everything else is the substrate's
  ## to judge, so everything else produces a request — including a flavour
  ## this build has never seen and an image reference that looks unpublished.
  ## Refusing either here would be the re-derived admission check §3.2
  ## forbids, and the suite plants exactly that defect to prove this stays
  ## true.
  if d.session.runtime.kind != prkSession:
    return none(AllocationRequest)
  # An empty project id would build `/api/v1/projects//sessions`, which the
  # substrate's router splits to an empty `parts[4]` and answers about a
  # project called "". Raising is better than asking: a session runtime with
  # no project is a descriptor its producer got wrong, and the same argument
  # `decodeRuntime` already makes about an empty image reference applies —
  # the failure presented as a working request is the expensive one.
  if d.session.projectId.len == 0:
    raise newException(DescriptorError,
      "this descriptor declares a session runtime with no project id; there " &
      "is no project to allocate against, and an empty one addresses a " &
      "project named \"\" at the substrate")
  some(AllocationRequest(
    verb: AllocationVerb,
    path: allocationPathFor(d.session.projectId),
    body: allocationBodyFor(d.session.runtime),
    sameOriginCredentials: true))

proc readAllocationOutcome*(httpStatus: int; body: string): AllocationOutcome =
  ## The substrate's answer, read without being judged.
  ##
  ## ## The one branch, and why it is on `ok` rather than on the status
  ##
  ## `handleAllocateSession` answers 200 with `ok: true` and **402** with
  ## `ok: false`, and `ok` is the field that decides here. Branching on the
  ## status instead would make this bundle's notion of "refused" a list of
  ## numbers — and the moment the substrate adds a second refusal status, a
  ## genuine refusal with a perfectly good reason in it reads as a success with
  ## an empty session id.
  ##
  ## ## A body that will not parse is UNREACHABLE, not refused
  ##
  ## HTML from a proxy, an empty 502, a truncated response: none of those is
  ## the substrate declining to allocate, and calling them a refusal invents a
  ## reason the substrate never gave. `asUnreachable` carries the status it saw
  ## so the caller can say what actually happened.
  result = AllocationOutcome(status: asUnreachable, httpStatus: httpStatus)
  var node: JsonNode
  try:
    node = parseJson(if body.len > 0: body else: "{}")
  except:
    # The bare `except:` is the measured one every parser in this tree carries:
    # on the JS backend `parseJson` defers to V8's `JSON.parse`, which throws a
    # raw `SyntaxError` that no Nim exception type matches, so the narrow form
    # catches nothing there and the exception escapes into the renderer.
    result.message = "the substrate's answer was not JSON"
    return
  if node.kind != JObject:
    result.message = "the substrate's answer was not a JSON object"
    return

  func str(n: JsonNode; key: string): string =
    let f = n{key}
    if f.isNil or f.kind != JString: "" else: f.getStr

  func num(n: JsonNode; key: string): int =
    let f = n{key}
    if f.isNil or f.kind != JInt: 0 else: f.getInt

  result.reason = str(node, "reason")
  result.message = str(node, "message")
  result.sessionId = str(node, "session_id")
  result.instance = str(node, "instance")
  result.origin = str(node, "origin")
  result.flavour = str(node, "flavour")
  result.hostname = str(node, "hostname")
  result.startingMessage = str(node, "starting_message")
  result.waitedMillis = num(node, "waited_ms")

  let ok = node{"ok"}
  if ok.isNil or ok.kind != JBool:
    # No `ok` at all: something answered with JSON that is not an
    # `AllocationView`. Not a refusal — there is no reason to surface.
    result.status = asUnreachable
    if result.message.len == 0:
      result.message = "the substrate's answer carried no allocation verdict"
    return
  result.status = if ok.getBool: asAllocated else: asRefused

func allocationFailureText*(o: AllocationOutcome): string =
  ## What a person reading the page is told, for an outcome that is not an
  ## allocation.
  ##
  ## **The reason is reproduced, not translated.** This is the whole of
  ## CodeTracer's contribution to a refusal: it puts the substrate's reason and
  ## the substrate's message in front of the user and adds no judgement of its
  ## own. A `case` over reasons here, however helpful each arm looked, would be
  ## the second vocabulary §3.2 forbids — and the arm nobody wrote would be the
  ## reason that mattered.
  case o.status
  of asAllocated: ""
  of asRefused:
    if o.message.len > 0: o.reason & ": " & o.message else: o.reason
  of asUnreachable:
    "the session substrate did not answer" &
      (if o.httpStatus != 0: " (HTTP " & $o.httpStatus & ")" else: "") &
      (if o.message.len > 0: ": " & o.message else: "")
