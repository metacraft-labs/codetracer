## Headless cover for the layout-routing rule that decides whether a request to
## open a panel is answered by revealing an already-pinned (auto-hidden) panel
## or by opening a GoldenLayout tab.
##
## `openLayoutTab` and `auto_hide.findPanelToRevealOnOpen` both drive
## GoldenLayout and the DOM and cannot run headlessly, so the decision they turn
## on is factored into `revealsPinnedPanel` / `opensAsDocumentTab` in
## `src/common/common_types/codetracer_features/frontend.nim`, which compile on
## the C backend.  This file is the ViewModel-layer half of the headless-first
## policy for the GUI spec `src/tests/gui/tests/auto-hide/auto-hide-panes.spec.ts`
## ("editor unpin behavior").
##
## No mocks: these are pure functions over the real production rule.
##
## Spec grounding
## --------------
## * `codetracer-specs/GUI/Core-Panes/Editor-Pane.md`, "Tab Management":
##   "Multiple files can be open simultaneously as tabs."  So an editor pinned
##   to an auto-hide edge must not absorb the request to open a *different*
##   file — that request has to reach the layout and produce its own tab.
## * `codetracer-specs/Planned-Features/Auto-Hide-Panes.md` §1.1: a pinned panel
##   "slides in as a floating overlay on top of the Golden Layout area, without
##   displacing the existing layout".  Revealing the pinned panel is the right
##   answer when the request names *that* panel — which for a singleton is any
##   request for its content kind.
## * `codetracer-specs/Planned-Features/Auto-Hide-Panes.md` §6.1 lists the
##   panels auto-hide is a good fit for and marks the Editor "No — primary work
##   area".  That is guidance about a default layout, not a restriction on the
##   feature: §1.2 gives *every* GoldenLayout stack a pin control, so pinning an
##   editor is a supported state and must behave correctly.

import std/unittest

import ../../../../common/types as ct_types

suite "openLayoutTab: revealing a pinned auto-hide panel":

  test "a singleton panel is revealed by any request for its content":
    # BUILD / PROBLEMS / SEARCH RESULTS / REQUESTS and the ordinary sidebar
    # panes have exactly one instance, so the pinned one *is* the panel asked
    # for.  They carry no document path.
    check revealsPinnedPanel(
      ct_types.Content.Build, isEditor = false,
      requestedPath = "", pinnedPath = "")
    check revealsPinnedPanel(
      ct_types.Content.SearchResults, isEditor = false,
      requestedPath = "", pinnedPath = "")
    check revealsPinnedPanel(
      ct_types.Content.Filesystem, isEditor = false,
      requestedPath = "", pinnedPath = "")

  test "a pinned editor is revealed for the file it actually holds":
    check revealsPinnedPanel(
      ct_types.Content.EditorView, isEditor = true,
      requestedPath = "/src/main.py", pinnedPath = "/src/main.py")

  test "a pinned editor does NOT absorb a request for another file":
    # The defect behind issue #567 / milestone M18: matching on the content
    # kind alone meant that pinning one editor made every later "open a file"
    # request resolve to that single panel, so no other file could ever be
    # opened — contradicting Editor-Pane.md's "Multiple files can be open
    # simultaneously as tabs".
    check not revealsPinnedPanel(
      ct_types.Content.EditorView, isEditor = true,
      requestedPath = "/src/other.py", pinnedPath = "/src/main.py")
    # Also true when the request arrives without `isEditor`: an editor tab is a
    # document whichever way it is asked for.
    check not revealsPinnedPanel(
      ct_types.Content.EditorView, isEditor = false,
      requestedPath = "/src/other.py", pinnedPath = "/src/main.py")

  test "a pinned VCS diff tab does NOT absorb another diff target":
    # Same shape for the VCS panel's per-target `View Diff` tabs, whose
    # independence is the subject of issues #561 / #611.
    check revealsPinnedPanel(
      ct_types.Content.VCS, isEditor = true,
      requestedPath = "diff:a.nim", pinnedPath = "diff:a.nim")
    check not revealsPinnedPanel(
      ct_types.Content.VCS, isEditor = true,
      requestedPath = "diff:b.nim", pinnedPath = "diff:a.nim")

  test "the docked singleton VCS panel is still revealed":
    # `View Diff` opens documents; opening the VCS panel itself does not.
    check revealsPinnedPanel(
      ct_types.Content.VCS, isEditor = false,
      requestedPath = "", pinnedPath = "")

  test "a document request never matches a pinned panel with no identity":
    # A pinned panel whose serialised component state carries no label (a
    # standalone auto-hide pane, or a config that did not survive a restart)
    # has no document identity and must not swallow a document request.
    check not revealsPinnedPanel(
      ct_types.Content.EditorView, isEditor = true,
      requestedPath = "/src/main.py", pinnedPath = "")
    # …and a request with no path of its own cannot claim one either.
    check not revealsPinnedPanel(
      ct_types.Content.EditorView, isEditor = true,
      requestedPath = "", pinnedPath = "")

suite "opensAsDocumentTab":

  test "editor views and independent tabs are documents":
    check opensAsDocumentTab(ct_types.Content.EditorView, isEditor = true)
    check opensAsDocumentTab(ct_types.Content.EditorView, isEditor = false)
    check opensAsDocumentTab(ct_types.Content.VCS, isEditor = true)
    # `openNoSourceView` opens NO SOURCE as an editor-area document too.
    check opensAsDocumentTab(ct_types.Content.NoInfo, isEditor = true)

  test "singleton panels are not documents":
    check not opensAsDocumentTab(ct_types.Content.VCS, isEditor = false)
    check not opensAsDocumentTab(ct_types.Content.Build, isEditor = false)
    check not opensAsDocumentTab(ct_types.Content.Filesystem, isEditor = false)
    check not opensAsDocumentTab(ct_types.Content.SearchResults, isEditor = false)
