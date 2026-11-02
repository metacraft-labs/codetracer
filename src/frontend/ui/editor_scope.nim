## editor_scope.nim — PLAT-68: the desktop editor's element in the scope path.
##
## A leaf (`jsffi` and the Monaco bindings only), because both the editor
## (which stamps it) and the router (which reads the focus through it) need
## it, and the router may not import the editor.

import std/jsffi

import ../lib/monaco_lib

proc editorScopeElement*(editor: MonacoEditor): JsObject =
  ## The editor VIEW's element: the `.code-editor` container around the
  ## Monaco instance — the element a press on the read-only text focuses —
  ## or the instance's own node when it has none.
  let node = editor.toJs.getDomNode()
  if node.isNil or node.isUndefined:
    return node
  let view = node.closest(cstring".code-editor")
  if view.isNil or view.isUndefined: node else: view
