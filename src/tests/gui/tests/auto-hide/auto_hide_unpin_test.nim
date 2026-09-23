## Headless cover for Unpin on an auto-hide strip tab — issue #692 (M46).
##
## The report: the four panes CodeTracer pins to the bottom strip on every
## startup — BUILD, PROBLEMS, FIND IN FILES, REQUESTS — offer an Unpin action
## in their tab context menu that does nothing at all.  The reporter expects
## unpinning to turn them into ordinary dockable panels, the way CALLTRACE /
## STATE / TERMINAL / EVENT LOG behave.
##
## Spec grounding
## --------------
## `codetracer-specs/Planned-Features/Auto-Hide-Panes.md` §3.2:
## "**Right-click**: opens the tab context menu (re-pin to another edge,
## Unpin). This is the only unpin/close affordance a strip tab has."  The
## sentence is unconditional — there is no carve-out for these four — so the
## fix is to make Unpin work, not to hide it.
##
## What is asserted where, and why it is split
## -------------------------------------------
## * **JS backend** — the real behaviour, against the real production
##   functions in `src/frontend/ui/auto_hide_panel_config.nim`.  That module
##   was extracted from `auto_hide.nim` precisely so these two rules can run
##   under `nim js -d:nodejs`: `auto_hide.nim` imports `kdom`, the frontend
##   `types.nim` object graph and GoldenLayout, and compiles on neither lane.
## * **Native backend** — a source contract over `auto_hide.nim` and
##   `layout.nim`, the two call sites the extracted rule has to be reached
##   from.  A correct helper that nothing calls is the failure mode this half
##   exists to catch, and it is the same pattern
##   `layout/layout_config_roundtrip_test.nim` uses for the persistence
##   invariants of the same two files.
##
## No mocks: the JS half calls the shipped procs, the native half reads the
## shipped sources off disk.
##
## Red-before-green-after, and WHICH HALF CARRIES IT
## -------------------------------------------------
## Every case in the source-contract suite fails against the tree as it was
## before M46 (`e96d65a0a`), where `addStandaloneAutoHidePanel` stored
## `config: js{}` and `unpinPanel` handed that empty object straight to
## GoldenLayout.
##
## **The nine JS cases do not.** Dropped into the pre-M46 tree with
## `auto_hide_panel_config.nim` as their only addition — `auto_hide.nim` and
## `layout.nim` still entirely unfixed — all nine pass. They are real
## behavioural assertions against the real procs, but their subject is the new
## module alone, so their whole red-before is "the file did not exist".
## The source-contract suite is therefore the ONLY arm in this file that goes
## red if the fix is reverted, and it must not be deleted as redundant.
##
## Known residual, `Testing/Verification-Harness-Traps.md` §35b
## ------------------------------------------------------------
## The source-contract cases compare SUBSTRINGS, and Nim's identifier equality
## is not string equality: `is_Editor` and `isEditor` are one identifier and
## two strings. Five of the six cases are wrong only in the safe direction — a
## respelled needle makes them fail, not pass. The sixth, *the unpin target
## does not dereference a state it never checked*, is a negative, so
## `panel.config.componentState.is_Editor` would satisfy it. Closing that
## needs a token-level normaliser (`nimIdentKey` / `identifierKeys` in §35b),
## and no shared one exists in this tree yet; re-deriving a private copy here
## is what §30a forbids. So it is written down rather than papered over, and
## the rule that actually guards the defect at runtime is `unpinPanel`'s
## `isReattachableConfig` call, covered by its own case.

import std/unittest

when defined(js):
  import std/jsffi
  import ../../../../frontend/ui/auto_hide_panel_config

  # `Content` ordinals, mirrored as literals so the test keeps the
  # dependency-free property of the module under test.  Source of truth:
  # `src/common/common_types/codetracer_features/frontend.nim`.
  const
    ContentBuild = 11
    ContentBuildErrors = 21
    ContentRequestPanel = 40
    ContentState = 4

  proc jsonStringify(value: JsObject): cstring {.importjs: "JSON.stringify(#)".}
  proc jsonParse(raw: cstring): JsObject {.importjs: "JSON.parse(#)".}

  suite "#692 standalone auto-hide panes carry a re-attachable config":

    test "an empty object is NOT something GoldenLayout can rebuild":
      ## This is the defect itself.  `addStandaloneAutoHidePanel` stored
      ## `js{}` and `unpinPanel` passed it to `addItem`, which has no
      ## component type to construct from — so nothing was added and the
      ## Unpin gesture was a no-op.
      check not isReattachableConfig(js{})

    test "neither is a config GoldenLayout cannot even be asked about":
      # `jsUndefined` / `jsNull` are `std/jsffi`'s own bindings for the two
      # values a config field can hold when nothing ever wrote it.
      check not isReattachableConfig(jsUndefined)
      check not isReattachableConfig(jsNull)

    test "a standalone pane's config names a component and a mount label":
      let config = standaloneComponentConfig(
        cstring"errorsComponent-0", ContentBuildErrors, 0)
      check $config["type"].to(cstring) == "component"
      check $config["componentName"].to(cstring) == "genericUiComponent"
      check $config["componentState"]["label"].to(cstring) ==
        "errorsComponent-0"
      check config["componentState"]["content"].to(int) == ContentBuildErrors
      check config["componentState"]["id"].to(int) == 0
      # `unpinPanelTarget` used to read this field on its very first line,
      # which is why an absent `componentState` threw a native `TypeError`
      # before `addItem` was ever reached.
      check not config["componentState"]["isEditor"].to(bool)

    test "and it IS something GoldenLayout can rebuild":
      check isReattachableConfig(
        standaloneComponentConfig(cstring"buildComponent-0", ContentBuild, 0))

    test "the config survives the JSON round-trip persistence uses":
      let raw = jsonStringify(
        standaloneComponentConfig(
          cstring"requestPanelComponent-0", ContentRequestPanel, 0))
      check isReattachableConfig(jsonParse(raw))

    test "a component type with no mount label is refused":
      ## `genericUiComponent`'s registration returns immediately when
      ## `state.label.len == 0`, so such a config produces an EMPTY GL
      ## container rather than nothing at all — a worse outcome than the
      ## no-op, because it looks like it worked.
      check not isReattachableConfig(js{
        "type": cstring"component",
        "componentName": cstring"genericUiComponent",
        "componentState": js{"id": 0, "content": ContentBuild}
      })
      check not isReattachableConfig(js{
        "type": cstring"component",
        "componentName": cstring"genericUiComponent",
        "componentState": js{"id": 0, "label": cstring"",
                             "content": ContentBuild}
      })

    test "a config with no component type at all is refused":
      check not isReattachableConfig(js{
        "type": cstring"component",
        "componentState": js{"label": cstring"buildComponent-0"}
      })

    test "a pinned panel's own config is accepted unchanged":
      ## `pinPanel` builds this shape from a live GoldenLayout item; the four
      ## panes CALLTRACE / STATE / TERMINAL / EVENT LOG reach `unpinPanel`
      ## with it, and they are the ones that already work.  The guard must
      ## not start refusing them.
      check isReattachableConfig(js{
        "type": cstring"component",
        "componentName": cstring"genericUiComponent",
        "componentState": js{
          "id": 0, "label": cstring"calltraceComponent-0",
          "content": ContentState, "isEditor": false
        }
      })

    test "a RESOLVED config restored from disk is accepted too":
      ## `auto_hide_state.json` stores GoldenLayout's resolved form, which
      ## spells the component `componentType` rather than `componentName` —
      ## see `layout/layout_config_roundtrip_test.nim`'s restore case.
      check isReattachableConfig(jsonParse(cstring"""
        {"componentType":"genericUiComponent",
         "componentState":{"id":0,"label":"stateComponent-0","content":4}}"""))

else:
  import std/strutils

  const
    AutoHidePath = "src/frontend/ui/auto_hide.nim"
    LayoutPath = "src/frontend/ui/layout.nim"
    ConfigPath = "src/frontend/ui/auto_hide_panel_config.nim"

  proc source(path: string): string =
    ## `readFile` raising here is the right failure: it means the production
    ## file this contract describes was moved or deleted.
    readFile(path)

  proc codeOnly(body: string): string =
    ## `body` with every comment dropped.
    ##
    ## A contract that greps raw source answers "the file mentions X", and a
    ## comment explaining why X was REMOVED mentions it just as loudly as the
    ## code would.  This whole suite is about text that must not be in the
    ## compiled program, so the comments come out first.  (Dropping from the
    ## first `#` also mangles `#`-bearing string literals; nothing asserted
    ## here reads one.)
    var lines: seq[string] = @[]
    for line in body.splitLines:
      let hash = line.find('#')
      lines.add(if hash >= 0: line[0 ..< hash] else: line)
    lines.join("\n")

  proc importedModules(body: string): seq[string] =
    ## Every module named by a top-level `import` / `from` in `body`.
    for line in codeOnly(body).splitLines:
      let stripped = line.strip()
      if stripped.startsWith("import ") or stripped.startsWith("from "):
        result.add(stripped)

  proc region(body, fromMarker: string; toMarkers: varargs[string]): string =
    let start = body.find(fromMarker)
    doAssert start >= 0, "marker not found in source: " & fromMarker
    var stop = body.len
    for marker in toMarkers:
      let candidate = body.find(marker, start + fromMarker.len)
      if candidate >= 0 and candidate < stop:
        stop = candidate
    body[start ..< stop]

  suite "#692 unpin (source contract)":

    test "the config module stays dependency-free":
      ## The whole reason it is a separate file is that the rule can then be
      ## exercised headlessly.  An import of `kdom`, `../types` or
      ## GoldenLayout would drag in the DOM world and kill the JS suite above.
      check importedModules(source(ConfigPath)) == @["import std/jsffi"]

    test "a standalone pane is registered WITH a GoldenLayout config":
      ## The defect: `config: js{},  # No GL config — standalone panel`.
      let body = codeOnly(region(source(AutoHidePath),
        "proc addStandaloneAutoHidePanel*", "\nproc ", "\ntype"))
      check not body.contains("config: js{}")
      check body.contains("standaloneComponentConfig(")

    test "layout.nim hands the component label to that registration":
      ## The label is not derivable from the content: PROBLEMS is
      ## `Content.BuildErrors` but mounts into `errorsComponent-0`.
      let body = codeOnly(region(source(LayoutPath),
        "      addStandaloneAutoHidePanel(", "\n  , 500)"))
      check body.contains("panelDef.label")

    test "unpinPanel asks whether the config can be rebuilt":
      let body = codeOnly(
        region(source(AutoHidePath), "proc unpinPanel*", "\nproc "))
      check body.contains("isReattachableConfig(")

    test "unpinPanel never leaves a panel latched mid-unpin":
      ## `panel.isUnpinning` suppresses the panel's strip tab
      ## (`panelsForEdge`) and its persistence (`serializeAutoHideState`).
      ## Leaving it set on a failed unpin makes the tab vanish with no panel
      ## anywhere — the second, independent half of issue #692.  The reset
      ## used to sit in the `except` arm alone, which is only reached when
      ## something raises; `addItem` returning quietly is not a raise.
      let body = codeOnly(
        region(source(AutoHidePath), "proc unpinPanel*", "\nproc "))
      let finallyAt = body.find("finally:")
      check finallyAt >= 0
      let tail = body[finallyAt .. ^1]
      check tail.contains("panel.isUnpinning = false")

    test "the unpin target does not dereference a state it never checked":
      ## `let isEditor = panel.config.componentState.isEditor.to(bool)` was
      ## the FIRST line of `unpinPanelTarget`, it bound a value nothing in
      ## the proc ever read, and on an empty config it threw a native
      ## `TypeError` before `addItem` was reached at all.
      let body = codeOnly(
        region(source(LayoutPath), "auto_hide.unpinPanelTarget =",
               "\n  autoHideState.onPanelShown"))
      # POSITIVE CONTROL, and the only case here that needs one.
      #
      # Every other case in this suite pairs its "must not contain" with a
      # "must contain" over the SAME region, so an empty or mis-sliced subject
      # shows up as a failure of the positive half.  This case is a lone
      # negative, and `Testing/Verification-Harness-Traps.md` §4 is exactly
      # that shape: a scan that matches nothing satisfies every "must not
      # contain" check written against it.  These two lines are the proc body
      # that the negative is about; if they are gone, the subject is no longer
      # `unpinPanelTarget` and the negative below means nothing.
      check body.contains("discard main.addItem(panel.config")
      check body.contains("let edge = panel.edge")
      check not body.contains("panel.config.componentState.isEditor")
