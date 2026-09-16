## The Scene-1 live-edit panel: type a parameter value, watch the flame reshape.
##
## H4 gave the apply-edit command an action, a menu entry and a command-palette
## entry, and said in as many words that there was no widget for TYPING an edit
## — the edit arrived as the action's argument or from `CODETRACER_HCR_EDIT`.
## This is that widget. It is the smallest surface that makes the Scene-1 claim
## true from a user's side: a field you type `rise_speed=5.4` into, a line that
## tells you what the provider said about it, and a debounce so that typing
## produces a sequence of edits rather than one edit per keystroke.
##
## It is a LEAF MODULE — `std/jsffi` and `kdom`, nothing else — for the two
## reasons `file_conflict_dialog.nim` gives: `renderer.nim` cannot be loaded by
## a test, and the rule below is worth testing.
##
##   **The markup is a constant, and everything variable is TEXT.**
##
## Nothing here is cosmetic. The two variable things this panel displays are the
## command's `status`/`message` and the edit the user typed, and both are
## hostile inputs in the ordinary sense: the message is assembled from an agent
## refusal that quotes THREAD NAMES AND RELOCATION SYMBOLS out of a process this
## application did not build (`R_X86_64_REX_GOTPCRELX->ct_hcr4_unsupported_...`,
## `godot.l:disk$0`), and the edit is whatever was typed. So every one of them
## goes in through `textContent` and the markup below has no interpolation in
## it at all.
##
## WHAT THIS PANEL DOES NOT DECIDE. It does not compile, classify, publish or
## judge an edit, and it does not know what a knob is. It sends the string that
## was typed and renders the answer that comes back. H4's note about the main
## process forming no opinion applies here one layer further out: a second
## vocabulary maintained in the renderer would be a second vocabulary that can
## drift, and the one the user reads would be the wrong one.

when defined(js):
  import std/jsffi
  import kdom

  const HcrLiveEditPanelMarkup* = """
    <div class="hcr-live-edit-panel" role="dialog" aria-label="Live edit (HCR)">
      <h2>Live edit &mdash; hot code reload</h2>
      <p class="hcr-live-edit-hint">
        Type a parameter edit and the running program reshapes. No rebuild, no restart.
      </p>
      <label class="hcr-live-edit-label" for="hcr-live-edit-input">Edit</label>
      <input id="hcr-live-edit-input" class="hcr-live-edit-input" type="text"
             spellcheck="false" autocomplete="off"
             placeholder="rise_speed=5.4" data-hcr-live-edit-input />
      <div class="hcr-live-edit-row">
        <button type="button" class="hcr-live-edit-apply" data-action="apply">Apply now</button>
        <button type="button" class="hcr-live-edit-close" data-action="close">Close</button>
      </div>
      <p class="hcr-live-edit-status" data-hcr-live-edit-status></p>
      <p class="hcr-live-edit-detail" data-hcr-live-edit-detail></p>
    </div>
  """
    ## Constant. Nothing is interpolated into it, and `htmlSinks.test.mjs`
    ## pins the one `innerHTML` write that uses it.

  const HcrLiveEditDebounceMs* = 450
    ## How long typing must pause before an edit is published.
    ##
    ## Not a cosmetic delay and not tuning for its own sake. Each edit is a real
    ## clang++ invocation and a real publication over the coordinator wire —
    ## measured on the demo flame at roughly 0.3–0.4 s end to end — so a panel
    ## that fired per keystroke would queue a compile behind every character of
    ## `rise_speed=5.4` and the flame would walk through `5`, `5.`, `5.4` as
    ## three separate patches. 450 ms is longer than one publication and shorter
    ## than a deliberate pause, which is the property that makes typing read as
    ## one edit and stopping read as "apply this".

  proc buildHcrLiveEditPanel*(): kdom.Element =
    ## Build the panel. The caller wires `[data-action=...]`, the input, and
    ## appends the result to the document.
    let overlay = kdom.document.createElement(cstring"div")
    overlay.class = cstring"hcr-live-edit-backdrop"
    overlay.innerHTML = cstring(HcrLiveEditPanelMarkup)
    overlay

  proc setHcrLiveEditStatus*(overlay: kdom.Element; status: cstring;
                             detail: cstring) =
    ## Show the provider's own answer.
    ##
    ## `status` is the command's named outcome — `applied`,
    ## `edit-unknown-knob`, `refused-quiescence-signal-blocked` — and is shown
    ## verbatim, because those names ARE the edit-surface vocabulary and an
    ## operator shown "failed" has not been told which mistake they made.
    ## `detail` is the sentence underneath.
    ##
    ## Both are assigned with `textContent`. The refusal messages quote symbol
    ## names and thread names out of a foreign process; they are not markup and
    ## were never meant to be.
    if overlay.isNil:
      return
    let statusEl = overlay.toJs.querySelector(cstring"[data-hcr-live-edit-status]")
    if not statusEl.isNil:
      statusEl.textContent = status
    let detailEl = overlay.toJs.querySelector(cstring"[data-hcr-live-edit-detail]")
    if not detailEl.isNil:
      detailEl.textContent = detail

  proc hcrLiveEditValue*(overlay: kdom.Element): cstring =
    ## What is currently typed, or `""`.
    if overlay.isNil:
      return cstring""
    let input = overlay.toJs.querySelector(cstring"[data-hcr-live-edit-input]")
    if input.isNil:
      return cstring""
    cast[cstring](input.value)
