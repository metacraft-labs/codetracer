## ui/editor_surface.nim — the one place an editor surface of the desktop is
## made: Monaco's `monaco.editor.create`, or — under the developer setting
## `sharedEditor` (`shared_editor_flag`) — the shared editing core drawn as
## DOM (`shared_editor`) behind Monaco's API (`shared_editor_facade`).
##
## The editor pane's source editor (`ui/editor.createSourceEditorIn`), its
## macro expansions and low-level views, the removed lines' editors of a
## recording opened with a diff, the tracepoint editor (`ui/trace`) and the Agent Workspace's
## editor (`ui/agent_workspace`) are all made here, so with the setting on no
## editor surface of the desktop is Monaco's
## (docs/shared-editor-parity.md). The unified diff has its own maker
## (`shared_diff_editor.newSharedDiffEditor`), chosen by the same setting.

import std/jsffi

import ../types
import ./shared_editor
import ./shared_editor_facade
import ./shared_editor_flag

proc isNilOrUndef(v: JsObject): bool {.importjs: "(# == null)".}
proc jsStr(v: JsObject): cstring {.importjs: "String(#)".}
proc monacoCreate(host, options: JsObject): JsObject {.importjs:
  "monaco.editor.create(#, #)".}
proc setPageMonacoTheme(name: cstring) {.importjs:
  "(globalThis.monaco && globalThis.monaco.editor && globalThis.monaco.editor.setTheme && globalThis.monaco.editor.setTheme(#))".}

proc optString(o: JsObject; name: cstring): string =
  if isNilOrUndef(o[name]): "" else: $jsStr(o[name])

proc sharedSurfaceIn*(host: JsObject; options: JsObject; path: string;
                      fontSize: int; fontFamily: string;
                      darkTheme: bool): SharedEditor =
  ## The shared editor in `host`, made from Monaco's creation options
  ## (`value`, `language`, `readOnly`, `theme` and the rest, which the facade
  ## reads as Monaco's `updateOptions` would).
  installMonacoGlobals()
  # What `monaco.editor.create(host, {theme})` does: the theme is the
  # page's, and Monaco's colour variables follow it.
  let theme = optString(options, "theme")
  if theme.len > 0:
    setPageMonacoTheme(cstring(theme))
  let readOnly = not isNilOrUndef(options["readOnly"]) and options["readOnly"].to(bool)
  result = newSharedEditor(host, optString(options, "value"), path,
    optString(options, "language"), readOnly, fontSize, fontFamily,
    darkTheme, options)
  result.observeSize()

proc createEditorSurface*(host: JsObject; options: JsObject; config: Config;
                          path: string; fontSize: int; fontFamily: string;
                          darkTheme: bool; embeddedField = false): JsObject =
  ## Monaco's `create(host, options)`, or the shared editor's facade under
  ## the setting. `embeddedField`: a field inside another view (the
  ## tracepoint editor; `SharedEditor.embeddedField`).
  if sharedEditorEnabled(config):
    let ed = sharedSurfaceIn(host, options, path, fontSize, fontFamily, darkTheme)
    ed.embeddedField = embeddedField
    return facadeOf(ed)
  monacoCreate(host, options)
