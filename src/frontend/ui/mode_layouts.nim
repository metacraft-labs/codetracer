## ONE LAYOUT PER MODE: the register, its defaults, and where it is kept.
##
## `GUI/Layout-And-Navigation/Mode-Transitions.md` §4 states the rule this
## module exists to implement — "each mode has its own layout, and each is the
## user's", restored on the way in, preserved on the way out, written to its
## mode's own store rather than only held in memory, and swapped together with
## the mode or not at all. Everything here is one of those four sentences.
##
## ## What was here before, and why it could not satisfy §6
##
## Two fields on `data.ui`, each a single slot:
##
##   * `lastUsedEditLayout` — written by `switchToDebug`, read by `switchToEdit`
##   * `savedLayoutBeforeEdit` — written by `switchToEdit`, read by
##     `switchToDebug`, and its read arm was *disabled*, with a comment
##     recording that enabling it degraded the workspace over three round trips
##     (`ci/test/noir-mode-roundtrip.sh`: 19 failures against 7).
##
## `Mode-Transitions.md` §6 names this shape in advance and says why it fails:
## "a single 'saved layout' slot filled on the way out and consumed on the way
## back — correct for one round trip, and thereafter holding either nothing or
## the wrong mode's arrangement". The disabled arm is that prediction, measured.
##
## The fix is not a third slot. It is to stop having slots: a mode's layout is
## addressed BY THE MODE, so a transition names which mode it is leaving and
## which it is entering, and no field can be the wrong mode's by construction.
## `ModeLayouts` is an `array[LayoutMode, ...]`, so a mode added to
## `LayoutMode` gets a cell without anyone remembering to give it one.
##
## ## Why the register is not enough on its own
##
## §4.3: "the preserved layout is written to its mode's layout file, not only
## held in memory. An in-memory snapshot is lost if the window reloads, and the
## user cannot tell which of their two arrangements the reload kept."
##
## The desktop already had this half and the web had none of it. A browser tab
## was documented as "always a first-ever launch — it has no user layout
## directory and never will" (`ui/web_entry_surface.nim`), which is true about
## a *directory* and was taken to settle the question about *persistence*. So
## every arrangement a web user made was discarded by the next reload, and the
## half of the request that says "saved between sessions" was missing entirely
## on the platform it was reported from. `localStorage` is the store, for the
## reasons `ui/shortcut_preference.nim` gives about the shortcut preset: a
## device-local UI preference, small, wanted synchronously at boot, and
## deliberately NOT the OPFS project volume, which holds the user's FILES and
## whose absence must never cost them a layout.
##
## ## The degradation rule, which is a hard requirement and not a nicety
##
## A saved layout that cannot be loaded has already produced a total failure in
## this product: after Stop the workspace came back EMPTY, because `loadLayout`
## threw and the last tier of `ui/layout.loadLayoutSafely` is "continue with an
## empty GoldenLayout". An empty workspace is indistinguishable from having
## lost the session.
##
## So: `layoutForMode` is TOTAL. There is no argument for which it yields
## nothing — the worst case is the mode's bundled default, which is a working
## workspace. And when it degrades it does so LOUDLY, through
## `describeDegradation`, which the caller raises as a notification rather than
## a console line the user will never see. A silent fallback to the default is
## how a user loses an arrangement and concludes the product forgets things at
## random.

import
  std/[jsffi, options],
  ./ui_imports,
  ../index/layout_config_repair

# ---------------------------------------------------------------------------
# The bundled default, per mode
# ---------------------------------------------------------------------------

const bundledModeLayoutJson = staticRead("../../config/default_layout.json")
  ## The same `src/config/default_layout.json` the rest of the tree reads.
  ##
  ## This is a fourth `staticRead` of one file and deliberately the LAST one:
  ## `ui/web_entry_surface.noirStudioEditLayout` and `.noirStudioDebugLayout`
  ## now delegate here rather than sanitising their own copy, so the number of
  ## places that turn the bundled tree into a mode's layout went from three to
  ## one. What matters is not the count of reads — deleting the file breaks
  ## every build at compile time either way — but the count of places that can
  ## disagree about what a mode's layout IS, and that is now one.

proc parseLayoutJsonOrNil*(raw: cstring): js {.importjs:
  """(function(raw) {
    try { return JSON.parse(raw); } catch (error) { return null; }
  })(#)""".}
  ## `JSON.parse` that answers `null` instead of throwing. A throw at renderer
  ## module-init takes the whole bundle down before anything mounts, which is
  ## the failure mode every reader of the bundled layout is written against.

proc bundledLayoutForMode*(mode: LayoutMode): js =
  ## The mode's default layout: the bundled tree, with what this mode does not
  ## show removed and what this mode homes elsewhere moved.
  ##
  ## One function of the mode, which is the point. It replaces a pair of procs
  ## — one per mode, each naming its own hidden set — whose only structural
  ## difference was `editModeHiddenContentIds()` versus the literal `@[]`, and
  ## which therefore had no way to express any per-mode difference that was not
  ## a suppression. A third mode needed a third proc; now it needs a row in
  ## `modeHiddenContentIds` and a row in `paneHomesForMode`.
  ##
  ## `nil` only if the bundled JSON itself does not parse, which is a build
  ## defect rather than a runtime condition — the file is `staticRead`, so it
  ## is the same bytes on every launch. Callers still check, because the
  ## alternative is a `TypeError` thirty frames away.
  let bundled = parseLayoutJsonOrNil(cstring(bundledModeLayoutJson))
  if bundled.isNil:
    return nil
  modeDefaultLayoutConfig(bundled, ord(Content.EditorView),
                          modeHiddenContentIds(mode), paneHomesForMode(mode))

proc layoutComponents*(layout: js): seq[tuple[content: int, id: int]] =
  ## Every `genericUiComponent` a layout config names, as (content id, dom id).
  ##
  ## `renderer.createUIComponents` walks the resolved config once at startup; a
  ## layout installed LATER has to have its components constructed by hand
  ## first, or GoldenLayout builds containers with nothing behind them —
  ## measured on the web Run path as "the layout visibly switched, the panes
  ## came up empty, and uncaught page errors went from 1 to 11".
  ##
  ## Every mode switch that falls back to a mode's default installs a layout
  ## later, so this walk is not the web's business and has moved here from
  ## `ui/web_entry_surface.nim` (which re-exports it, so its callers are
  ## unaffected). Exposed rather than re-implemented per call site, so nobody
  ## traverses the tree a second way and gets a different answer from the one
  ## the renderer would have given.
  result = @[]
  var found = newSeq[tuple[content: int, id: int]]()
  proc visit(node: js) =
    if node.isNil or node.isUndefined: return
    let state = node.componentState
    if not state.isNil and not state.isUndefined:
      let content = state.content
      if not content.isNil and not content.isUndefined:
        let id = state.id
        found.add (content: cast[int](content),
                   id: (if id.isNil or id.isUndefined: 0 else: cast[int](id)))
    let children = node.content
    if children.isNil or children.isUndefined: return
    let count = cast[int](children.length)
    for i in 0 ..< count:
      visit(children[i])
  if layout.isNil:
    return found
  # A RESOLVED config has no `root` wrapper and an unresolved one does, and
  # this proc is handed both — the register holds resolved configs and the
  # bundled default is unresolved. Walking only `layout.root` returned an
  # EMPTY list for the resolved case, and an empty list is indistinguishable
  # from "this layout declares no panes": the caller then constructs nothing
  # and every pane comes up blank, which is the failure this walk exists to
  # prevent, arriving through the walk itself.
  let root = layout.root
  visit(if root.isNil or root.isUndefined: layout else: root)
  result = found

# ---------------------------------------------------------------------------
# Where a mode's layout is kept between sessions
# ---------------------------------------------------------------------------

func isEditingMode*(mode: LayoutMode): bool =
  ## Whether `mode` is one of the modes that persists to the EDIT store.
  ##
  ## The desktop's two files are `default_edit_layout.json` and
  ## `default_layout.json`, so the store is binary while `LayoutMode` has five
  ## members. Stated once, here, rather than as `mode == EditMode` at each call
  ## site — which is what every existing site says, and which quietly files
  ## `QuickEditMode` and `InteractiveEditMode` under the DEBUG layout.
  mode in {EditMode, QuickEditMode, InteractiveEditMode}

const ModeLayoutStorageKeyPrefix* = "CODETRACER_MODE_LAYOUT_"
  ## The web store's key prefix. Suffixed `EDIT` or `DEBUG`, matching the
  ## desktop's two files rather than `LayoutMode`'s five members, so the two
  ## platforms persist the same partition and a layout does not change store
  ## when a session is in `QuickEditMode`.

func modeLayoutStorageKey*(mode: LayoutMode): string =
  ModeLayoutStorageKeyPrefix & (if isEditingMode(mode): "EDIT" else: "DEBUG")

when defined(js):
  proc jsReadLocal(key: cstring): cstring {.importjs: """
    (function(k) {
      try {
        if (typeof localStorage === 'undefined' || localStorage === null) return '';
        var v = localStorage.getItem(k);
        return (v === null || v === undefined) ? '' : v;
      } catch (e) { return ''; }
    })(#)""".}
    ## Guarded exactly as `ui/shortcut_preference.nim`'s pair is, and for the
    ## same two environments: one where there is no storage object at all, and
    ## one where there is and touching it throws (Safari private mode, site
    ## data blocked). A layout is not worth a `TypeError` that stops the
    ## renderer booting.

  proc jsWriteLocal(key, value: cstring) {.importjs: """
    (function(k, v) {
      try {
        if (typeof localStorage === 'undefined' || localStorage === null) return;
        localStorage.setItem(k, v);
      } catch (e) { }
    })(#, #)""".}

  proc jsRemoveLocal(key: cstring) {.importjs: """
    (function(k) {
      try {
        if (typeof localStorage === 'undefined' || localStorage === null) return;
        localStorage.removeItem(k);
      } catch (e) { }
    })(#)""".}

type
  ModeLayoutSource* = enum
    ## Where the layout a switch is about to apply came from. Reported, not
    ## inferred: §4.1 distinguishes "as the user last left it in this session"
    ## from "from the mode's store" from "the bundled default", and only the
    ## third is a degradation the user needs told about.
    mlsSession        ## the register — the user's, from earlier in this session
    mlsStored         ## this mode's store — the user's, from a previous session
    mlsBundled        ## the mode's default — nothing of the user's was found
    mlsBundledAfterFailure  ## the mode's default, because the stored one was unusable

  ModeLayoutResolution* = object
    ## A layout, and the honest account of where it came from.
    config*: js
    source*: ModeLayoutSource
    detail*: string  ## why, when `source` is `mlsBundledAfterFailure`

proc storedLayoutForMode*(mode: LayoutMode): Option[js] =
  ## This browser's saved arrangement for `mode`, or `none`.
  ##
  ## `none` covers "nothing stored" and "what was stored is not JSON" alike at
  ## this level; `resolveLayoutForMode` is what tells them apart, because only
  ## the second is something to tell the user about.
  when defined(js):
    let raw = jsReadLocal(cstring(modeLayoutStorageKey(mode)))
    if raw.len == 0:
      return none(js)
    let parsed = parseLayoutJsonOrNil(raw)
    if parsed.isNil:
      return none(js)
    some(parsed)
  else:
    none(js)

proc storeLayoutForMode*(mode: LayoutMode; config: js) =
  ## Write `mode`'s arrangement to this browser's store.
  ##
  ## Silent on failure by design — a full or blocked `localStorage` must not
  ## take down a mode switch. What must NOT be silent is the read side, and it
  ## is not.
  when defined(js):
    if config.isNil:
      return
    try:
      jsWriteLocal(cstring(modeLayoutStorageKey(mode)),
                   cast[cstring](JSON.stringify(config)))
    except CatchableError:
      cwarn "mode-layout: could not store the " & $mode & " layout: " &
        getCurrentExceptionMsg()
  else:
    discard

proc forgetStoredLayoutForMode*(mode: LayoutMode) =
  ## Drop a stored arrangement that could not be used.
  ##
  ## Without this a corrupt entry is re-read, re-rejected and re-reported on
  ## every switch and every reload for the life of the browser profile — the
  ## user is told the same thing forever and the only remedy is a devtools
  ## console. The desktop's `resetLayoutToDefault` writes the bad file aside as
  ## `.broken` for the same reason; there is nowhere to write one here, and a
  ## layout is regenerable, so it is dropped.
  when defined(js):
    jsRemoveLocal(cstring(modeLayoutStorageKey(mode)))
  else:
    discard

# ---------------------------------------------------------------------------
# The register
# ---------------------------------------------------------------------------

proc rememberModeLayout*(data: Data; mode: LayoutMode) =
  ## Snapshot the LIVE layout as `mode`'s, in the register and in the store.
  ##
  ## `mode` is a parameter and not `data.ui.mode`, and that is §4.4 rather than
  ## a style preference. A transition assigns the mode flag and rearranges the
  ## layout, and whichever it does second, there is an instant at which
  ## `data.ui.mode` is not the mode the layout on screen belongs to. Reading
  ## the flag here is what §4.4 describes as filing "the wrong arrangement into
  ## the wrong file"; naming the mode makes the ordering irrelevant.
  if data.isNil or data.ui.isNil or data.ui.layout.isNil:
    return
  # NOT WHILE A LAYOUT IS BEING LOADED, and this is the guard the whole design
  # turns on rather than a defensive extra.
  #
  # MEASURED IN A BROWSER, on three round trips against the assembled bundle.
  # Trips 2 and 3 reached Debug mode — `data-topbar-surface` said
  # `debugger-controls` and `data.ui.mode` said `0` — while the workspace was
  # still the EDIT arrangement, tab for tab: `FILES, VCS, TEST RESULTS,
  # src/main.nr, CONSTRAINTS`, three top-level columns, and no EVENT LOG. The
  # stored debug layout had gone from 4901 bytes to 3071, byte-for-byte the
  # size of the stored EDIT layout.
  #
  # The path: `applyModeLayout` sets `data.ui.mode` to the entering mode and
  # then swaps the layout. `loadLayout` tears the old tree down as it builds
  # the new one and GoldenLayout emits `stateChanged` DURING that, so
  # `ui/layout.nim`'s handler fired with the new mode already assigned and the
  # old (or half-built) layout still live — and filed it under the entering
  # mode. The next switch then restored that, which is how the edit
  # arrangement came back with the debugger's toolbar over it.
  #
  # This is the SAME defect the previous implementation had and the reason its
  # restore arm was disabled: an unrelated writer recording a layout mid-swap,
  # so "each transition saves a layout that the previous transition had already
  # damaged, and applying it feeds the damage forward". Moving the mode's
  # arrangement into a per-mode register removed one such writer; this removes
  # the other. `data.ui.isLoadingLayout` is set for exactly the duration of
  # `loadLayout` (`ui/layout.swapLayout`) and is what `itemDestroyed` already
  # uses to tell a wholesale swap from a user closing a tab.
  if data.ui.isLoadingLayout:
    return
  # NEVER PERSIST A REVIEW'S LAYOUT, for the reason `renderer.saveConfig` gives
  # at its own guard: a review runs on a layout that deliberately omits panels,
  # and storing it as the user's would leave the next ordinary launch missing
  # them.
  if data.deepReviewActive:
    return
  try:
    let live = cast[js](data.ui.layout.saveLayout())
    if live.isNil:
      return
    let snapshot = parseLayoutJsonOrNil(cast[cstring](JSON.stringify(live)))
    if snapshot.isNil:
      cwarn "mode-layout: the live " & $mode & " layout did not round-trip; " &
        "it was not remembered"
      return
    # THE REGISTER KEEPS THE LIVE LAYOUT; THE STORE KEEPS THE SANITISED ONE,
    # and the asymmetry is the desktop's, not an invention here.
    #
    # In-session, the editor tabs are the user's working set and their absolute
    # paths are still valid, so the register keeps them — that is how
    # `Mode-Transitions.md` §5's "the set of open editor tabs, their order, and
    # which is active" survives a round trip.
    #
    # Across sessions they are per-trace paths into a recording that may not
    # exist next time, which is why `index/window.onSaveConfig` sanitises
    # before writing either layout file. The web store gets the same treatment
    # from the same proc, so a browser and a desktop persist the same shape.
    data.ui.modeLayouts[mode] = cast[GoldenLayoutResolvedConfig](snapshot)
    storeLayoutForMode(mode, sanitizeLayoutConfig(
      snapshot, ord(Content.EditorView), modeHiddenContentIds(mode)))
  except CatchableError:
    cwarn "mode-layout: could not remember the " & $mode & " layout: " &
      getCurrentExceptionMsg()

proc resolveLayoutForMode*(data: Data; mode: LayoutMode): ModeLayoutResolution =
  ## The layout a switch into `mode` should apply, and where it came from.
  ##
  ## §4.1's order, and it is an order rather than a set: this session's
  ## arrangement, then this mode's store, then the mode's default. "It never
  ## rebuilds from the bundled default when a user arrangement exists."
  ##
  ## **Total.** Every arm ends in a config. The one that cannot — a bundled
  ## layout that does not parse — is a build defect, and it is reported as one
  ## with a nil config the caller must handle rather than being papered over
  ## with an empty tree, because an empty tree IS the failure this proc exists
  ## to prevent.
  let session = if data.isNil or data.ui.isNil: nil
                else: cast[js](data.ui.modeLayouts[mode])
  if not session.isNil:
    return ModeLayoutResolution(config: session, source: mlsSession)

  let stored = storedLayoutForMode(mode)
  if stored.isSome:
    return ModeLayoutResolution(config: stored.get, source: mlsStored)

  # DID THE STORE HOLD SOMETHING UNUSABLE, or was it simply empty? The two are
  # different events for the user — one is "you have not arranged this mode
  # yet", the other is "your arrangement could not be read" — and only the
  # second is worth interrupting anyone about.
  var detail = ""
  when defined(js):
    if jsReadLocal(cstring(modeLayoutStorageKey(mode))).len > 0:
      detail = "the stored " & $mode & " layout was not readable JSON"
      forgetStoredLayoutForMode(mode)

  let bundled = bundledLayoutForMode(mode)
  if detail.len > 0:
    return ModeLayoutResolution(config: bundled,
                                source: mlsBundledAfterFailure, detail: detail)
  ModeLayoutResolution(config: bundled, source: mlsBundled)

func describeDegradation*(resolution: ModeLayoutResolution;
                          mode: LayoutMode): Option[string] =
  ## The sentence to show the user, when there is one.
  ##
  ## Only `mlsBundledAfterFailure` produces one. A first visit to a mode is not
  ## a degradation and must not be announced — a notification on every first
  ## switch teaches the user to dismiss the one that matters.
  ##
  ## The sentence LEADS WITH WHAT THEY HAVE, the way
  ## `ui/web_project_persistence.nim`'s durability rows do: the workspace in
  ## front of them is a working default, not a failure, and the thing they need
  ## to know is that their own arrangement for this mode is gone and will be
  ## replaced by whatever they do next.
  if resolution.source != mlsBundledAfterFailure:
    return none(string)
  some("The " & (if isEditingMode(mode): "edit" else: "debug") &
       " layout was reset to the default: " & resolution.detail &
       ". Rearranging the panes will save a new one.")
