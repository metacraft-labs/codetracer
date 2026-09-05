## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
##
## A module here may import `codetracer_embed`, `headless_app`, `isonim`,
## `isonim_tui` and `std/*` modules that touch neither a process nor a
## terminal. Nothing else. `src/frontend/tui/tests/test_tui_facade_boundary.nim`
## walks this directory's import graph on every run.
##
## This module imports LESS than that rule allows, and deliberately: it needs
## `headless_app/layout_model` and `std/strutils` and nothing more. Profile
## selection is a pure function of two integers, and a module that could not
## reach a renderer cannot accidentally make it one.
##
## app/layout/profile.nim — CTUI-3. Which shape the screen takes, decided from
## its size alone.
##
## ## What this owns
##
## Three things, all of them values:
##
##   1. `selectProfile(width, height)` — the Compact / Standard / Ultra-wide
##      breakpoint rule of CodeTracer-TUI.md §3.2, as a PURE FUNCTION. The
##      milestone asks for it to be tested as one, independently of rendering,
##      and that is only possible because nothing here draws.
##   2. `bodyArea(width, height)` — where the multi-pane body sits once the
##      header and the status bar have taken their rows.
##   3. `profileLayout(profile)` — the `LayoutNode` for a profile. THE SAME
##      TYPE THE DESKTOP PERSISTS (`headless_app/layout_model`), not a second
##      layout model. `app/layout/project.nim` puts it onto Yoga.
##
## ## THE SPEC'S BREAKPOINTS OVERLAP, AND THIS RESOLVES THE OVERLAP EXPLICITLY
##
## §3.2 reads, verbatim:
##
##   1. Compact Profile (80 <= width < 120, **or height < 35**)
##   2. Standard Profile (120 <= width < 180, **and height >= 35**)
##   3. Ultra-Wide Profile (**width >= 180**)
##
## Rules 1 and 3 both claim `width >= 180, height < 35` — a 200x30 terminal,
## which is an ordinary shape on a wide monitor with a short window. Rule 2 is
## explicitly conjunctive about height and rule 3 is silent, so the reading
## taken here is that rule 1's height clause is the general one and rule 3
## inherits it: **height decides first**. Below 35 rows there is no room for a
## three-column body plus an eight-row timeline strip whatever the width is,
## which is the reason the clause exists at all.
##
## Written down rather than left to the implementation, because a breakpoint
## table that disagrees with itself is exactly the kind of thing that gets
## resolved differently by the next person who reads it.
##
## ## WHY `profileLayout` TAKES NO GEOMETRY
##
## `LayoutNode.weight` is a unitless relative share — `layout_model.nim` says
## so about itself and refuses to learn what axis it is measured in. So the
## tree for a profile is a constant, and every cell count in it comes from
## `project.nim` dividing a real area by those shares. The alternative — a tree
## whose weights are recomputed from the terminal's height so that a strip
## lands on exactly eight rows — would put a measurement in the model, which is
## the one thing the model is written to keep out.
##
## The 4:1 body-to-timeline share is chosen so that the Standard profile's
## strip is EIGHT rows at 120x40, which is the height §3.2 names. That is a
## property of the projection at one geometry, asserted in
## `app/tests/test_layout_profiles.nim`, not a promise at every geometry.

import std/strutils

import headless_app/layout_model

type
  LayoutProfile* = enum
    ## The three arrangements of CodeTracer-TUI.md §3.2.
    ##
    ## An enum with explicit strings rather than an int, because the profile
    ## appears in the status bar and in every failure message this milestone
    ## prints, and `$` on an unnamed enum is how a report becomes unreadable.
    lpCompact = "compact"
    lpStandard = "standard"
    lpUltraWide = "ultra-wide"

  CellArea* = object
    ## A rectangle of terminal cells, in ABSOLUTE screen coordinates.
    ##
    ## Distinct from `isonim_tui`'s `CellRect` on purpose: that one is a
    ## renderer's type and lives behind the layout engine, and this module —
    ## which is where the screen's shape is decided — must not need a renderer
    ## to say where the body is. `project.nim` converts.
    col*: int
    row*: int
    width*: int
    height*: int

const
  HeaderRows* = 1
    ## The session header (§3.3.1). One row in every profile: both ASCII
    ## drawings in §3.1 show one, and the session tabs share it rather than
    ## claiming a second — see `app/views/header.nim`.

  StatusRows* = 1
    ## The command line and status bar (§3.3.6).

  ChromeRows* = HeaderRows + StatusRows
    ## Everything the shell takes before the body gets a row.

  StandardMinWidth* = 120
    ## §3.2 rule 2's lower bound.
  UltraWideMinWidth* = 180
    ## §3.2 rule 3's lower bound.
  TallProfileMinHeight* = 35
    ## §3.2 rule 1's height clause. Below this the Compact profile is selected
    ## at every width — see the module header on the overlap.

  MinShellWidth* = 20
    ## Below this no profile can be laid out at all: the Compact body needs two
    ## columns and the header needs something legible in each. `project.nim`
    ## reports `prNoSpace` rather than drawing a hole.
  MinShellHeight* = ChromeRows + 2
    ## A header, a status bar, and at least one row for each of the Compact
    ## profile's two body rows.

proc selectProfile*(width, height: int): LayoutProfile =
  ## Which profile a `width` x `height` terminal gets. A pure function, with no
  ## state, no I/O and no renderer — which is what lets
  ## `app/tests/test_layout_profiles.nim` assert it over a grid of sizes
  ## instead of over screenshots.
  ##
  ## Height decides first; see the module header for why, and for the §3.2
  ## overlap that decision resolves.
  if height < TallProfileMinHeight:
    lpCompact
  elif width >= UltraWideMinWidth:
    lpUltraWide
  elif width >= StandardMinWidth:
    lpStandard
  else:
    lpCompact

proc bodyArea*(width, height: int): CellArea =
  ## The multi-pane region: everything between the header and the status bar.
  ##
  ## Clamped at zero rather than allowed to go negative, because a negative
  ## height would propagate into the projection as a rectangle that contains
  ## nothing and overlaps everything. A zero-height body is a reportable
  ## condition (`project.prNoSpace`); a negative one is a bug that hides.
  CellArea(col: 0, row: HeaderRows, width: max(0, width),
           height: max(0, height - ChromeRows))

proc profileLayout*(profile: LayoutProfile): LayoutNode =
  ## The `LayoutNode` a profile arranges its panes with.
  ##
  ## Column percentages are §3.2's, spelled as weights: they are relative
  ## shares, so 25/50/25 and 1/2/1 are the same tree. The literal percentages
  ## are kept because they are what the specification says and a reader
  ## comparing the two should not have to divide.
  ##
  ## THE COMPACT PROFILE'S BOTTOM ROW IS A `stack`, which is the milestone's
  ## load-bearing contract: `Alt+1/2/3` is `LayoutNode.activate`, the same
  ## operation `session_switch.nim` performs on a desktop tab click, rather
  ## than a second tab mechanism that only the terminal has.
  case profile
  of lpCompact:
    column([
      row([
        pane(paneCalltrace, "Call Stack", weight = 30.0),
        pane(paneEditor, "Source", weight = 70.0)],
        weight = 3.0),
      stack([
        pane(paneState, "Variables"),
        pane(paneTimeline, "Timeline"),
        pane(paneEventLog, "Tracepoints")],
        activeIndex = 0, weight = 1.0)])
  of lpStandard:
    column([
      row([
        pane(paneCalltrace, "Call Stack", weight = 25.0),
        pane(paneEditor, "Source", weight = 50.0),
        pane(paneState, "Variables", weight = 25.0)],
        weight = 4.0),
      pane(paneTimeline, "Timeline & Tracepoints", weight = 1.0)])
  of lpUltraWide:
    column([
      row([
        pane(paneCalltrace, "Call Stack", weight = 20.0),
        pane(paneEditor, "Source", weight = 45.0),
        pane(paneState, "Variables", weight = 20.0),
        pane(paneEventLog, "Event Log", weight = 15.0)],
        weight = 4.0),
      pane(paneTimeline, "Timeline & Tracepoints", weight = 1.0)])

proc profileTabs*(profile: LayoutProfile): seq[PaneKind] =
  ## The panes `Alt+1` / `Alt+2` / `Alt+3` select, in that order, or an empty
  ## sequence for a profile whose tree carries no stack.
  ##
  ## Read out of the tree rather than written down beside it: a second list
  ## would be a second thing to keep true, and the whole point of the contract
  ## above is that the tabs ARE the stack's children.
  # A local rather than `result`: Nim refuses to capture `result` in a closure,
  # and the walk below is recursive so it has to be one.
  var found: seq[PaneKind] = @[]
  let node = profileLayout(profile)
  proc walk(n: LayoutNode) =
    if n.isNil:
      return
    if n.kind == lnStack:
      for c in n.children:
        if c.kind == lnPane:
          found.add c.pane
      return
    for c in n.children:
      walk(c)
  walk(node)
  found

proc minPaneWidth*(kind: PaneKind): int =
  ## The narrowest column a pane can be given and still say anything.
  ##
  ## THE MINIMUM-SIZE CONTRACT IS EXPLICIT, which is CTUI-3's risk mitigation
  ## verbatim: "an explicit minimum-size contract per pane that the projection
  ## test enforces rather than discovers". These are cell counts, they are
  ## asserted at all three geometries, and a profile that cannot honour them at
  ## a size is a profile that must not be selected at that size.
  case kind
  of paneEditor: 24     ## a line number gutter, a pointer and some source
  of paneCalltrace: 14  ## `#0 process_item()` truncated but still legible
  of paneState: 14      ## `ptr: 0x7ffd98`
  of paneEventLog: 12
  of paneTimeline: 20   ## a scrubber with two ends and a marker
  else: 8

proc minPaneHeight*(kind: PaneKind): int =
  ## The shortest a pane can be: a title row plus at least one row of content.
  case kind
  of paneTimeline: 3    ## title, scrubber, one event line
  else: 2

proc minimumWidth*(profile: LayoutProfile): int =
  ## The narrowest terminal this profile's widest row can be laid out in.
  ##
  ## Derived from the tree rather than tabulated, so a profile whose columns
  ## change carries its own answer with it.
  let node = profileLayout(profile)
  proc walk(n: LayoutNode): int =
    if n.isNil:
      return 0
    case n.kind
    of lnPane:
      minPaneWidth(n.pane)
    of lnRow:
      var total = 0
      for c in n.children:
        total += walk(c)
      total
    of lnColumn:
      var widest = 0
      for c in n.children:
        widest = max(widest, walk(c))
      widest
    of lnStack:
      var widest = 0
      for c in n.children:
        widest = max(widest, walk(c))
      widest
  walk(node)

proc minimumHeight*(profile: LayoutProfile): int =
  ## The shortest terminal this profile fits in, INCLUDING the header and the
  ## status bar, so it is comparable with a terminal's own height.
  let node = profileLayout(profile)
  proc walk(n: LayoutNode): int =
    if n.isNil:
      return 0
    case n.kind
    of lnPane:
      minPaneHeight(n.pane)
    of lnColumn:
      var total = 0
      for c in n.children:
        total += walk(c)
      total
    of lnRow:
      var tallest = 0
      for c in n.children:
        tallest = max(tallest, walk(c))
      tallest
    of lnStack:
      var tallest = 0
      for c in n.children:
        tallest = max(tallest, walk(c))
      tallest
  walk(node) + ChromeRows

proc profileFits*(profile: LayoutProfile; width, height: int): bool =
  ## Whether `profile`'s minimum-size contract is satisfiable at this size.
  width >= minimumWidth(profile) and height >= minimumHeight(profile)

proc describeProfile*(profile: LayoutProfile; width, height: int): string =
  ## One line for a status bar or a failure message: what was selected, at what
  ## size, and what that profile needs.
  $profile & " " & $width & "x" & $height & " (min " &
    $minimumWidth(profile) & "x" & $minimumHeight(profile) & ")"

proc profileSummary*(): string =
  ## Every profile with its minimums, for a report that has to show what the
  ## breakpoint table actually resolved to.
  var parts: seq[string] = @[]
  for p in LayoutProfile:
    parts.add $p & ":" & $minimumWidth(p) & "x" & $minimumHeight(p)
  parts.join(" ")
