## Mock-renderable ct-test editor controls.
##
## The records rendered here are intentionally plain DOM metadata. Monaco can
## later consume the same attributes to mount gutter glyphs or view zones.

import isonim/dsl/ui
import isonim/core/computation
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/editor_test_controls_vm

proc markersAttr(markers: seq[EditorLineMarkerKind]): string =
  for i, marker in markers:
    if i > 0:
      result.add ","
    result.add $marker

proc buttonText(action: EditorTestControlAction): string =
  case action.kind
  of etcakRun: "Run"
  of etcakRecord: "Record"
  of etcakOpenLastTrace: "Open"
  of etcakStatus:
    if action.status.len == 0: "idle" else: action.status

template renderEditorTestControlsImpl(r, plan: untyped): untyped =
  ui(r):
    tdiv(class = "ct-test-editor-controls",
         `data-ct-test-controls` = "true",
         `data-ct-test-file` = plan.file,
         `data-ct-test-placement` = $plan.placement,
         `data-ct-test-scroll-anchor-before` = $plan.scrollAnchorBefore,
         `data-ct-test-scroll-anchor-after` = $plan.scrollAnchorAfter):
      for controlIndex in 0 ..< plan.controls.len:
        let control = plan.controls[controlIndex]
        tdiv(class = "ct-test-control " & $control.surface,
             `data-ct-test-control` = "true",
             `data-ct-test-surface` = $control.surface,
             `data-ct-test-id` = control.testId,
             `data-ct-test-selector` = control.selector,
             `data-ct-test-line` = $control.line,
             `data-ct-test-gutter-slot` = $control.gutterSlot,
             `data-ct-test-collision-markers` = markersAttr(control.collisionMarkers)):
          for actionIndex in 0 ..< control.actions.len:
            let action = control.actions[actionIndex]
            button(class = "ct-test-action " & $action.kind,
                   `data-ct-test-action` = $action.kind,
                   `data-ct-test-command` = action.commandName,
                   `data-ct-test-enabled` = $action.enabled,
                   `data-ct-test-status` = action.status,
                   `aria-label` = action.ariaLabel,
                   title = action.ariaLabel):
              text buttonText(action)

proc renderEditorTestControls*(r: MockRenderer;
                               plan: EditorTestControlRenderPlan): MockNode =
  renderEditorTestControlsImpl(r, plan)

when defined(js):
  proc renderEditorTestControls*(r: WebRenderer;
                                 plan: EditorTestControlRenderPlan):
                                 isonim_dom.Element =
    renderEditorTestControlsImpl(r, plan)
