## ui/origin_badge.nim
##
## Shared origin-badge renderer used by every value-rendering surface
## per spec §3.2.3 (State Pane locals / watches / history popover,
## Omniscience-Flow overlay, Scratchpad pinned entries, editor hover
## card). The badge is a compact `(terminator-icon, short-expr)`
## affordance that pops the origin chain inline when clicked
## (spec §3.2.1).
##
## All six surfaces share one DOM contract:
##
##   <button class="ct-origin-badge {iconClass}" data-token=…
##           aria-label="Value origin: <expr>">
##     <span class="ct-origin-badge-icon"/>
##     <span class="ct-origin-badge-text">…middle-ellipsis…</span>
##     <span class="ct-origin-badge-fn">@ <function></span> <!-- optional -->
##   </button>
##
## or, for placeholder summaries (spec §3.2.1 placeholder state):
##
##   <button class="ct-origin-badge ct-origin-badge-placeholder"
##           data-token="…" aria-label="Resolve placeholder origin">
##     <span class="ct-origin-badge-text">[?]</span>
##   </button>
##
## The badge is intentionally an HTML `<button>` so screen readers
## announce the disclosure semantics (spec §13.0 accessibility).
##
## ON RUNTIME: this module is `when defined(js)` because the rendering
## helpers touch `dom.Node`. The pure-Nim helpers (badge text /
## aria-label / class derivation) live in `viewmodel/viewmodels/
## origin_chain_types.nim` so the headless tests can assert on them
## without pulling in the DOM.

import std/options

import ../viewmodel/viewmodels/origin_chain_types

# Re-export the helpers so callers can `import ui/origin_badge` and
# get both the rendering procs (when on JS) and the pure logic
# helpers in one place. The pure-logic helpers
# (``ariaLabelForSummary``, ``badgeClassFor``, ``tokenForSummary``,
# the ``BadgeBaseClass`` / ``BadgePlaceholderClass`` / etc. constants)
# moved into ``viewmodel/viewmodels/origin_chain_types`` (M4 fix-up
# round) so the renderer-agnostic IsoNim views can use them without
# pulling ``std/dom`` into the native compile target.
export origin_chain_types

# ---------------------------------------------------------------------------
# DOM rendering (JS-only). The Karax-based surfaces (`state.nim`,
# `value.nim`, `flow.nim`, `editor.nim`, `scratchpad.nim`) call into
# `renderBadgeDom` to attach the badge to a pre-existing parent node.
# ---------------------------------------------------------------------------

when defined(js):
  import std/dom

  proc renderBadgeDom*(parent: Node;
                       summary: OriginSummary;
                       prefs: OriginPreferences;
                       atSidePanel: bool = false;
                       iconOnly: bool = false;
                       onClick: proc(token: string) = nil): Node {.discardable.} =
    ## Append a badge element to `parent` and return the created
    ## button. The click handler is invoked with the placeholder
    ## token (empty string when the badge is already resolved).
    let button = document.createElement(cstring"button")
    button.setAttribute(cstring"class", cstring(badgeClassFor(summary, iconOnly)))
    button.setAttribute(cstring"aria-label",
                        cstring(ariaLabelForSummary(summary, prefs, atSidePanel)))
    if summary.isPlaceholder:
      let token = tokenForSummary(summary)
      if token.len > 0:
        button.setAttribute(cstring"data-token", cstring(token))
    # Icon
    let iconSpan = document.createElement(cstring"span")
    iconSpan.setAttribute(cstring"class", cstring(BadgeIconClass))
    button.appendChild(iconSpan)
    # Text — collapsed to "[?]" for placeholders by badgeTextForSummary
    let textSpan = document.createElement(cstring"span")
    textSpan.setAttribute(cstring"class", cstring(BadgeTextClass))
    textSpan.innerText = cstring(badgeTextForSummary(summary, prefs, atSidePanel))
    if not iconOnly:
      button.appendChild(textSpan)
    # Optional `@ function_name` suffix is folded into the badge text
    # by `badgeTextForSummary`; rendering it as a separate <span>
    # would risk drift between the visible string and the ARIA label
    # so we keep it concatenated.
    if not onClick.isNil:
      let handler = proc(ev: Event) =
        let tok =
          if summary.isPlaceholder: tokenForSummary(summary)
          else: ""
        onClick(tok)
      button.addEventListener(cstring"click", handler)
    parent.appendChild(button)
    button
