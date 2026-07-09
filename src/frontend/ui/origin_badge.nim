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

when defined(js):
  import std/[json, jsffi]

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
        ev.preventDefault()
        ev.stopPropagation()
        let tok =
          if summary.isPlaceholder: tokenForSummary(summary)
          else: ""
        onClick(tok)
      button.addEventListener(cstring"click", handler)
    parent.appendChild(button)
    button

  # ---------------------------------------------------------------------------
  # Wire-shape helpers — extract `originSummary` from a raw JS object.
  #
  # The Nim-side typed wire objects (``Variable`` in
  # ``common_types/language_features/value.nim``,
  # ``HistoryResult`` in
  # ``common_types/language_features/value_history.nim``,
  # ``FlowStep`` in ``common_types/codetracer_features/flow.nim``)
  # do NOT yet carry an ``originSummary`` field — adding it would
  # ripple through every consumer.  The Rust serde-derived wire
  # JSON carries the field unconditionally (per spec §4.1 +
  # ``task::Variable``/``task::HistoryResult``/``task::FlowStep``),
  # so the field is present on the JsObject behind every Nim
  # ref-object and we recover it lazily through ``toJs``.
  #
  # Both surfaces (history popover in ``ui/value.nim``,
  # omniscience-flow overlay in ``ui/flow.nim``) call this helper
  # immediately before rendering the badge so the JS-side wire
  # contract drift is contained to a single proc.
  # ---------------------------------------------------------------------------

  proc jsObjectToJson(raw: JsObject): cstring {.importjs: "JSON.stringify(#)".}
    ## Round-trip a JsObject to its JSON serialisation.  Mirrors the
    ## helper of the same name in ``ui/state.nim::syncOriginSummaries``
    ## but is exported here so every value-rendering surface can reach
    ## it.

  proc extractOriginSummary*(raw: JsObject): Option[OriginSummary] =
    ## Decode the ``originSummary`` field carried by a wire-shape
    ## JsObject (``Variable`` / ``HistoryResult`` / ``FlowStep``
    ## value-map entry).  Returns ``none`` when the field is absent,
    ## ``null``, or fails JSON parsing — every caller must tolerate
    ## the empty case (older backends, non-materialized traces).
    if raw.isNil or raw.isUndefined:
      return none(OriginSummary)
    let summaryRaw = raw[cstring("originSummary")]
    if summaryRaw.isNil or summaryRaw.isUndefined:
      return none(OriginSummary)
    try:
      let asJson = parseJson($jsObjectToJson(summaryRaw))
      some(parseOriginSummary(asJson))
    except CatchableError, Defect:
      none(OriginSummary)

  proc extractOriginSummaryMap*(raw: JsObject): seq[(string, OriginSummary)] =
    ## Decode a wire-shape ``HashMap<String, OriginSummary>``
    ## (``FlowStep.origin_summaries``) into a sequence of typed
    ## ``(name, summary)`` pairs.  Returns an empty seq when the field
    ## is absent / not an object.  Each entry's value is parsed
    ## through ``parseOriginSummary`` so callers receive properly-
    ## typed records.
    result = @[]
    if raw.isNil or raw.isUndefined:
      return
    try:
      let asJson = parseJson($jsObjectToJson(raw))
      if asJson.kind != JObject:
        return
      for key, value in asJson.pairs:
        result.add((key, parseOriginSummary(value)))
    except CatchableError, Defect:
      discard

  # ---------------------------------------------------------------------------
  # IntersectionObserver-driven batch fill (spec §3.2.3 V1 default
  # "originDisplay.batchFillVisible: on").  Observed placeholder
  # badges enqueue their token via the host-provided callback when
  # they enter the viewport.  The host owns the debounced
  # ``ct/originSummary`` flush — typically wired to
  # ``OriginChainVM.enqueuePlaceholderFill`` +
  # ``flushPlaceholderFill`` per the
  # ``originDisplay.batchFillThrottleMs`` preference.
  #
  # The observer is created lazily on first call so the surfaces
  # don't have to import ``std/dom`` to construct it.  Browser
  # support for ``IntersectionObserver`` is universal across the
  # Chromium/Electron versions the app targets, so no polyfill is
  # required.
  # ---------------------------------------------------------------------------

  type
    BadgeIntersectionCallback* = proc(token: cstring)
      ## Invoked once per badge as it enters the viewport.  The badge
      ## element is also un-observed at that point so a re-scroll
      ## does not re-fire the callback.

  proc createBadgeIntersectionObserver*(
      onEnter: BadgeIntersectionCallback): JsObject {.discardable.} =
    ## Construct an ``IntersectionObserver`` that watches placeholder
    ## badge ``<button>`` elements.  When a badge intersects the
    ## viewport the callback receives the badge's ``data-token`` value.
    ## The badge is then un-observed so we never re-fire for the same
    ## token (the host's de-dup happens at the queue layer anyway —
    ## belt-and-braces).
    ##
    ## The observer instance is returned so the caller can hold a
    ## reference for the duration of the surface's lifetime; dropping
    ## the reference causes the runtime to disconnect the observer.
    let cb = proc(entries: JsObject, observer: JsObject) =
      let count = entries.length.to(int)
      for i in 0 ..< count:
        let entry = entries[i]
        let isIntersecting = entry.isIntersecting.to(bool)
        if not isIntersecting:
          continue
        let target = entry.target
        if target.isNil:
          continue
        # Use the JsObject ``getAttribute`` shim so the proc compiles
        # on the JS target without an explicit ``dom.Node`` cast —
        # ``target`` here is the IO ``entry.target`` which can be any
        # ``Element`` subclass.
        let tokenJs = target.getAttribute(cstring"data-token")
        # Un-observe immediately so the same badge does not re-fire
        # if the user scrolls back to it.  The host's queue de-dups
        # anyway but un-observing keeps the IO's tracking set small.
        discard observer.unobserve(target)
        if tokenJs.isNil:
          continue
        let token = tokenJs.to(cstring)
        if token.isNil:
          continue
        if ($token).len > 0:
          onEnter(token)
    # The options object: rootMargin + threshold keep the observer
    # firing slightly before the badge is fully in view so the round-
    # trip latency is masked by the user's scroll inertia.
    let opts = newJsObject()
    opts["rootMargin"] = cstring"50px"
    opts["threshold"] = 0.0
    {.emit: """
    var IO = window.IntersectionObserver;
    if (IO) {
      `result` = new IO(`cb`, `opts`);
    } else {
      `result` = null;
    }
    """.}

  proc observeBadgeForLazyFill*(observer: JsObject; badge: Node) =
    ## Register `badge` (a placeholder ``<button class="ct-origin-badge
    ## ct-origin-badge-placeholder">``) with the lazy-fill observer.
    ## Safe to call on non-placeholder badges; the observer simply
    ## fires the enter callback unconditionally and the host's queue
    ## de-dups when the token is empty.
    if observer.isNil:
      return
    if badge.isNil:
      return
    discard observer.observe(badge)
