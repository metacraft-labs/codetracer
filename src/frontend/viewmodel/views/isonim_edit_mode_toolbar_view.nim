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
## The two surfaces differ in which elements exist, not in an attribute, so
## the topbar host chooses between two views: `renderTopbar`
## (`isonim_debug_controls_view.nim`) shows this one or the debugger controls
## with `show` over `DebugControlsVM.topbarSurface`.
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
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/edit_mode_toolbar
import ./edit_toolbar_marks
export edit_toolbar_marks
# A generic view is instantiated where it is called, and the `ui` macro's
# expansion names `createRenderEffect` and the control-flow components there:
# exported so a caller needs no IsoNim import of its own to render this view.
export computation, components

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

func editButtonClass*(buttonId: string): string =
  ## Which button variant this id is drawn as.
  ##
  ## The distinction is NOT cosmetic and the two spellings are not
  ## interchangeable. `[class*="ct-button-image-"]` is what carries
  ## `background-position`, `background-size`, `background-repeat` and the
  ## centring that an icon button needs; `[class*="ct-button-text-md-"]` is
  ## what carries the padding a label needs. A button that takes the wrong one
  ## does not merely look off — a text button with the image rules is how
  ## `#run-tests-image` came to tile a 21x16 asset across the words "Run
  ## Tests" on the shipped bar.
  ##
  ## Keyed on whether a mark EXISTS for the id, so the class and the glyph can
  ## never disagree: adding a mark to `EditToolbarMarks` is the single edit
  ## that turns a button into an icon button.
  ##
  ## Exported so a test can ask the same question the view asks rather than
  ## hard-coding the answer — the class the view emits and the class the
  ## stylesheet selects drifting apart is the defect this whole surface
  ## already shipped once.
  ##
  ## ## `ct-button-no-border`, and why it was the missing one
  ##
  ## Reported as *"the debugging control icons designed by our designer don't
  ## have rectangular frames; the icons you created for build and run should
  ## not have either"*. Measured rather than guessed: on the compiled theme —
  ## the byte-identical one noirstudio.dev serves — a debugger-strip button
  ## computes `border: 0px none` and a button on this bar computed
  ## `border: 1px solid rgb(86, 86, 86)`. That 1px IS the frame.
  ##
  ## It arrives from `[class*="-button-"][class*="-secondary"]` in
  ## `components/button.styl`, which every icon button on BOTH surfaces
  ## carries. The debugger strip cancels it per button with
  ## `ct-button-no-border` (`border: none !important`) — twelve times, in
  ## `isonim_debug_controls_view` — and this bar simply never adopted that
  ## half of the convention. So the frame was not drawn by the marks, and no
  ## amount of reading `edit_toolbar_marks.nim` could have found it: the SVG
  ## contains no rectangle and never did.
  ##
  ## Cancelled HERE, in the emitted class, rather than with a `border: none`
  ## in the `.edit-mode-toolbar` block, for the reason the strip already
  ## demonstrates: the border is applied by a class, so it is cancelled by a
  ## class, and the two surfaces then say "no frame" in one vocabulary instead
  ## of two. A stylesheet-side override would also be a rule that the next
  ## `!important` quietly wins against.
  ##
  ## The `-secondary` background (`colors-ui-surface-primary-default`) is left
  ## alone deliberately: it computed `rgb(27, 27, 27)` on both surfaces, which
  ## is the bar's own colour, so it paints nothing. Only the border was
  ## visible, and only the border is removed.
  if hasEditMark(buttonId):
    "ct-button-image-md-secondary ct-button-no-border edit-toolbar-button"
  else:
    "ct-button-text-md-secondary ct-button-no-border edit-toolbar-button"

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
# The panel — one view, generic over the renderer
# ---------------------------------------------------------------------------

proc renderEditModeToolbarPanel*[R, N](r: R; model: proc(): EditToolbarModel;
                                       invoke: proc(id: string)): N =
  ## The edit-mode topbar, in the classes the debugger strip uses
  ## (`ct-header`, `separate-bar`) so the topbar keeps one look across a mode
  ## switch:
  ##   div.ct-header.edit-mode-toolbar[data-topbar-surface=edit-commands]
  ##     button#<id>.edit-toolbar-button[disabled when not enabled]  <label>
  ##
  ## `model` is read reactively: the platform installs a NEW model whenever
  ## something that could change it happens (a save that adds a `Nargo.toml`,
  ## a build finishing), and the buttons follow it in place — keyed by the
  ## button itself, so an unchanged button keeps its node.
  ##
  ## A button that carries a mark has no label: its glyph is attached on the
  ## web renderer (`edit_toolbar_marks`), and the headless structure has the
  ## same buttons with the same absence of text.
  var buttonsHost: N
  let panel = ui(r):
    tdiv(class = "ct-header edit-mode-toolbar",
         `data-topbar-surface` = EditToolbarSurfaceValue,
         `data-button-count` = $model().visibleButtons.len):
      tdiv(class = "separate-bar"):
        discard
      tdiv(ref = buttonsHost, class = "edit-toolbar-buttons"):
        discard
  createRenderEffect proc() =
    r.setAttribute(panel, "data-button-count", $model().visibleButtons.len)
  forEachKeyed[ToolbarButton, R, N](r, buttonsHost,
    proc(): seq[ToolbarButton] = model().visibleButtons,
    proc(item: proc(): ToolbarButton; index: proc(): int): N =
      let candidate = item()
      let id = candidate.id
      let cls = editButtonClass(id)
      let title = candidate.buttonTitle
      var btn: N
      if candidate.enabled:
        btn = ui(r):
          button(id = id, class = cls, title = title,
                 onclick = invoker(invoke, id)):
            discard
      else:
        btn = ui(r):
          button(id = id, class = cls, title = title, disabled = "true"):
            discard
      if not hasEditMark(id):
        r.appendChild(btn, r.createTextNode(candidate.label))
      when defined(js):
        when N is isonim_dom.Element:
          attachEditMark(btn, id)
      btn)
  panel
