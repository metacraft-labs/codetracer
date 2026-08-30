## store/degraded_state.nim
##
## The degraded-state catalogue, as enums.
##
## `BlockTracer/Page-Descriptions.md` §14 ends with the rule this module
## exists to make true:
##
##   "Every row above is a **value of an enum on a ViewModel**, not a branch
##   in a view, which is what makes each of them testable without a browser."
##
## and `BlockTracer/Front-End-Architecture.md` §3 repeats it as a design
## rule: "anything a page *decides* lives in a memo, and every degraded state
## from Page-Descriptions.md §14 is a value of an enum on some ViewModel —
## not an `if` in a view."
##
## ## Which rows are *this* package's, and which are not
##
## §14's catalogue spans two layers, and putting all of it here would break
## the SDK's own boundary. `CodeTracer-Embed-SDK.md` §3.2's last row excludes
## "**Any chain concept** — transaction, block, chain id, generation" from
## this package outright, and `ci/test/sdk-facade-boundary.sh` enforces that
## by name. So the catalogue splits by what a *debugger over a trace* can
## itself know:
##
## | §14 row                             | Owner                                        |
## | ----------------------------------- | -------------------------------------------- |
## | Pipeline behind the chain tip       | `ChainVM` — Front-End-Architecture §3         |
## | Object not found                    | the router / `SearchVM` — §3                  |
## | Trace awaiting generation           | `GenerationJobVM` — §3, §14.1                 |
## | **Replay window expired**           | **here** — `raWindowExpired`                  |
## | **Permanently unreplayable**        | **here** — `raUnreplayable`                   |
## | **Browser cannot run the debugger** | **here** — `ReplayCapability` + `CapabilityRung` |
## | Recorder unavailable for the VM     | `TraceStatusVM` — §3                          |
## | Transaction below the history floor | `ChainRegistryVM` — §3                        |
## | **Trace truncated**                 | **here** — `tiTruncated`                      |
## | **Divergence detected**             | **here** — `tiDivergent`                      |
## | **No verified source**              | **here** — `savUnverified`                    |
## | Reorganised away                    | `ChainVM` — §3                                |
## | CDN unreachable                     | the service worker — §14, Rendering-And-Delivery |
##
## The six bold rows are the ones that reach a *pane*, and they are the six
## `PaneDegradation` values below. The other seven are named in this table
## rather than merely omitted, because "we forgot" and "that belongs one
## layer up" look identical in a file that only lists what it owns.
##
## **"here" means consumed here, not owned exclusively here.** Four of the six
## bold rows also have a BlockTracer ViewModel named against them in
## Front-End-Architecture §3's table — `CapabilityVM` for §14.2's ladder,
## `DivergenceVM` and `TraceStatusVM` for divergence, `SourceBundleVM` and
## `AddressVM` for verified source, `ArtifactVM` for availability. That is not
## a conflict and neither layer is redundant: those ViewModels *establish* the
## condition (a probe, a manifest verdict, a provider chain, a retention
## policy), and every one of those inputs is chain- or delivery-shaped, which
## is why they cannot live here. What lives here is the value a *pane* renders
## a treatment for, plus the precedence between two simultaneous conditions.
## The seam is the setters and the `CtReplayStatus` event in
## `replay_data_store.nim`: the layer above writes, the panes read. Anyone
## adding a row should ask which side of that seam they are on before adding
## it to `PaneDegradation`.
##
## ## Why one enum and a sensitivity set, rather than one enum per pane
##
## §14's opening sentence asks for "one canonical treatment rather than
## being reinvented per page". Five per-pane enums would be five places to
## re-decide what "truncated" means, and the precedence between two
## simultaneous conditions would be re-derived in each one — which is
## exactly the "branch in a view" failure mode moved up a layer.
##
## Instead: one `PaneDegradation`, one fixed precedence (`resolveDegradation`),
## and each pane declares as data the subset of rows it renders. A pane's
## memo is then a call, not a decision tree, and the precedence is asserted
## once.
##
## This module imports nothing. It is pure data and two total functions over
## it, so it compiles on both the C and the JS target — it reaches JS on every
## file in the `vm-js` lane, through `replay_data_store`. The suite that walks
## every value (`tests/unit/test_five_panes_drive_headlessly.nim`) runs in
## `vm-unit`, which is a C-backend lane, so the *values* are exercised on C
## only today.

type
  ReplayAvailability* = enum
    ## §14.1a — "A trace's availability is not binary, and collapsing it
    ## would produce the two worst outcomes: a retry button that cannot
    ## succeed, or an error where the honest answer is 'not right now'."
    ##
    ## The five rows of §14.1a's table, in that order. `raWindowExpired`
    ## and `raUnreplayable` are deliberately distinct values and not a
    ## bool: "'Not now' and 'not ever' are different states ... Presenting
    ## either as the other is the failure this table exists to prevent."
    raRetained
      ## The trace is kept indefinitely. The debugger opens.
    raWindowedLive
      ## Retained for a bounded window that has not closed. The debugger
      ## opens; a consumer may still want to say the window exists.
    raWindowExpired
      ## The trace is not *currently* retained. Renewable — §14.1a's
      ## "Renew" action, which is a public good rather than a per-user
      ## unlock, and belongs to the consumer.
    raNeverGenerated
      ## No trace has ever been produced for this execution. Distinct
      ## from `raWindowExpired` because nothing is being renewed.
    raUnreplayable
      ## Terminal. §14: "A terminal state with a reason, never a retry
      ## that cannot succeed."

  TraceIntegrity* = enum
    ## §14's "Trace truncated" and "Divergence detected" rows. Both are
    ## properties of a trace the replay engine holds, so both are knowable
    ## without any chain concept.
    tiComplete
      ## The trace covers the whole execution and validated clean.
    tiTruncated
      ## §14: "Banner in the debugger, with the option to request a
      ## deeper profile." The execution ran past what was recorded.
    tiDivergent
      ## §14: "Non-dismissible banner above the debugger, with the
      ## specific mismatch." Ranked above `tiTruncated` in
      ## `resolveDegradation` — a short replay is a smaller lie than a
      ## wrong one.

  ReplayCapability* = enum
    ## §14.2 — "The replay engine has real requirements, and a browser can
    ## fail to meet them in several distinct ways. Each has a specific
    ## cause and none should surface as a generic error."
    ##
    ## One value per row of §14.2's failure table, so the cause survives
    ## to the consumer instead of collapsing into "it did not work".
    rcCapable
      ## Every requirement met; the engine runs.
    rcWasmCompilationFailed
      ## Detected on `compileStreaming`.
    rcInsufficientMemory
      ## Allocation failure or budget exceeded. The worker is terminated.
    rcRangeRequestsUnsupported
      ## A `200` where a `206` was requested — §14.2 calls this a hostile
      ## intermediary. A whole-file memory-only path may still work if
      ## the trace fits, which is why this is its own value and not
      ## folded into `rcWasmCompilationFailed`.
    rcWorkerUnsupported
      ## Feature detection at session start said no.

  CapabilityRung* = enum
    ## §14.2's ladder, "in order, stopping at the first that works".
    ##
    ## The rung is a *value*, not a chain of `if`s in a view, for the
    ## reason §14.2 gives for the ladder existing at all: "the floor is a
    ## useful page, not an apology".
    crFullDebugger
      ## Not a rung — the engine runs and no fallback is in force.
    crTraceDownload
      ## Rung 1: "the container is self-contained and the user keeps
      ## something useful."
    crOpenInDesktop
      ## Rung 2: "the one path that always works."
    crStaticSummary
      ## Rung 3: a call and event summary rendered with no replay engine
      ## at all.

  SourceAvailability* = enum
    ## §14's "No verified source" row: "Instruction-level stepping, with
    ## the supply-sources action prominent."
    savVerified
      ## Source is present and matches the recorded build.
    savUnverified
      ## No verified source. Stepping degrades to instruction level; the
      ## supply-sources action is the prominent affordance.
    savAbsent
      ## No source of any kind for this position — a stripped library or
      ## a synthetic frame. Distinct from `savUnverified` because there
      ## is nothing for a supply-sources action to attach to.

  PaneDegradation* = enum
    ## The single value a pane hands its view, so the view renders a
    ## treatment rather than deciding on one.
    ##
    ## Six of the seven values are §14 rows; `pdNone` is the ordinary
    ## case. Every §14 row that reaches a pane is here, and nothing that
    ## does not reach a pane is (see the table in this module's header).
    pdNone
    pdPermanentlyUnreplayable  ## §14 / §14.1a — terminal
    pdReplayWindowExpired      ## §14 / §14.1a — renewable
    pdEngineUnavailable        ## §14 / §14.2 — a ladder rung is in force
    pdDivergenceDetected       ## §14 — non-dismissible banner
    pdTraceTruncated           ## §14 — banner, offer a deeper profile
    pdNoVerifiedSource         ## §14 — instruction-level stepping

  DegradedStateSnapshot* = object
    ## The four independent axes, read together. A snapshot rather than
    ## four arguments so `resolveDegradation` cannot be called with three
    ## of them by accident, and so a pane memo makes one read of each
    ## signal per evaluation.
    availability*: ReplayAvailability
    integrity*: TraceIntegrity
    capability*: ReplayCapability
    sourceAvailability*: SourceAvailability

const
  # The order `resolveDegradation` tests conditions in, most severe first.
  # Stated as data so a test can assert the ordering directly instead of
  # inferring it from the function's control flow.
  #
  # The ordering rule: a state that means "you cannot see this execution at
  # all" outranks one that means "what you can see is incomplete", which
  # outranks one that means "what you can see is coarser than usual".
  DegradationPrecedence*: array[6, PaneDegradation] = [
    pdPermanentlyUnreplayable,
    pdReplayWindowExpired,
    pdEngineUnavailable,
    pdDivergenceDetected,
    pdTraceTruncated,
    pdNoVerifiedSource,
  ]

  # The editor is the only pane that renders source, so it is the only one
  # that can offer §14's instruction-level fallback — and truncation does
  # not change which source a *position inside the recording* sits in, so
  # `pdTraceTruncated` is deliberately not on this list.
  EditorPaneDegradations*: set[PaneDegradation] = {
    pdPermanentlyUnreplayable,
    pdReplayWindowExpired,
    pdEngineUnavailable,
    pdNoVerifiedSource,
  }

  # A truncated trace's call tree ends before the execution did, which is a
  # claim the pane must not make silently.
  CalltracePaneDegradations*: set[PaneDegradation] = {
    pdPermanentlyUnreplayable,
    pdReplayWindowExpired,
    pdEngineUnavailable,
    pdTraceTruncated,
  }

  # Same reason as the calltrace: the last row of a truncated log is not the
  # last event of the execution.
  EventLogPaneDegradations*: set[PaneDegradation] = {
    pdPermanentlyUnreplayable,
    pdReplayWindowExpired,
    pdEngineUnavailable,
    pdTraceTruncated,
  }

  # Values past the truncation point were never recorded, so "no locals
  # here" and "no locals were kept" are different answers and the pane has
  # to be able to give the second one.
  StatePaneDegradations*: set[PaneDegradation] = {
    pdPermanentlyUnreplayable,
    pdReplayWindowExpired,
    pdEngineUnavailable,
    pdTraceTruncated,
  }

  # The debugger's chrome, and therefore the owner of both §14 banners: it
  # is the surface that has to refuse to step, and the one place the
  # divergence banner can sit "above the debugger" without every pane
  # re-rendering it.
  DebugControlsPaneDegradations*: set[PaneDegradation] = {
    pdPermanentlyUnreplayable,
    pdReplayWindowExpired,
    pdEngineUnavailable,
    pdDivergenceDetected,
    pdTraceTruncated,
  }

  # Every pane's sensitivity set, so a test can assert that the union covers
  # every §14 row this package owns — the check that catches a seventh row
  # being added to `PaneDegradation` and then rendered by nobody.
  AllPaneDegradations*: array[5, set[PaneDegradation]] = [
    EditorPaneDegradations,
    CalltracePaneDegradations,
    EventLogPaneDegradations,
    StatePaneDegradations,
    DebugControlsPaneDegradations,
  ]

func initDegradedStateSnapshot*(): DegradedStateSnapshot =
  ## The undegraded snapshot — a retained, complete, verified trace on a
  ## capable host. Named rather than relying on Nim's zero-initialisation
  ## so that reordering an enum cannot silently change the default.
  DegradedStateSnapshot(
    availability: raRetained,
    integrity: tiComplete,
    capability: rcCapable,
    sourceAvailability: savVerified,
  )

func capabilityRung*(capability: ReplayCapability): CapabilityRung =
  ## §14.2's ladder: "in order, stopping at the first that works".
  ##
  ## `rcRangeRequestsUnsupported` stops at `crTraceDownload` because
  ## §14.2 says a whole-file path may still serve a trace that fits, and
  ## the download rung is exactly that container. The two failures that
  ## mean the engine cannot execute here at all — no WASM, no worker —
  ## go straight to the desktop rung, which §14.2 calls "the one path
  ## that always works". `rcInsufficientMemory` terminates the worker,
  ## so offering a download that must then be opened *in this browser*
  ## would be the retry-that-cannot-succeed §14 exists to forbid; it
  ## falls to the static summary, whose whole point is that it needs no
  ## replay engine.
  case capability
  of rcCapable: crFullDebugger
  of rcRangeRequestsUnsupported: crTraceDownload
  of rcWasmCompilationFailed, rcWorkerUnsupported: crOpenInDesktop
  of rcInsufficientMemory: crStaticSummary

func degradationPresent*(snapshot: DegradedStateSnapshot;
                         degradation: PaneDegradation): bool =
  ## Whether `degradation` holds in `snapshot`, ignoring precedence and
  ## ignoring which pane is asking. Exposed because a consumer sometimes
  ## needs "is the trace also truncated?" alongside the single value a
  ## pane resolved to — §14's divergence banner sits above a debugger
  ## that may additionally be short.
  case degradation
  of pdNone:
    snapshot.availability in {raRetained, raWindowedLive} and
      snapshot.integrity == tiComplete and
      snapshot.capability == rcCapable and
      snapshot.sourceAvailability == savVerified
  of pdPermanentlyUnreplayable:
    snapshot.availability == raUnreplayable
  of pdReplayWindowExpired:
    # Both of §14.1a's renewable rows. They are one *pane* row because a
    # pane's treatment is identical — the debugger does not open, and the
    # page is otherwise intact — while the action differs ("Renew" vs
    # "Generate") and belongs to the consumer, which reads
    # `ReplayAvailability` and still has both values.
    #
    # This is not the collapse §14.1a forbids. That one is between "not
    # now" and "not ever", and it is prevented by `pdPermanentlyUnreplayable`
    # being a separate value that outranks this one.
    snapshot.availability in {raWindowExpired, raNeverGenerated}
  of pdEngineUnavailable:
    snapshot.capability != rcCapable
  of pdDivergenceDetected:
    snapshot.integrity == tiDivergent
  of pdTraceTruncated:
    snapshot.integrity == tiTruncated
  of pdNoVerifiedSource:
    snapshot.sourceAvailability != savVerified

func resolveDegradation*(snapshot: DegradedStateSnapshot;
                         sensitivity: set[PaneDegradation]): PaneDegradation =
  ## The one decision site. Walks `DegradationPrecedence` and returns the
  ## first degradation that both holds in `snapshot` and is one this pane
  ## renders; `pdNone` when none does.
  ##
  ## A pane that is not sensitive to a condition returns `pdNone` for it
  ## rather than a weaker value, which is the point of the sensitivity
  ## set: the editor showing a source line inside a truncated recording
  ## is not degraded, and saying it is would train users to ignore the
  ## banner that matters.
  for candidate in DegradationPrecedence:
    if candidate in sensitivity and snapshot.degradationPresent(candidate):
      return candidate
  pdNone
