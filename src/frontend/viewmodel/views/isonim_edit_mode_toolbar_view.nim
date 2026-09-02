## views/isonim_edit_mode_toolbar_view.nim
##
## The EDIT-MODE topbar, rendered from `viewmodels/edit_mode_toolbar`.
##
## ## What this closes
##
## `viewmodels/edit_mode_toolbar.nim` landed complete and tested — 30
## `ProjectKind`s, the provenance ladder, the browser capability tier — and
## was imported by **nothing outside its own two test files**. It was dead
## code in the shipped bundle, and the user-visible face of that was the bug
## report: *"I still see the debugger controls in the top bar even though I
## requested different buttons to be shown in Edit mode"*. The viewmodel had
## always answered that question correctly; nobody asked it.
##
## ## Why a second view rather than a branch inside the debug one
##
## `isonim_debug_controls_view.nim` builds ONE static `ui()` block whose only
## reactivity is per-attribute (`reactiveDisabled`, `reactiveHidden`). The two
## surfaces do not differ by an attribute — they differ in which elements
## exist — so a signal cannot restructure one into the other. The mount picks
## a surface and the transition re-mounts, which is the mechanism
## `ui/debug.nim` already has (`remountDebugControls`, and the
## `shouldRemountDebugControls` predicate it goes through).
##
## Keeping the debugger's panel untouched is the other half: the stepping
## controls are the product's most-exercised chrome, and this feature has no
## business editing them to add itself.
##
## ## Why the disabled state is an attribute and not an effect
##
## The debug panel's `reactiveDisabled` exists because its VM's `can*` memos
## change WHILE the panel stays mounted — a step lands and the buttons update.
## Nothing of that shape applies here: an `EditToolbarModel` is a pure value
## composed at mount time from the profile, the wasm registry and the project
## listing, and when any of those change the host re-mounts with a new model.
## A render effect over a value that cannot change between mounts would be
## machinery that never fires, and reading it later as "this is reactive" is
## how the next person wires a signal to it that never arrives.
##
## ## The id question, answered narrowly
##
## `ToolbarButton.id` warns that `run-tests-image` "exists today and routes to
## `ct record-test`". Measured rather than assumed: the published contract
## `src/tests/gui/page-objects/debug-toolbar-ids.ts` lists TEN ids and
## `run-tests-image` is not one of them, and the only other references are the
## debug view itself and a stylesheet rule. So no page object is retargeted by
## this file existing.
##
## What remains is that `#run-tests-image` would mean two things depending on
## mode. Rather than rename a spec-assigned id, the panel root carries
## `data-topbar-surface`, so a selector that cares can say which surface it
## means. `EDIT_TOOLBAR_IDS` in the page-object module records the pairing.
##
## ## Purity
##
## This module is in the host-free surface (`ci/test/hostfree-build.sh`), so it
## takes a composed `EditToolbarModel` and an `invoke` callback and reaches
## nothing. Everything a model needs to exist — the platform profile, the wasm
## registry, the project listing — is the caller's to know.

# `isonim/core/computation` is not used by name here — no effect is created,
# for the reason the header gives — but `isonim/dsl/ui` expands to
# `createRenderEffect` for any dynamic attribute, so the symbol has to be in
# scope at the expansion site or the `ui()` block does not compile.
import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/edit_mode_toolbar

const
  EditToolbarSurfaceAttr* = "data-topbar-surface"
    ## Names which surface the host is carrying, so a Playwright selector can
    ## disambiguate the ids the two panels share. Exported because the page
    ## object asserts against the same string.
  EditToolbarSurfaceValue* = "edit-commands"
  DebugToolbarSurfaceValue* = "debugger-controls"

proc visibleButtons*(model: EditToolbarModel): seq[ToolbarButton] =
  ## The buttons this model actually carries, in the order §7.2 fixes.
  ##
  ## `model.buttons` is every button the model COMPUTED; `model.actions` is
  ## which slots the mode and the platform allow. Rendering the first without
  ## filtering by the second is how a Build button appears in Debug mode, which
  ## EMT-D12 exists to forbid — rebuilding underneath a live replay invalidates
  ## the trace being replayed.
  ##
  ## Exported so a test can assert the COUNT rather than the presence of one
  ## button, because "the edit toolbar rendered" is satisfied by a toolbar that
  ## silently dropped three of its four controls.
  for candidate in model.buttons:
    if candidate.action in model.actions:
      result.add candidate

proc invoker(invoke: proc(id: string); id: string): proc() =
  ## One click handler, closed over ONE id.
  ##
  ## This is a proc rather than `proc() = invoke(candidate.id)` written inline
  ## in the loop, and the difference is not style. A closure created in a `for`
  ## body captures the loop's environment, not a per-iteration copy, so every
  ## handler ends up reading the LAST button's id: one toolbar, four buttons,
  ## and every one of them runs Record Tests. Passing the id as a PARAMETER
  ## gives each closure its own binding.
  ##
  ## Caught by EMT-V5 rather than reasoned about — the first version of this
  ## file did write the closure inline, the markup was correct in every
  ## structural check, and the click test reported the right NUMBER of
  ## invocations with the wrong ids in them.
  result = proc() = invoke(id)

proc buttonTitle*(candidate: ToolbarButton): string =
  ## What the pointer reveals. A DISABLED button must say why it is off — its
  ## `reason` is never empty when `not enabled` (EMT-D14/EMT-A28) — and an
  ## enabled one shows the exact command line, which is also what §7.2's
  ## confirmation shows before a `cpConventional` command is run.
  if not candidate.enabled and candidate.reason.len > 0: candidate.reason
  elif candidate.tooltip.len > 0: candidate.tooltip
  elif candidate.commandLine.len > 0: candidate.commandLine
  else: candidate.label

# ---------------------------------------------------------------------------
# MockRenderer panel — headless, for `vm-unit` and `vm-unit-js`
# ---------------------------------------------------------------------------

proc renderEditModeToolbarPanel*(r: MockRenderer;
                                 model: EditToolbarModel;
                                 invoke: proc(id: string)): MockNode =
  ## Structure:
  ##   div.edit-mode-toolbar[data-topbar-surface=edit-commands]
  ##     button#<id>.edit-toolbar-button[disabled when not enabled]  <label>
  let buttons = model.visibleButtons

  ui(r):
    tdiv(class = "edit-mode-toolbar",
         `data-topbar-surface` = EditToolbarSurfaceValue,
         `data-button-count` = $buttons.len):
      for candidate in buttons:
        # `id` and `label` are captured per iteration: the click handler must
        # close over THIS button's id, not over the loop variable's last value.
        let id = candidate.id
        let label = candidate.label
        let title = candidate.buttonTitle
        # Two arms rather than a computed `disabled=` value, because a browser
        # treats ANY value of `disabled` — including "" and "false" — as
        # disabled. The attribute has to be absent, not empty.
        if candidate.enabled:
          button(class = "edit-toolbar-button", id = id, title = title,
                 onclick = invoker(invoke, id)):
            text label
        else:
          button(class = "edit-toolbar-button", id = id, title = title,
                 disabled = "true"):
            text label

# ---------------------------------------------------------------------------
# WebRenderer panel — the shipped one
# ---------------------------------------------------------------------------

when defined(js):

  proc renderEditModeToolbarPanel*(r: WebRenderer;
                                   model: EditToolbarModel;
                                   invoke: proc(id: string)):
                                  isonim_dom.Element =
    ## The same structure the mock renders, in the classes the debug panel
    ## already uses (`ct-header`, `separate-bar`) so the topbar keeps one look
    ## across a mode switch rather than announcing the transition with a
    ## different-shaped bar.
    let buttons = model.visibleButtons

    ui(r):
      tdiv(class = "ct-header edit-mode-toolbar",
           `data-topbar-surface` = EditToolbarSurfaceValue,
           `data-button-count` = $buttons.len):
        tdiv(class = "separate-bar"):
          discard
        for candidate in buttons:
          let id = candidate.id
          let label = candidate.label
          let title = candidate.buttonTitle
          if candidate.enabled:
            button(id = id,
                   class = "ct-button-text-md-secondary edit-toolbar-button",
                   title = title,
                   onclick = invoker(invoke, id)):
              text label
          else:
            button(id = id,
                   class = "ct-button-text-md-secondary edit-toolbar-button",
                   title = title,
                   disabled = "true"):
              text label

  proc mountIsoNimEditModeToolbar*(container: isonim_dom.Element;
                                   model: EditToolbarModel;
                                   invoke: proc(id: string)) =
    ## Mount the edit-mode topbar as a child of `container`.
    ##
    ## The caller clears the host first — `ui/debug.nim`'s `doMount` does, for
    ## the reason its own comment gives — so this appends rather than replaces.
    let r = WebRenderer()
    let panel = renderEditModeToolbarPanel(r, model, invoke)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
