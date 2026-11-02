## component_ids_across_sessions_test.nim
##
## Regression test for issue #835: "New File" from a "+" tab breaks the
## editor when a replay is already open.
##
## THE DEFECT
##
## Every tab of a window is a `ReplaySession` with its own
## `ui.componentMapping`, but the DOM hosts and Monaco instances of all tabs
## live in ONE document: a hidden tab's `session-container-<n>` stays mounted
## so switching back is instant. An editor's host is the element with the
## document-global id `editorComponent-<id>` (`ui/layout.nim`'s
## `editorComponent` registration), and `ui/editor.nim` finds it with
## `getElementById` / `jq("#editorComponent-<id>")`, which return the FIRST
## match in document order. `utils.generateId` used to return the lowest id
## free in the ACTIVE tab only, so the "+" tab's untitled buffer got id 0 —
## the replay tab's editor's id. Its mount then found the replay's host,
## Monaco refused a second editor on it ("Element already has context
## attribute"), and the new tab's own host stayed blank.
##
## WHAT IS ASSERTED HERE
##
## * an editor (and a unified-diff tab, the other multi-instance pane whose
##   host is `<content>Component-<id>`) never gets an id another tab of the
##   window already uses;
## * the singleton chrome (Build, Menu, WelcomeScreen, …) keeps its per-tab id
##   0, because `data.buildComponent(0)` and friends look it up by that id;
## * an editor id that arrives from a layout config (a restored edit layout,
##   or a layout inherited from another tab) is re-assigned when another tab
##   already owns it, and two config editors never end up sharing an id.
##
## No fakes: the real `types.data`, `ReplaySession`s and `utils.generateId` /
## `utils.claimWindowUniqueLayoutIds`. Components are bare `Component`
## objects because only their presence in `componentMapping` matters to the
## id allocator.
##
## Runs under `just test-frontend-js` (lane `frontend-js`): the session
## forwarding templates and `utils.nim` are JS-only.

import std/[jsffi, unittest]
import ../types
import ../utils

proc addSession(): int =
  ## Append an empty tab the way `session_switch.createNewSession` shapes one
  ## (initialised component maps), and return its index. Does not activate it.
  var session = newReplaySession(ReplaySessionId(data.sessions.len))
  session.ui = Components(editors: JsAssoc[cstring, EditorViewComponent]{})
  for content in Content:
    session.ui.componentMapping[content] = JsAssoc[int, Component]{}
    session.ui.openComponentIds[content] = @[]
  data.sessions.add(session)
  data.sessions.len - 1

proc resetWindow() =
  ## One tab (the module's own session 0) with empty component maps.
  data.sessions.setLen(1)
  data.activeSessionIndex = 0
  if data.sessions[0].ui.isNil:
    data.sessions[0].ui = Components(editors: JsAssoc[cstring, EditorViewComponent]{})
  for content in Content:
    data.sessions[0].ui.componentMapping[content] = JsAssoc[int, Component]{}
    data.sessions[0].ui.openComponentIds[content] = @[]

proc occupy(sessionIndex: int, content: Content, id: int) =
  data.sessions[sessionIndex].ui.componentMapping[content][id] = Component(id: id)

suite "component ids across the tabs of one window (#835)":

  test "a new tab's editor id is not one the replay tab's editor uses":
    resetWindow()
    occupy(0, Content.EditorView, 0)
    let plus = addSession()
    data.activeSessionIndex = plus
    let id = data.generateId(Content.EditorView)
    check id != 0
    check id == 1

  test "a unified-diff tab id is unique across tabs too":
    resetWindow()
    occupy(0, Content.UnifiedDiff, 0)
    occupy(0, Content.UnifiedDiff, 1)
    let plus = addSession()
    data.activeSessionIndex = plus
    check data.generateId(Content.UnifiedDiff) == 2

  test "the lowest id free in every tab is taken, gaps included":
    resetWindow()
    occupy(0, Content.EditorView, 0)
    occupy(0, Content.EditorView, 2)
    let plus = addSession()
    occupy(plus, Content.EditorView, 1)
    data.activeSessionIndex = plus
    check data.generateId(Content.EditorView) == 3

  test "singleton chrome keeps id 0 in every tab":
    resetWindow()
    occupy(0, Content.Build, 0)
    occupy(0, Content.WelcomeScreen, 0)
    let plus = addSession()
    data.activeSessionIndex = plus
    check data.generateId(Content.Build) == 0
    check data.generateId(Content.WelcomeScreen) == 0

proc component(content: Content, id: int, label: string): JsObject =
  js{"type": cstring"component",
     "componentType": cstring(if content == Content.EditorView: "editorComponent"
                              else: "genericUiComponent"),
     "componentState": js{"id": id, "content": ord(content),
                          "label": cstring(label)}}

proc layoutWith(items: seq[JsObject]): JsObject =
  ## A minimal GoldenLayout tree: a row holding one stack of `items`.
  js{"type": cstring"row",
     "content": @[js{"type": cstring"stack", "content": items}]}

proc idAt(root: JsObject, index: int): int =
  root["content"][0]["content"][index]["componentState"]["id"].to(int)

suite "editor ids that arrive with a layout config (#835)":

  test "a config editor whose id another tab owns is re-numbered":
    resetWindow()
    occupy(0, Content.EditorView, 0)
    let plus = addSession()
    data.activeSessionIndex = plus
    let root = layoutWith(@[
      component(Content.EditorView, 0, "/tmp/a.py"),
      component(Content.Filesystem, 0, "filesystemComponent")])
    data.claimWindowUniqueLayoutIds(root)
    check idAt(root, 0) == 1
    # Not an editor: the Files pane keeps its per-tab id 0.
    check idAt(root, 1) == 0

  test "a re-numbered editor never takes an id a later config editor holds":
    resetWindow()
    occupy(0, Content.EditorView, 0)
    let plus = addSession()
    data.activeSessionIndex = plus
    let root = layoutWith(@[
      component(Content.EditorView, 0, "/tmp/a.py"),
      component(Content.EditorView, 1, "/tmp/b.py")])
    data.claimWindowUniqueLayoutIds(root)
    check idAt(root, 0) == 2
    check idAt(root, 1) == 1

  test "ids no other tab uses are left exactly as saved":
    resetWindow()
    let root = layoutWith(@[
      component(Content.EditorView, 3, "/tmp/a.py"),
      component(Content.EditorView, 5, "/tmp/b.py")])
    data.claimWindowUniqueLayoutIds(root)
    check idAt(root, 0) == 3
    check idAt(root, 1) == 5

  test "an id the active tab already owns is kept, not duplicated":
    # `createUIComponents` can run twice for one tab; the second walk must
    # find the tab's own editor again under the same id.
    resetWindow()
    occupy(0, Content.EditorView, 0)
    let root = layoutWith(@[component(Content.EditorView, 0, "/tmp/a.py")])
    data.claimWindowUniqueLayoutIds(root)
    check idAt(root, 0) == 0
