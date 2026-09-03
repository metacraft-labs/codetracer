## Repair and sanitisation of persisted GoldenLayout configuration trees.
##
## This module is deliberately **dependency-free**: it imports nothing but
## ``std/jsffi``.  Everything it needs about CodeTracer (the ``Content``
## ordinals, the registered GoldenLayout component types) is passed in by the
## caller.  That is what makes the layout-persistence invariants testable
## headlessly with ``nim js`` + node, without electron, ``fs``, or the
## frontend's ``types.nim`` object graph — see
## ``src/tests/gui/tests/layout/layout_config_roundtrip_test.nim``.
## ``src/frontend/index/config.nim`` is the only production caller.
##
## Two operations live here:
##
## * `sanitizeLayoutConfig` — runs on **save**.  Strips the per-trace editor
##   tabs (and, in edit mode, the replay-only panels) out of the config that
##   is about to be written to ``~/.config/codetracer/default_layout.json``.
## * `repairLayoutConfig` — runs on **load**.  Brings a config back into the
##   subset GoldenLayout will actually accept, so a file that is JSON-valid
##   but *semantically* rejected by GoldenLayout degrades into a usable
##   layout instead of aborting startup with a native ``Error``.
##
## Both preserve the stack invariant GoldenLayout enforces in ``Stack.init``
## (``node_modules/golden-layout/src/ts/items/stack.ts:169-171``):
##
## .. code-block:: js
##
##     if (this._initialActiveItemIndex < 0 ||
##         this._initialActiveItemIndex >= contentItemCount) {
##         throw new Error(`ActiveItemIndex out of range: ...`);
##     }
##
## ``activeItemIndex`` is a first-class stack-config field which round-trips
## verbatim through ``StackItemConfig.fromResolved``
## (``golden-layout/src/ts/config/config.ts:358``) and back through
## ``StackItemConfig.resolve`` (:342).  Removing a tab from a stack without
## remapping it therefore writes a *permanently* unloadable layout file —
## which is issue #608: the saved layout breaks on the next open and only
## ``just reset-layout`` recovers it.
##
## Size strings are validated against the same rules ``parseSize``
## (``golden-layout/src/ts/config/config.ts:1249``) applies:
## ``ItemConfig.resolveSize`` accepts only ``%`` and ``fr`` units (:168) and
## ``ItemConfig.resolveMinSize`` accepts only ``px`` (:193).  Anything else
## throws a ``ConfigurationError`` during ``loadLayout``.

import std/jsffi

const
  ## The component types ``ui/layout.nim`` registers with GoldenLayout
  ## (``registerComponent`` at layout.nim:552 and :697).  A saved config
  ## naming anything else makes ``VirtualLayout.bindComponent``
  ## (``golden-layout/src/ts/virtual-layout.ts:214-217``) fall through to
  ## CodeTracer's handler, which returns ``undefined``; destructuring
  ## ``{component, virtual}`` off that throws a ``TypeError``.
  EditorComponentType* = cstring"editorComponent"
  GenericUiComponentType* = cstring"genericUiComponent"

proc knownComponentTypes*(): seq[cstring] =
  ## The allow-list `repairLayoutConfig` validates ``componentType`` against.
  @[EditorComponentType, GenericUiComponentType]

proc reviewModeHiddenContentIds*(editModeHidden: seq[int];
                                 reviewPillars: seq[int]): seq[int] =
  ## Which panels a **review** layout hides: edit mode's set, minus the
  ## panels a review is *built out of*.
  ##
  ## RV-2 (``codetracer-specs/DeepReview/Review-Command.milestones.org``):
  ## a review over an exported dataset opens the EDITOR layout, not the
  ## debugging one — "The editor layout omits the panels a dataset cannot
  ## populate (EVENT LOG, CALLTRACE, TIMELINE, TERMINAL OUTPUT), so a review
  ## does not present empty panels that imply missing data"
  ## (DeepReview-GUI.md §1.1).
  ##
  ## Reusing edit mode's hidden set verbatim would go one panel too far.
  ## ``index/config.editModeHiddenContentIds`` hides ``Content.AgentActivity``
  ## and ``Content.AgentActivityDeepReview``, because an *editing* session has
  ## no agent review data — but the Agent Activity panel is DeepReview's third
  ## pillar (DeepReview-GUI.md, "DeepReview introduces no panel of its own ...
  ## 3. The Agent Activity panel"), and hiding it would delete a required
  ## surface *and* silently turn ``deepreview_layout.focusReviewActivityPane``
  ## into a no-op.  So the review's own pillars are subtracted back out.
  ##
  ## A set difference rather than a second hand-maintained list: the two modes
  ## must not drift apart panel by panel, and a panel added to edit mode's
  ## hidden set is a panel a dataset cannot populate either.  The caller
  ## supplies both sides by ``Content`` name
  ## (``index/config.reviewModeHiddenContentIds``), so the ordinals live in
  ## exactly one place; this module stays dependency-free so the rule is
  ## exercisable headlessly (``src/tests/gui/tests/layout/
  ## review_layout_test.nim``).
  for contentId in editModeHidden:
    if contentId notin reviewPillars:
      result.add(contentId)

# ---------------------------------------------------------------------------
# Save-side sanitisation
# ---------------------------------------------------------------------------

proc sanitizeLayoutConfig*(config: js; editorContent: int;
                           hiddenContents: seq[int]): js {.importjs:
  """(function(config, editorContent, hiddenContents) {
    if (!config) return config;
    const hidden = new Set(Array.isArray(hiddenContents)
      ? hiddenContents.map(Number)
      : []);
    const editor = Number(editorContent);
    const clone = JSON.parse(JSON.stringify(config));

    // Remap a stack's activeItemIndex after some of its children were
    // dropped.  `survivors` holds the ORIGINAL indices of the children that
    // are still present, in order, so `survivors[k]` is the old index of the
    // new child `k`.
    //
    // If the previously active tab survived, follow it.  Otherwise fall on
    // the nearest surviving tab to its right (the count of survivors that
    // used to sit to its left), which is what a tab strip does when you
    // close the active tab.  Finally clamp into [0, count-1] so the result
    // can never trip GoldenLayout's Stack.init() range check.
    const remapActiveItemIndex = (previous, survivors, count) => {
      if (count <= 0) return 0;
      const old = Number(previous);
      const base = Number.isFinite(old) ? old : 0;
      const survivingPosition = survivors.indexOf(base);
      let mapped = survivingPosition >= 0
        ? survivingPosition
        : survivors.filter((index) => index < base).length;
      if (!Number.isFinite(mapped) || mapped < 0) mapped = 0;
      if (mapped > count - 1) mapped = count - 1;
      return mapped;
    };

    const isDropped = (node) => {
      if (node.type !== 'component') return false;
      const state = node.componentState || {};
      const content = Number(state.content);
      return content === editor || hidden.has(content);
    };

    const walk = (node) => {
      if (!node) return null;
      if (isDropped(node)) return null;
      if (Array.isArray(node.content)) {
        const survivors = [];
        const kept = [];
        for (let i = 0; i < node.content.length; i++) {
          const child = walk(node.content[i]);
          if (child) { kept.push(child); survivors.push(i); }
        }
        node.content = kept;
        if (kept.length === 0) return null;
        // Only rewrite the field when it was actually persisted; when it is
        // absent GoldenLayout defaults to 0, which is always in range for a
        // non-empty stack, and we would rather not grow the saved file.
        if (node.type === 'stack' && node.activeItemIndex !== undefined &&
            node.activeItemIndex !== null) {
          node.activeItemIndex =
            remapActiveItemIndex(node.activeItemIndex, survivors, kept.length);
        }
      }
      return node;
    };

    const sanitizedRoot = walk(clone.root || clone);
    if (!sanitizedRoot) return config;
    if (clone.root) clone.root = sanitizedRoot;
    return clone.root ? clone : sanitizedRoot;
  })(#, #, #)""".}
  ## Strip the editor tabs (``componentState.content == editorContent``) and
  ## every content id in ``hiddenContents`` out of a layout config, keeping
  ## every enclosing stack's ``activeItemIndex`` in range.
  ##
  ## Returns the original `config` untouched when the sanitised tree would be
  ## empty, so a degenerate layout is never persisted as "no root at all".

proc unclaimedTopLevelPercent*(config: js): int {.importjs:
  """(function(config) {
    const root = config && (config.root || config);
    if (!root || root.type !== 'row') return -1;
    const kids = Array.isArray(root.content) ? root.content : null;
    if (!kids || kids.length === 0) return -1;
    let total = 0;
    for (const kid of kids) {
      const raw = kid ? kid.size : undefined;
      if (raw === undefined || raw === null) return -1;
      let value;
      if (typeof raw === 'number') {
        // A RESOLVED config: GoldenLayout splits the unit out into
        // `sizeUnit`, and anything but a percentage cannot be summed against
        // the others.
        if (kid.sizeUnit !== '%' && kid.sizeUnit !== 'percent') return -1;
        value = raw;
      } else {
        const text = String(raw).trim();
        if (!text.endsWith('%')) return -1;
        value = Number(text.slice(0, -1));
      }
      if (!Number.isFinite(value)) return -1;
      total += value;
    }
    const free = 100 - total;
    return free > 0 && free < 100 ? Math.round(free) : 0;
  })(#)""".}
  ## The percentage of the top-level row that the layout does NOT account for.
  ##
  ## ## What it is for, and why the number is not recoverable later
  ##
  ## `src/config/default_layout.json` declares three top-level columns —
  ## `20%` Filesystem, `55%` replay panes, `25%` the NS9 panes — and edit mode
  ## hides every component of the middle one, so `sanitizeLayoutConfig` drops
  ## it. The survivors still SAY `20%` and `25%`, but GoldenLayout renormalises
  ## a row to fill 100% the instant it loads one: measured, `20/25` became
  ## `44.44/55.56` before any pane had been created. The editor's container is
  ## created after that, so by the time it asks how much room the layout meant
  ## to leave it, the answer has been overwritten.
  ##
  ## So it is read HERE, from the config as sent, where `20%` and `25%` are
  ## still strings and the missing `55` is still visible as the shortfall.
  ##
  ## ## Why "unclaimed" rather than "what was dropped"
  ##
  ## A sanitiser that reported what it removed would answer only for the path
  ## that removes something. This asks a question about the config in front of
  ## it — how much of the row is unspoken for — which has the same answer for
  ## a sanitised layout, for a hand-edited one, and for a future layout that
  ## simply leaves a gap. `0` means the row is fully accounted for and the
  ## caller must not interfere; `-1` means the question has no well-defined
  ## answer (no explicit sizes, a non-row root) and likewise.
  ##
  ## Returns `0` rather than a negative for an OVER-subscribed row: a layout
  ## summing past 100 is GoldenLayout's business to normalise, not this
  ## function's to complain about.

# ---------------------------------------------------------------------------
# Per-mode placement
# ---------------------------------------------------------------------------
#
# ## Why suppression alone could not express what a mode's layout is
#
# Until now a mode's default layout was `sanitizeLayoutConfig(bundled, ...,
# hiddenFor(mode))` — ONE bundled tree, read two ways, and the only difference
# a mode could express was which panes were *removed*. That is a strict subset
# of "each mode has its own layout", and the gap is visible in the product:
# `src/config/default_layout.json` gives TEST RESULTS and CONSTRAINTS a
# top-level column of their own, so debug mode — which hides neither — kept a
# standing column of them beside a replay, and no hidden set could have said
# otherwise. A suppression list can delete a pane; it cannot say where a pane
# belongs *in this mode*.
#
# `nestPanesIntoHosts` is the missing half. A mode declares, as data, which
# panes are tabs of which other pane's stack; everything else about the bundled
# tree is left exactly as it is. Together with the hidden set that makes a
# mode's default layout a function of the mode rather than a reading of one
# tree, which is what `GUI/Layout-And-Navigation/Mode-Transitions.md` §4
# requires of the layouts a switch moves between.
#
# ## Why the rule is data and the engine is one function
#
# The placements the request asked for — TEST RESULTS with FILES in both modes,
# CONSTRAINTS with the EVENT LOG in debug mode — are three rows of a table, and
# they are stated once, beside the `Content` enum they are about
# (`common_types/codetracer_features/frontend.paneHomesForMode`). Writing them
# as three branches HERE would have made each an exception in the layout code
# and left the next pane with no place to be declared; the whole point of the
# general rule is that the placements are its output rather than its cases.

proc nestPanesIntoHosts*(config: js; placements: seq[seq[int]]): js {.importjs:
  """(function(config, placements) {
    if (!config) return config;
    const pairs = (Array.isArray(placements) ? placements : [])
      .filter((p) => Array.isArray(p) && p.length >= 2)
      .map((p) => ({ pane: Number(p[0]), host: Number(p[1]) }))
      .filter((p) => Number.isFinite(p.pane) && Number.isFinite(p.host));
    if (pairs.length === 0) return config;

    let clone;
    try {
      clone = JSON.parse(JSON.stringify(config));
    } catch (error) {
      // A config that will not round-trip through JSON is one this function
      // cannot reason about. Handing back the ORIGINAL is the honest answer:
      // the caller still has a layout, and `repairLayoutConfig` is the module
      // that is allowed to have an opinion about a malformed one.
      return config;
    }
    const hasRootWrapper = clone.root !== undefined && clone.root !== null;
    const root = hasRootWrapper ? clone.root : clone;
    if (!root || typeof root !== 'object') return config;

    const contentOf = (node) => {
      if (!node || node.type !== 'component') return NaN;
      const state = node.componentState || {};
      return Number(state.content);
    };

    // The first component with this content id, together with the parent that
    // holds it and its index there. Re-walked per placement rather than
    // indexed once, because each move rewrites the tree the next one reads.
    const locate = (target) => {
      let found = null;
      const visit = (node, parent, index) => {
        if (found || !node || typeof node !== 'object') return;
        if (contentOf(node) === target) {
          found = { node: node, parent: parent, index: index };
          return;
        }
        const kids = Array.isArray(node.content) ? node.content : null;
        if (!kids) return;
        for (let i = 0; i < kids.length; i++) visit(kids[i], node, i);
      };
      visit(root, null, -1);
      return found;
    };

    // A tab removed from the left of the active one shifts it left by one.
    // Same rule `sanitizeLayoutConfig` applies, for the same reason: an
    // `activeItemIndex` past the end makes `Stack.init` throw and the whole
    // restore aborts (the issue this module's header names).
    const remapAfterRemoval = (stack, removedIndex) => {
      if (!stack || stack.type !== 'stack') return;
      if (stack.activeItemIndex === undefined || stack.activeItemIndex === null) return;
      const count = Array.isArray(stack.content) ? stack.content.length : 0;
      if (count <= 0) { stack.activeItemIndex = 0; return; }
      let active = Number(stack.activeItemIndex);
      if (!Number.isFinite(active)) active = 0;
      if (active > removedIndex) active -= 1;
      if (active < 0) active = 0;
      if (active > count - 1) active = count - 1;
      stack.activeItemIndex = active;
    };

    const remapActiveItemIndex = (previous, survivors, count) => {
      if (count <= 0) return 0;
      const old = Number(previous);
      const base = Number.isFinite(old) ? old : 0;
      const survivingPosition = survivors.indexOf(base);
      let mapped = survivingPosition >= 0
        ? survivingPosition
        : survivors.filter((index) => index < base).length;
      if (!Number.isFinite(mapped) || mapped < 0) mapped = 0;
      if (mapped > count - 1) mapped = count - 1;
      return mapped;
    };

    // Containers emptied by the moves above are dropped, bottom up — the same
    // treatment `sanitizeLayoutConfig` gives a container emptied by hiding.
    // Without it, nesting the last component of a stack leaves an empty stack,
    // which GoldenLayout rejects outright.
    const prune = (node) => {
      if (!node || typeof node !== 'object') return null;
      if (node.type === 'component') return node;
      const kids = Array.isArray(node.content) ? node.content : null;
      if (!kids) return node;
      const survivors = [];
      const kept = [];
      for (let i = 0; i < kids.length; i++) {
        const child = prune(kids[i]);
        if (child) { kept.push(child); survivors.push(i); }
      }
      node.content = kept;
      if (kept.length === 0) return null;
      if (node.type === 'stack' && node.activeItemIndex !== undefined &&
          node.activeItemIndex !== null) {
        node.activeItemIndex =
          remapActiveItemIndex(node.activeItemIndex, survivors, kept.length);
      }
      return node;
    };

    for (let k = 0; k < pairs.length; k++) {
      const pane = pairs[k].pane;
      const host = pairs[k].host;
      const paneAt = locate(pane);
      // A PANE THIS MODE DOES NOT HAVE IS NOT AN ERROR. The hidden set has
      // already run by the time this does, so a placement naming a pane the
      // mode suppresses simply has nothing to move — and a mode is allowed to
      // declare a home for a pane it does not show, because the two tables are
      // independent statements and neither should have to know the other's
      // contents.
      if (!paneAt || !paneAt.parent) continue;
      const hostAt = locate(host);
      if (!hostAt || !hostAt.parent) continue;
      if (hostAt.parent.type !== 'stack') continue;
      // IDEMPOTENCE, and it is a requirement rather than an optimisation.
      // `Mode-Transitions.md` §6 requires the nth switch to behave as the
      // first; this function runs on every switch that falls back to a mode's
      // default, so a second run over its own output has to be a no-op.
      if (paneAt.parent === hostAt.parent) continue;
      // Detach, then append. APPENDING is what keeps the host the visible tab:
      // every existing index in the host stack is unchanged, so its
      // `activeItemIndex` still names the tab it named before — FILES stays
      // the front tab of the FILES stack and TEST RESULTS joins behind it.
      paneAt.parent.content.splice(paneAt.index, 1);
      remapAfterRemoval(paneAt.parent, paneAt.index);
      // A size on a stack child is meaningless (stack children fill the
      // stack), and carrying a column's `25%` onto a tab is how a stale number
      // survives to confuse the next reader of the file.
      delete paneAt.node.size;
      delete paneAt.node.sizeUnit;
      hostAt.parent.content.push(paneAt.node);
    }

    const pruned = prune(root);
    if (!pruned) return config;
    if (hasRootWrapper) { clone.root = pruned; return clone; }
    return pruned;
  })(#, #)""".}
  ## Re-home panes as tabs of another pane's stack, as `placements` declares.
  ##
  ## Each entry of `placements` is a two-element `@[pane, host]` of `Content`
  ## ordinals: the component whose content is `pane` becomes the last tab of
  ## the stack that holds the component whose content is `host`. Containers
  ## left empty by the move are dropped and every affected stack's
  ## `activeItemIndex` is kept in range.
  ##
  ## **Total.** A placement whose pane or host is absent, whose host is not in
  ## a stack, or which is already satisfied, is skipped; a config that does not
  ## round-trip through JSON is returned untouched. There is no input for which
  ## this returns nothing — the caller always still has a layout.

proc modeDefaultLayoutConfig*(config: js; editorContent: int;
                              hiddenContents: seq[int];
                              placements: seq[seq[int]]): js =
  ## A MODE'S DEFAULT LAYOUT, from the bundled tree: what the mode does not
  ## show, removed; what the mode homes elsewhere, moved.
  ##
  ## This is the whole of "each mode has its own layout" on the default side —
  ## the user side is a saved layout per mode, which is the caller's business
  ## (`Mode-Transitions.md` §4.1: a switch prefers the user's arrangement and
  ## falls back to this).
  ##
  ## The two tables are PARAMETERS rather than reads of `Content`, which is the
  ## same convention every other proc in this module follows and the reason the
  ## module has no imports: the rules stay exercisable headlessly under
  ## `nim js` + node, and the ordinals keep living in exactly one place
  ## (`common_types/codetracer_features/frontend.modeHiddenContentIds` and
  ## `.paneHomesForMode`, which both platforms call).
  ##
  ## ORDER IS LOAD-BEARING, and it is the reason this composition is a named
  ## proc rather than two calls at each site. Suppression runs first, so a
  ## placement can name a host the mode hides and be skipped rather than
  ## resurrect it: edit mode declares no CONSTRAINTS-under-EVENT-LOG row for
  ## exactly this reason, but a mode that did would get the skip and not a
  ## revived event log. Nesting first would move a pane into a stack that the
  ## sanitiser then deletes, taking the nested pane with it — the pane would
  ## vanish from a mode that never hid it.
  nestPanesIntoHosts(
    sanitizeLayoutConfig(config, editorContent, hiddenContents), placements)

# ---------------------------------------------------------------------------
# Load-side repair
# ---------------------------------------------------------------------------

proc repairLayoutConfigJs(config: js; allowedComponentTypes: seq[cstring]): js
  {.importjs: """(function(config, allowedComponentTypes) {
    const issues = [];
    const allowed = new Set(Array.isArray(allowedComponentTypes)
      ? allowedComponentTypes.map(String)
      : []);
    const reject = (reason) => ({
      ok: false, changed: false, config: config, issues: [reason]
    });

    if (!config || typeof config !== 'object') {
      return reject('layout config is not an object');
    }

    let clone;
    try {
      clone = JSON.parse(JSON.stringify(config));
    } catch (error) {
      return reject('layout config is not serialisable: ' +
        (error && error.message ? error.message : String(error)));
    }

    const hasRootWrapper = clone.root !== undefined && clone.root !== null;
    const rootItem = hasRootWrapper ? clone.root : clone;
    if (!rootItem || typeof rootItem !== 'object' ||
        typeof rootItem.type !== 'string') {
      return reject('layout config has no usable root item');
    }

    let changed = false;
    const note = (message) => { issues.push(message); changed = true; };

    // Size acceptance mirrors GoldenLayout's own `parseSize`
    // (golden-layout/src/ts/config/config.ts:1249) exactly, rather than
    // approximating it with a regex.  Getting this WRONG in the strict
    // direction would be worse than the bug being fixed: a legitimate size
    // wrongly rejected here is a panel proportion silently reset on load.
    // Saved sizes really are fractional — `RowOrColumn` recomputes them as
    // `(contentItem.size / total) * 100` (row-or-column.ts:441) — so
    // "33.3333%" must be accepted, while GoldenLayout's own splitter never
    // produces a sign, and a leading '-' makes its `parseInt` see an empty
    // numeric part and throw.
    //
    // `ItemConfig.resolveSize` allows only '%' and 'fr' (config.ts:168);
    // `resolveMinSize` allows only 'px' (:193).  Anything else makes
    // `parseSize` throw a ConfigurationError out of `loadLayout`, which
    // aborts the entire restore.
    const splitSize = (value) => {
      const text = String(value).trimStart();
      let firstNonNumeric = text.length;
      let seenDecimalPoint = false;
      for (let i = 0; i < text.length; i++) {
        const char = text[i];
        if (char >= '0' && char <= '9') continue;
        if (char === '.' && !seenDecimalPoint) { seenDecimalPoint = true; continue; }
        firstNonNumeric = i;
        break;
      }
      return {
        numeric: text.substring(0, firstNonNumeric),
        unit: text.substring(firstNonNumeric)
      };
    };
    const sizeAcceptable = (value, allowedUnits) => {
      if (typeof value !== 'string') return false;
      const parts = splitSize(value);
      if (!Number.isFinite(Number.parseInt(parts.numeric, 10))) return false;
      return allowedUnits.indexOf(parts.unit) >= 0;
    };
    const repairSizes = (node, path) => {
      if (node.size !== undefined && node.size !== null &&
          !sizeAcceptable(node.size, ['%', 'fr'])) {
        note(path + ': unsupported size ' + JSON.stringify(node.size) +
          ' removed (only % and fr are accepted)');
        delete node.size;
      }
      if (node.minSize !== undefined && node.minSize !== null &&
          !sizeAcceptable(node.minSize, ['px'])) {
        note(path + ': unsupported minSize ' + JSON.stringify(node.minSize) +
          ' removed (only px is accepted)');
        delete node.minSize;
      }
    };

    const remapActiveItemIndex = (previous, survivors, count) => {
      if (count <= 0) return 0;
      const old = Number(previous);
      const base = Number.isFinite(old) ? old : 0;
      const survivingPosition = survivors.indexOf(base);
      let mapped = survivingPosition >= 0
        ? survivingPosition
        : survivors.filter((index) => index < base).length;
      if (!Number.isFinite(mapped) || mapped < 0) mapped = 0;
      if (mapped > count - 1) mapped = count - 1;
      return mapped;
    };

    const walk = (node, path) => {
      if (!node || typeof node !== 'object' || Array.isArray(node)) {
        note(path + ': item is not an object, dropped');
        return null;
      }
      if (typeof node.type !== 'string') {
        note(path + ': item without a type, dropped');
        return null;
      }
      repairSizes(node, path);

      if (node.type === 'component') {
        if (typeof node.componentType !== 'string' ||
            !allowed.has(node.componentType)) {
          note(path + ': unknown componentType ' +
            JSON.stringify(node.componentType) + ', dropped');
          return null;
        }
        const state = node.componentState;
        if (!state || typeof state !== 'object' ||
            !Number.isFinite(Number(state.content))) {
          note(path + ': component without componentState.content, dropped');
          return null;
        }
        return node;
      }

      if (node.content !== undefined && !Array.isArray(node.content)) {
        note(path + ': content is not an array, reset to empty');
        node.content = [];
      }
      const children = Array.isArray(node.content) ? node.content : [];
      const survivors = [];
      const kept = [];
      for (let i = 0; i < children.length; i++) {
        let child = walk(children[i], path + '/' + i);
        // GoldenLayout requires every child of a stack to be a ComponentItem
        // (stack.ts:174-176 throws otherwise), so a nested row/column/stack
        // inside a stack is fatal at restore time.
        if (child && node.type === 'stack' && child.type !== 'component') {
          note(path + '/' + i + ': non-component child of a stack, dropped');
          child = null;
        }
        if (child) { kept.push(child); survivors.push(i); }
      }
      if (kept.length !== children.length) changed = true;
      node.content = kept;

      if (kept.length === 0) {
        note(path + ': empty ' + node.type + ', dropped');
        return null;
      }

      if (node.type === 'stack') {
        const mapped =
          remapActiveItemIndex(node.activeItemIndex, survivors, kept.length);
        const previous = node.activeItemIndex;
        if (previous === undefined || previous === null) {
          // Absent means 0, which is always in range here — leave it absent.
        } else if (Number(previous) !== mapped) {
          note(path + ': activeItemIndex ' + JSON.stringify(previous) +
            ' out of range for ' + kept.length + ' tab(s), clamped to ' +
            mapped);
          node.activeItemIndex = mapped;
        } else {
          node.activeItemIndex = mapped;
        }
      }
      return node;
    };

    const repairedRoot = walk(rootItem, 'root');
    if (!repairedRoot) {
      return {
        ok: false,
        changed: true,
        config: config,
        issues: issues.concat(['layout config is empty after repair'])
      };
    }
    if (hasRootWrapper) clone.root = repairedRoot;
    return {
      ok: true,
      changed: changed,
      config: hasRootWrapper ? clone : repairedRoot,
      issues: issues
    };
  })(#, #)""".}

type
  LayoutRepair* = object
    ## Outcome of `repairLayoutConfig`.
    ok*: bool           ## false when nothing usable could be salvaged
    changed*: bool      ## true when the repaired config differs from the input
    config*: js         ## the repaired config (the input when `ok` is false)
    issues*: seq[cstring] ## human-readable description of every repair applied

proc repairLayoutConfig*(config: js;
                         allowedComponentTypes: seq[cstring] =
                           @[EditorComponentType, GenericUiComponentType]):
                        LayoutRepair =
  ## Bring `config` into the subset GoldenLayout accepts.
  ##
  ## Every rule here corresponds to a shape that makes ``loadLayout`` throw a
  ## native JavaScript ``Error`` — which a Nim ``try/except`` cannot catch,
  ## so it aborts ``initLayout`` half-way and leaves an unusable window:
  ##
  ## * a stack's ``activeItemIndex`` outside ``[0, content.len-1]``
  ## * a ``componentType`` that was never registered
  ## * a component with no ``componentState.content``
  ## * a non-component child of a stack
  ## * a container whose ``content`` is empty
  ## * a ``size`` / ``minSize`` string with a unit GoldenLayout rejects
  ##
  ## When `ok` is false the caller should fall back to the bundled default
  ## layout.  When `changed` is true the caller should rewrite the file so
  ## the repair is not re-applied on every launch.
  let raw = repairLayoutConfigJs(config, allowedComponentTypes)
  result.ok = raw["ok"].to(bool)
  result.changed = raw["changed"].to(bool)
  result.config = raw["config"]
  # On Nim's JavaScript backend a `seq[T]` *is* a JS array, so the issue list
  # crosses the jsffi boundary without a copy.
  result.issues = cast[seq[cstring]](raw["issues"])

# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

proc layoutContainsContentId*(config: js; contentId: int): bool {.importjs:
  """(function(config, contentId) {
    const target = Number(contentId);
    const walk = (node) => {
      if (!node) return false;
      const state = node.componentState || {};
      if (node.type === 'component' && Number(state.content) === target) {
        return true;
      }
      if (Array.isArray(node.content)) {
        for (const child of node.content) {
          if (walk(child)) return true;
        }
      }
      return false;
    };
    return walk((config && config.root) || config);
  })(#, #)""".}
  ## Recursively check whether a GoldenLayout config tree contains a
  ## component panel with the given ``componentState.content`` ordinal.

proc autoHideStateContainsContentId*(state: js; contentId: int): bool
  {.importjs: """(function(state, contentId) {
    if (!state || typeof state !== 'object') return false;
    const panels = state.panels;
    if (!Array.isArray(panels)) return false;
    const target = Number(contentId);
    return panels.some((panel) => panel && Number(panel.content) === target);
  })(#, #)""".}
  ## Whether a serialised auto-hide state (see ``ui/auto_hide.nim``'s
  ## `serializeAutoHideState`) holds a panel with the given ``Content``
  ## ordinal.  A panel that the user pinned to an edge is *removed* from the
  ## GoldenLayout tree, so the layout validator has to consult this set as
  ## well — otherwise pinning the Filesystem panel makes the saved layout
  ## look "incompatible" and the loader deletes it.

proc layoutHasRequiredPanel*(config: js; autoHideState: js;
                             contentId: int): bool =
  ## Whether a panel CodeTracer requires (today: ``Content.Filesystem``) is
  ## reachable from a saved session — either still mounted in the
  ## GoldenLayout tree, or pinned to an edge and therefore living in the
  ## auto-hide state instead.
  ##
  ## Checking only the GoldenLayout tree is what made pinning the Filesystem
  ## panel destroy the user's layout: the loader decided the file was
  ## "incompatible" and `resetLayoutToDefault` deleted it, with nothing but a
  ## warning in the log.
  layoutContainsContentId(config, contentId) or
    autoHideStateContainsContentId(autoHideState, contentId)

proc stackActiveItemIndexInRange*(config: js): bool {.importjs:
  """(function(config) {
    const walk = (node) => {
      if (!node || typeof node !== 'object') return true;
      if (Array.isArray(node.content)) {
        if (node.type === 'stack') {
          const index = node.activeItemIndex === undefined ||
            node.activeItemIndex === null ? 0 : Number(node.activeItemIndex);
          if (!Number.isFinite(index) || index < 0 ||
              index >= node.content.length) {
            return false;
          }
        }
        for (const child of node.content) {
          if (!walk(child)) return false;
        }
      }
      return true;
    };
    return walk((config && config.root) || config);
  })(#)""".}
  ## Mirror of GoldenLayout's ``Stack.init`` range check, applied to a plain
  ## config tree.  Used by the tests as the "would GoldenLayout accept this"
  ## oracle, and available to callers that want to assert the invariant
  ## without attempting a real restore.
