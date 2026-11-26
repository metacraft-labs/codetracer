## test_zgui_story_mount.nim — a declared story's production view, mounted
## through `ZguiRenderer` on zgui's headless platform.
##
## The story-parity harness draws every story with every renderer through
## `stories/story_mount` and `stories/story_frames`; this suite holds that the
## zgui arm of it builds the same document the DOM arm does:
##
##   * the frame a panel story gets (`#root-container … .lm_stack`, one active
##     tab titled with the panel's name, the `.ct-storybook-panel-content`
##     host), element for element as `storybook/stories/lib/surfaces.js`
##     builds it;
##   * the Event Log and Calltrace panels' production views
##     (`renderEventLogPanel` / `renderCalltracePanel`) over the story store,
##     instantiated with a renderer that is not `MockRenderer`. The Calltrace
##     view's rows used to bind `insertBefore` to `MockRenderer`'s at the
##     view's definition, so no other native renderer could instantiate the
##     panel at all.
##
## The text the views show is read back out of zgui's document.
##
## ## NO MOCKS
##
## zgui is the real runtime on its headless platform (`zrNowhere`: every
## stage but drawing). The story store's backend is `MockBackendService`, the
## stand-in the ViewModel testing architecture names for stories, which the
## StoryBook render of the same stories uses.

import std/[strutils, unittest]

import isonim_zgui/[renderer, testing]

import ../../stories/[story_frames, story_mount]
import ../zgui_view_support

var countedAssertions = 0
const ExpectedAssertions = 22

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc firstWithClass(node: ZguiNode; class: string): ZguiNode =
  if (" " & node.getAttribute("class") & " ").contains(" " & class & " "):
    return node
  for i in 0 ..< node.childCount:
    let found = firstWithClass(node.nthChild(i), class)
    if not found.isNil: return found

proc mountStory(surface, title: string): tuple[host: ZguiNode, dispose: StoryDispose] =
  var host: ZguiNode
  var dispose: StoryDispose
  openHeadless(1600, 1000, storySurfaceCss, zrNowhere, proc(root: ZguiNode) =
    let r = ZguiRenderer()
    let surfaceEl = createSurface(r, root, "panel", surface)
    host = createAppShell(r, surfaceEl, "panel", surface, title)
    dispose = mountPanelStory(r, host, surface, "populated"))
  discard settle()
  (host, dispose)

suite "a panel story mounted through ZguiRenderer":

  test "the Event Log story: the frame, the tab and the story's events":
    let (host, dispose) = mountStory("event-log", "Event Log")
    try:
      ck not host.isNil
      ck host.getAttribute("class") == "ct-storybook-panel-content"
      let panel = firstWithClass(host, "eventLog")
      ck not panel.isNil
      ck "stdout: Positive Test Case" in panel.textContent
      ck "stdout: Damage: 100" in panel.textContent
    finally:
      dispose()
      closeHeadless()

  test "the Calltrace story instantiates with a renderer that is not MockRenderer":
    let (host, dispose) = mountStory("calltrace", "Calltrace")
    try:
      let panel = firstWithClass(host, "calltrace-view")
      ck not panel.isNil
      ck "iterate_asteroids" in panel.textContent
      ck "calculate_damage" in panel.textContent
    finally:
      dispose()
      closeHeadless()

  test "every panel story the harness mounts instantiates with ZguiRenderer":
    # The REPL, Terminal Output, Low Level Code, Trace Log and Errors views
    # read MockRenderer's nodes or bound its operations natively, and could
    # not be drawn by any other native renderer.
    for surface in ["repl", "terminal-output", "low-level-code", "trace-log",
                    "errors", "search-results", "state", "filesystem"]:
      let (host, dispose) = mountStory(surface, titleize(surface))
      try:
        ck host.childCount > 0
      finally:
        dispose()
        closeHeadless()

  test "the Event Log's list carries the browser's scrubber, placed once laid out":
    # The browser hides the scroll body's own bar (`.ct-scrubbed`) and draws
    # a track over its right edge (`list_scrubber_dom`); a native renderer
    # draws the same elements (`list_scrubber_native`, `zgui_view_support`).
    let (host, dispose) = mountStory("event-log", "Event Log")
    try:
      let body = firstWithClass(host, "eventLog-scroll-body")
      ck "ct-scrubbed" in body.getAttribute("class")
      let track = firstWithClass(host, "ct-list-scrubber")
      ck not track.isNil
      refreshScrubbers(1.0)
      discard settle()
      ck track.getAttribute("data-ct-scrub-total") == "70"
      let thumb = firstWithClass(track, "ct-list-scrubber-thumb")
      ck parseInt(thumb.getAttribute("data-ct-thumb-px")) > 0
    finally:
      dispose()
      closeHeadless()

  test "the frame's one tab is active and names the panel":
    var root: ZguiNode
    openHeadless(800, 600, storySurfaceCss, zrNowhere, proc(r0: ZguiNode) =
      root = r0
      let r = ZguiRenderer()
      discard createAppShell(r, root, "panel", "event-log", ""))
    try:
      discard settle()
      let tab = firstWithClass(root, "lm_tab")
      ck "lm_active" in tab.getAttribute("class")
      ck firstWithClass(tab, "lm_title").textContent == "Event Log"
    finally:
      closeHeadless()

  test "the suite ran every assertion":
    check countedAssertions == ExpectedAssertions
