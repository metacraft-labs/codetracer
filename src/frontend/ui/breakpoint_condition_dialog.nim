## The "Edit breakpoint condition" dialog (Breakpoints-And-Tracepoints.md
## § Conditional breakpoints).
##
## One text field holding the breakpoint's condition. Enter or OK applies the
## field's text (an empty field clears the condition), Escape or Cancel
## closes it with the breakpoint as it was. A leaf module, like
## `file_conflict_dialog`: the markup is a constant, and the condition and
## the location are set as TEXT (`value`, `textContent`), never as markup.

when defined(js):
  import std/[jsffi, strutils]
  import kdom

  const BreakpointConditionDialogMarkup* = """
    <div class="breakpoint-condition-dialog" role="dialog" aria-modal="true"
         data-ct-dialog aria-labelledby="breakpoint-condition-title">
      <h2 id="breakpoint-condition-title" data-ct-dialog-title>Breakpoint condition</h2>
      <p class="breakpoint-condition-location" data-ct-dialog-message></p>
      <input type="text" class="breakpoint-condition-input" aria-label="condition"
             spellcheck="false" placeholder="Stop only when this expression is true">
      <div class="breakpoint-condition-actions">
        <button type="button" data-ct-dialog-button data-action="cancel">Cancel</button>
        <button type="button" data-ct-dialog-button data-action="apply">OK</button>
      </div>
    </div>
  """
    ## Constant: nothing is interpolated into it.

  var openOverlay: kdom.Element = nil

  proc closeBreakpointConditionDialog*() =
    if not openOverlay.isNil:
      let parent = openOverlay.parentNode
      if not parent.isNil:
        parent.removeChild(openOverlay)
      openOverlay = nil

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
    overlay.innerHTML = cstring(BreakpointConditionDialogMarkup)
    let o = overlay.toJs
    let locationEl = o.querySelector(cstring".breakpoint-condition-location")
    if not locationEl.isNil:
      locationEl.textContent = location
    let input = o.querySelector(cstring".breakpoint-condition-input")
    input.value = condition

    proc confirm() =
      let text = input.value.to(cstring)
      closeBreakpointConditionDialog()
      apply(cstring(($text).strip))

    input.addEventListener(cstring"keydown", proc(e: JsObject) =
      let key = e.key.to(cstring)
      if key == cstring"Enter":
        e.preventDefault()
        e.stopPropagation()
        confirm()
      elif key == cstring"Escape":
        e.preventDefault()
        e.stopPropagation()
        closeBreakpointConditionDialog())
    o.querySelector(cstring"[data-action='apply']").addEventListener(
      cstring"click", proc(e: JsObject) = confirm())
    o.querySelector(cstring"[data-action='cancel']").addEventListener(
      cstring"click", proc(e: JsObject) = closeBreakpointConditionDialog())
    # A press on the backdrop, outside the dialog, cancels.
    o.addEventListener(cstring"mousedown", proc(e: JsObject) =
      if e.target == o:
        closeBreakpointConditionDialog())

    kdom.document.body.appendChild(overlay)
    openOverlay = overlay
    discard input.focus()
    discard input.select()
