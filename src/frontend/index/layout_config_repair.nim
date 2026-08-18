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
