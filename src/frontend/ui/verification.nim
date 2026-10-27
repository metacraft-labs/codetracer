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
## Lifecycle:
## 1. ``utils.nim::makeVerificationComponent`` constructs the legacy
##    ``VerificationComponent`` and registers it under ``Content.Verification``.
## 2. GoldenLayout's component factory creates the
##    ``verificationComponent-{id}`` container and the panel host
##    (``ui/panel_host``) mounts the pane into it, with the renderer this
##    module registers: ``renderVerificationPane``, the run and then the
##    counterexample, each in a host rebuilt by its own effect.
## 3. Nothing installs a shared store: neither VM has one. `VerificationVM` is
##    pushed at by a host adapter and pulls at `verification_report`, which is
##    pure; `CounterexampleSessionVM` reads only the payload the run attached.
##    They are this module's, not the session's, so the pane keeps one run
##    across trace switches.
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
## So the reachable surface is exactly one entry: **View ▸ Verification**. What
## the developer sees there depends only on what the run produced.
##
## **On macOS that entry is reachable through the command palette, not the
## menu, and the difference is not ours.** `electron_profile.nim` gives darwin
## `capNativeMenuBar`, so `topbar_actions` withholds `tbaInPageMenu` and
## `menu.nim` suppresses the in-page HTML menu; the *native* menu is only
## registered under `-d:ctmacos`, which the nix/reprobuild build path never
## passes (`repro.nim`'s `RendererDefines` is `chronicles_enabled=off` +
## `ctRenderer`). The palette is unaffected: `ui_js.nim` builds its command list
## from `getCommands(data.ui.menuNode)` — the same tree — whether or not that
## tree is rendered. So one `element` declaration buys the menu on Linux and
## Windows and the palette everywhere, and a UI test that drives the *menu* must
## skip darwin the way `welcome-screen/launch_config.spec.ts` already does.
##
## ## What no lane runs
##
## The registration below is compiled by the `renderer-electron` lane (`nim js -d:ctRenderer src/frontend/ui_js.nim`) and
## **run** by nothing in CI — it needs Electron. The panel's behaviour is
## asserted headlessly in `viewmodel/tests/unit/test_counterexample_session.nim`
## against the same views this file mounts; what is unasserted here is the
## mount itself: that the container exists, that it is found, and that the
## effects survive a GoldenLayout re-parent.

import
  ui_imports,
  ../[ types, communication ]

from isonim/web/dom_api import nil
import isonim/web/web_renderer
import ./panel_host
from ../viewmodel/session_vm import SessionViewModel
from ../viewmodel/viewmodels/verification_vm import
  VerificationVM, createVerificationVM
from ../viewmodel/viewmodels/counterexample_session_vm import
  CounterexampleSessionVM, createCounterexampleSessionVM
import ../viewmodel/views/isonim_verification_view

var verificationVMInstance*: VerificationVM
var counterexampleVMInstance*: CounterexampleSessionVM

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

# The panel host mounts the pane into the container GoldenLayout creates.
setPanelRenderer(Content.Verification,
  proc(r: WebRenderer; host: dom_api.Element;
       session: SessionViewModel): dom_api.Element =
    initVerificationVM()
    renderVerificationPane[WebRenderer, dom_api.Element](r,
      verificationVMInstance, counterexampleVMInstance))

method register*(self: VerificationComponent, api: MediatorWithSubscribers) =
  ## No subscriptions: the VMs are pushed at by the host adapter.
  self.api = api
  initVerificationVM()
