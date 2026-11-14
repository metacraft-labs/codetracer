## The "Edit breakpoint condition" dialog (Breakpoints-And-Tracepoints.md
## § Conditional breakpoints).
##
## One text field holding the breakpoint's condition. Enter or OK applies the
## field's text (an empty field clears the condition), Escape or Cancel
## closes it with the breakpoint as it was. A leaf module, like
## `file_conflict_dialog`: the markup is a constant, and the condition and
## the location are set as TEXT (`value`, `textContent`), never as markup.
##
## INPUT (Input-Routing-And-Keymaps.md §5.1, §6). The dialog holds no press
## handler: its backdrop is the `breakpointCondition` scope (`data-ct-pane`), OK and
## Cancel are buttons carrying their operations (`data-ct-operation`:
## `breakpoint-condition.apply`, `breakpoint-condition.cancel`), and the
## window's one pointer listener (`viewmodel/input/dom_pointer`, installed by
## the desktop's key router) resolves a press on them through the pointer
## keymap — a user's row for the press first — and runs the procedure this
## module registers for the operation. The field's Enter and Escape are the
## field's own keys (§6), read through the one decoder
## (`field_keys.fieldKeyOf`); Escape anywhere else in the window closes the
## dialog through `dismissals`, as every transient surface does. A press on
## the backdrop is an `overlay` element's, carrying
## `breakpoint-condition.cancel`, so it is routed like the buttons.

const
  BreakpointConditionApply* = "breakpoint-condition.apply"
    ## OK's operation: apply the field's text as the condition.
  BreakpointConditionCancel* = "breakpoint-condition.cancel"
    ## Cancel's operation: close, the breakpoint as it was.

when defined(js):
  import std/[jsffi, strutils]
  import kdom
  import ../viewmodel/input/dom_pointer
  import ../viewmodel/keymap/scope_path
  import ../viewmodel/views/[field_keys, dismissals]

  const BreakpointConditionDialogMarkup* = """
    <div class="breakpoint-condition-dialog" role="dialog" aria-modal="true"
         data-ct-dialog aria-labelledby="breakpoint-condition-title">
      <h2 id="breakpoint-condition-title" data-ct-dialog-title>Breakpoint condition</h2>
      <p class="breakpoint-condition-location" data-ct-dialog-message></p>
      <input type="text" class="breakpoint-condition-input" aria-label="condition"
             spellcheck="false" placeholder="Stop only when this expression is true">
      <div class="breakpoint-condition-actions">
        <button type="button" data-ct-dialog-button data-action="cancel"
                data-ct-operation="breakpoint-condition.cancel">Cancel</button>
        <button type="button" data-ct-dialog-button data-action="apply"
                data-ct-operation="breakpoint-condition.apply">OK</button>
      </div>
    </div>
  """
    ## Constant: nothing is interpolated into it. Its scope and operation
    ## names are spelled out; the static block below holds them to the
    ## constants the router and the procedures use.

  static:
    doAssert ("data-ct-operation=\"" & BreakpointConditionApply & "\"") in
      BreakpointConditionDialogMarkup
    doAssert ("data-ct-operation=\"" & BreakpointConditionCancel & "\"") in
      BreakpointConditionDialogMarkup
    doAssert OperationAttribute == "data-ct-operation"

  var
    openOverlay: kdom.Element = nil
    openInput: JsObject = nil
      ## The open dialog's field.
    openApply: proc(condition: cstring) = nil
      ## The open dialog's caller's apply.
    proceduresRegistered = false

  proc closeBreakpointConditionDialog*() =
    if not openOverlay.isNil:
      let parent = openOverlay.parentNode
      if not parent.isNil:
        parent.removeChild(openOverlay)
      openOverlay = nil
      openInput = nil
      openApply = nil

  proc dismiss(): bool =
    ## Escape on the window while the dialog is open (`dismissals`).
    if openOverlay.isNil:
      return false
    closeBreakpointConditionDialog()
    true

  proc confirmBreakpointCondition(): bool =
    ## `breakpoint-condition.apply`: the field's text, trimmed, to the
    ## caller; false when no dialog is open.
    if openOverlay.isNil or openInput.isNil:
      return false
    let text = openInput.value.to(cstring)
    let apply = openApply
    closeBreakpointConditionDialog()
    if not apply.isNil:
      apply(cstring(($text).strip))
    true

  proc cancelBreakpointCondition(): bool =
    ## `breakpoint-condition.cancel`: close; false when none is open.
    if openOverlay.isNil:
      return false
    closeBreakpointConditionDialog()
    true

  proc registerBreakpointConditionProcedures*() =
    ## The procedures the window's pointer listener runs for a press that
    ## resolved to OK's or Cancel's operation, and how Escape closes the
    ## dialog (`dismissals`). Registered once, on the first show; each acts
    ## on the dialog open when the press comes, and answers false when none
    ## is.
    if proceduresRegistered:
      return
    proceduresRegistered = true
    registerDismissal(dismiss)
    registerElementOperation(BreakpointConditionApply,
      proc(p: ElementPress): bool = confirmBreakpointCondition())
    registerElementOperation(BreakpointConditionCancel,
      proc(p: ElementPress): bool = cancelBreakpointCondition())
    # A press on the backdrop, outside the dialog, cancels: the backdrop is an
    # `overlay` element carrying `breakpoint-condition.cancel`, named by this
    # hit test (no selector can tell the backdrop from the dialog on it), and
    # pressed on the press, as it always was, so a text selection dragged out
    # of the field and released over the backdrop does not cancel.
    registerHitTest(BreakpointConditionScope, proc(target, ev: JsObject): ElementHit =
      if not openOverlay.isNil and target == openOverlay.toJs:
        ElementHit(element: target, kind: "overlay",
                   operation: BreakpointConditionCancel, pressDown: true)
      else:
        ElementHit())

  proc breakpointConditionDialogOpen*(): bool =
    not openOverlay.isNil

  proc showBreakpointConditionDialog*(location, condition: cstring;
                                      apply: proc(condition: cstring)) =
    ## Open the dialog for the breakpoint at `location` (shown as text),
    ## its field holding `condition`. `apply` gets the field's text, trimmed,
    ## when the user confirms; nothing is called on cancel.
    closeBreakpointConditionDialog()
    let overlay = kdom.document.createElement(cstring"div")
    overlay.class = cstring"breakpoint-condition-dialog-backdrop"
    # The backdrop is the dialog's scope: its buttons and the backdrop itself
    # are pressed in it.
    overlay.setAttribute(cstring"data-ct-pane", cstring(BreakpointConditionScope))
    overlay.innerHTML = cstring(BreakpointConditionDialogMarkup)
    let o = overlay.toJs
    let locationEl = o.querySelector(cstring".breakpoint-condition-location")
    if not locationEl.isNil:
      locationEl.textContent = location
    let input = o.querySelector(cstring".breakpoint-condition-input")
    input.value = condition
    openInput = input
    openApply = apply
    registerBreakpointConditionProcedures()

    # The field's own keys (§6): Enter applies, Escape cancels.
    input.addEventListener(cstring(KeyDownEvent), proc(e: JsObject) =
      let answer =
        case fieldKeyOf($e.key.to(cstring))
        of fkCommit: confirmBreakpointCondition()
        of fkCancel: cancelBreakpointCondition()
        else: false
      if answer:
        e.preventDefault()
        e.stopPropagation())

    kdom.document.body.appendChild(overlay)
    openOverlay = overlay
    discard input.focus()
    discard input.select()
