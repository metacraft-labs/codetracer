## Verification Panel — a Verno run, and the counterexample it produced.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the only renderer.
##
## There is no legacy Karax `method render` here and there never was one: this
## panel is VN-M3/VN-M5 work, built on the ViewModel layer from the start. The
## `VerificationComponent` exists purely as the GoldenLayout carrier — it gives
## the panel a `Content` identity, a container id and a place on the event bus.
##
## Lifecycle (the pattern `request_panel.nim` and `scratchpad.nim` document):
## 1. ``utils.nim::makeVerificationComponent`` constructs the legacy
##    ``VerificationComponent`` and registers it under ``Content.Verification``.
## 2. ``layout.nim`` registers the GL container, sees ``Content.Verification``
##    in its direct-mount set, and calls ``tryMountIsoNimVerificationPanel``
##    instead of invoking Karax.
## 3. The mount helper appends **two** IsoNim roots inside the
##    ``verificationComponent-{id}`` container — the run panel and the
##    counterexample panel — each rebuilt by its own `createEffect`.
## 4. Nothing installs a shared store: neither VM has one. `VerificationVM` is
##    pushed at by a host adapter and pulls at `verification_report`, which is
##    pure; `CounterexampleSessionVM` reads only the payload the run attached.
## ---------------------------------------------------------------------------
##
## ## Why the counterexample is not a `Content` of its own
##
## Because it would then be a thing a user can open when there is nothing to
## open. The counterexample region of this panel exists only while a session is
## open, and a session opens only from a finding whose payload carries a model
## with steps in it (`canOpenCounterexample`). A menu entry, a palette row or a
## restorable tab for it would be a standing affordance for something that is
## usually absent — which is the promise VN-M3's whole text tier was designed
## not to make, and which VN-M5 has no reason to start making.
##
## So the reachable surface is exactly one: **View ▸ Verification**. What the
## developer sees there depends only on what the run produced.
##
## ## What no lane runs
##
## Everything below the `when defined(js)` is compiled by the
## `renderer-electron` lane (`nim js -d:ctRenderer src/frontend/ui_js.nim`) and
## **run** by nothing in CI — it needs Electron. The panel's behaviour is
## asserted headlessly in `viewmodel/tests/unit/test_counterexample_session.nim`
## against the same views this file mounts; what is unasserted here is the
## mount itself: that the container exists, that it is found, and that the
## effects survive a GoldenLayout re-parent.

import
  ui_imports,
  ../[ types, communication ]

from ../viewmodel/viewmodels/verification_vm import
  VerificationVM, createVerificationVM
from ../viewmodel/viewmodels/counterexample_session_vm import
  CounterexampleSessionVM, createCounterexampleSessionVM

when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_verification_view import
    mountIsoNimVerificationPanel
  from ../viewmodel/views/isonim_counterexample_view import
    mountIsoNimCounterexampleSession

# ---------------------------------------------------------------------------
# Module-level slots, so the mount and the run can find each other across
# calls. Mirrors trace_log / request_panel / scratchpad.
# ---------------------------------------------------------------------------

var verificationVMInstance*: VerificationVM
var counterexampleVMInstance*: CounterexampleSessionVM
var verificationComponentRef: VerificationComponent
var isoNimVerificationMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

proc tryMountIsoNimVerificationPanel*()

proc initVerificationVM*() =
  ## Bring both VMs up if they are not already.
  ##
  ## **The two are created together and live as long as the panel does.** The
  ## session VM is not created per counterexample: `openCounterexample` is what
  ## fills it, and `close` is what empties it, so "is a counterexample open" is
  ## a property of its `isOpen` signal rather than of whether an object exists.
  ## A VM created on demand would make "no session" and "a session that failed
  ## to open" the same state, which is the distinction
  ## `CounterexampleSessionVM.refusalReason` exists to keep.
  if verificationVMInstance.isNil:
    verificationVMInstance = createVerificationVM()
  if counterexampleVMInstance.isNil:
    counterexampleVMInstance = createCounterexampleSessionVM()

when defined(js):
  proc tryMountIsoNimVerificationPanel*() =
    ## Mount both IsoNim roots into the GL container, retrying while the
    ## container is still being created — GoldenLayout attaches the host
    ## slightly after the layout state changes (mirrors
    ## ``tryMountIsoNimRequestPanel`` / ``tryMountIsoNimScratchpadPanel``).
    if verificationVMInstance.isNil or counterexampleVMInstance.isNil:
      return
    if verificationComponentRef.isNil:
      return
    let componentId = verificationComponentRef.id
    if isoNimVerificationMountedIds.hasKey(componentId):
      return

    let key = cstring("verificationComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      if isoNimVerificationMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimVerificationPanel: not ready after 200 " &
            "retries, giving up"
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)

      isoNimVerificationMountedIds[componentId] = true
      try:
        # Two roots, one container, in reading order: the run, then what its
        # counterexample says. They are separate mounts rather than one nested
        # tree because no IsoNim view in this repository composes another's
        # `ui()` tree, and inventing that here would be the largest untested
        # thing in a file nothing runs.
        mountIsoNimVerificationPanel(container, verificationVMInstance,
                                     counterexampleVMInstance)
        mountIsoNimCounterexampleSession(container, counterexampleVMInstance)
      except:
        cerror "tryMountIsoNimVerificationPanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

    doMount()
else:
  proc tryMountIsoNimVerificationPanel*() =
    ## Native compilation has no DOM — keep the proc available so callers
    ## compile on every backend.
    discard

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer, no Karax method render.
# ---------------------------------------------------------------------------

method register*(self: VerificationComponent, api: MediatorWithSubscribers) =
  ## Bring the VMs up so the mount can find them, and adopt the newest
  ## registration as the live panel.
  ##
  ## Dropping the mount-tracking entry is deliberate and is a bug the
  ## Scratchpad panel had: ids restart from 0 after a layout reset, so a stale
  ## "already mounted" marker would suppress the mount into the freshly created
  ## container and the re-opened panel would stay blank.
  self.api = api
  initVerificationVM()
  discard jsDelete(isoNimVerificationMountedIds[self.id])
  verificationComponentRef = self
  tryMountIsoNimVerificationPanel()
