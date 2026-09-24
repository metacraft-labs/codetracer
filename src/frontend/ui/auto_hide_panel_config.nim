## The GoldenLayout component config an auto-hide panel is re-attached from.
##
## `unpinPanel` (`ui/auto_hide.nim`) hands `panel.config` to GoldenLayout's
## `addItem`, which builds a component from it.  Two questions decide whether
## that call can succeed, and both are answered here:
##
## * **What does a config have to carry?** A component type GoldenLayout can
##   construct (`componentName` on an unresolved config, `componentType` on a
##   resolved one) and a `componentState.label`, which is the DOM id
##   `layout.nim`'s `genericUiComponent` registration mounts into
##   (`element.mountComponentContainer(editorLabel)`; the registration returns
##   immediately when `state.label.len == 0`).
## * **What is that config for a pane that was never in GoldenLayout?** The
##   four panes `layout.nim` pins to the bottom strip on every startup — BUILD,
##   PROBLEMS, FIND IN FILES, REQUESTS — are registered by
##   `addStandaloneAutoHidePanel` and never pass through `pinPanel`, so nothing
##   ever captured a config for them.  Issue #692 is the consequence: their
##   Unpin action ran the whole unpin path against an empty object and produced
##   no panel.  `standaloneComponentConfig` is the config they get instead.
##
## This module is deliberately **dependency-free**: it imports nothing but
## `std/jsffi`, for the same reason `index/layout_config_repair.nim` does — a
## rule with no dependencies is cheap to exercise and cheap to reason about.
##
## It is NOT here because the rule could not otherwise be reached.  An earlier
## version of this comment said `auto_hide.nim` "pulls in `kdom`, the frontend
## `types.nim` object graph and GoldenLayout, none of which compile under
## `nim js -d:nodejs`"; that was asserted rather than measured, and it is
## false.  `auto_hide.nim` compiles and runs under exactly the `vm-js` lane's
## command (`nim js -d:nodejs --path:src/frontend/viewmodel`), which is why
## `src/tests/gui/tests/auto-hide/auto_hide_unpin_test.nim` can call
## `unpinPanel` itself rather than only this helper.  That file is the headless
## cover for both.

import std/jsffi

const
  GenericComponentName* = cstring"genericUiComponent"
    ## The GoldenLayout component every non-editor CodeTracer pane is built
    ## from; registered in `ui/layout.nim`'s `initLayout`.

proc standaloneComponentConfig*(
    label: cstring; contentOrdinal: int; componentId: int): JsObject =
  ## The *unresolved* GoldenLayout component config for a standalone auto-hide
  ## pane, in the shape `addItem` consumes.
  ##
  ## Unresolved, not resolved, for the same reason `pinPanel` builds its config
  ## by hand rather than passing `contentItem.toConfig().toJs` through: a
  ## resolved config spells the component with `componentType` and numeric type
  ## enums, and `addItem` expects the string-based `type` / `componentName`
  ## pair.
  ##
  ## `label` is the component label — `buildComponent-0`, `errorsComponent-0`,
  ## `searchResultsComponent-0`, `requestPanelComponent-0` — which is both the
  ## DOM id the pane's IsoNim view mounts into and the key
  ## `bindLayoutItemForTab` registers the tab under.  It is passed in rather
  ## than derived from `contentOrdinal` because PROBLEMS breaks the derivation:
  ## its content is `Content.BuildErrors` but its label is `errorsComponent-0`,
  ## not `buildErrorsComponent-0`.
  ##
  ## The remaining `componentState` fields mirror `pinPanel`'s config exactly,
  ## so an unpinned standalone pane and a pinned-then-unpinned one reach
  ## `genericUiComponent` with the same state shape.
  js{
    "type": cstring"component",
    "componentName": GenericComponentName,
    "componentState": js{
      "id": componentId,
      "label": label,
      "content": contentOrdinal,
      "fullPath": cstring"",
      "name": label,
      "editorView": 0,
      "isEditor": false,
      "noInfoMessage": cstring""
    }
  }

proc jsConfigComponentName(config: JsObject): cstring {.importjs: """
(function (c) {
  if (!c || typeof c !== 'object') return '';
  var type = c.componentName;
  if (typeof type !== 'string' || type.length === 0) type = c.componentType;
  return (typeof type === 'string') ? type : '';
})(#)""".}

proc configComponentName*(config: JsObject): cstring =
  ## The GoldenLayout component `config` names, or `""` when it names none.
  ##
  ## Both spellings, for the reason `isReattachableConfig` gives: `addItem`
  ## consumes the unresolved `componentName`, and a config read back from
  ## `auto_hide_state.json` carries GoldenLayout's resolved `componentType`.
  ##
  ## Callers use this to tell the two component registrations apart —
  ## `genericUiComponent`, which `ui/layout.nim` can mount from a component
  ## state alone, and `editorComponent`, which cannot be rebuilt that way.
  jsConfigComponentName(config)

proc jsConfigComponentLabel(config: JsObject): cstring {.importjs: """
(function (c) {
  if (!c || typeof c !== 'object') return '';
  var state = c.componentState;
  if (!state || typeof state !== 'object') return '';
  var label = state.label;
  return (typeof label === 'string') ? label : '';
})(#)""".}

proc configComponentLabel*(config: JsObject): cstring =
  ## `config.componentState.label`, or `""` when the config carries none.
  ##
  ## This is the DOM id the pane mounts into — `stateComponent-0`,
  ## `errorsComponent-0`, an editor tab's absolute path — and it is the single
  ## field `isReattachableConfig` insists on beyond the component type.
  ##
  ## Raw JS for the same reason the predicate above is: `config.componentState`
  ## on an empty object is `undefined`, and the next `.` throws a native
  ## `TypeError`.
  jsConfigComponentLabel(config)

proc jsIsReattachableConfig(config: JsObject): bool {.importjs: """
(function (c) {
  if (!c || typeof c !== 'object') return false;
  var type = c.componentName;
  if (typeof type !== 'string' || type.length === 0) type = c.componentType;
  if (typeof type !== 'string' || type.length === 0) return false;
  var state = c.componentState;
  if (!state || typeof state !== 'object') return false;
  return typeof state.label === 'string' && state.label.length > 0;
})(#)""".}

proc isReattachableConfig*(config: JsObject): bool =
  ## Whether GoldenLayout can build a panel from `config`.
  ##
  ## `addItem` does not report failure the way a Nim caller would expect, so
  ## this is asked BEFORE the attempt rather than inferred from it.  An empty
  ## object — which is what `addStandaloneAutoHidePanel` used to store, and
  ## what issue #692 is — names no component type, so there is nothing for
  ## GoldenLayout to construct and nothing is added; a config carrying a type
  ## but no `componentState.label` is worse, because `genericUiComponent`'s
  ## registration returns on the empty label and leaves an empty GL container
  ## behind.
  ##
  ## Both `componentName` (unresolved, what `addItem` takes) and
  ## `componentType` (resolved, the spelling a config restored from
  ## `auto_hide_state.json` carries) are accepted.
  ##
  ## Written as a raw JS predicate rather than a chain of `JsObject` field
  ## reads because those reads are exactly the hazard: `config.componentState`
  ## on an empty object is `undefined`, and the next `.` on it throws a native
  ## `TypeError`.  That is not theoretical — it is what `layout.nim`'s
  ## `unpinPanelTarget` did on its first line for every standalone pane.
  jsIsReattachableConfig(config)
