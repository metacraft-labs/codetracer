## The one declaration of CodeTracer's stories.
##
## A story is a named state of a CodeTracer surface: which surface (a panel,
## a shell view, a building-block component or a whole layout), which fixture
## its viewmodel is built over, and how a reviewer finds it. Two review
## surfaces show the same stories:
##
## - StoryBook (`storybook/`). `tools/stories/emit_storybook_stories.nim`
##   writes one CSF file per section into `storybook/stories/generated/` from
##   this list; nothing else declares a StoryBook story.
## - The IsoNim Editor instance (`src/frontend/isonim_editor_codetracer.nim`,
##   `just isonim-editor-codetracer`). It turns each section into an editor
##   story group and each story into a component story.
##
## Both mount a story the same way: `mountCodeTracerStory(container, kind,
## surface, fixture)` in `storybook_components.nim` builds the story's
## viewmodel over its fixture and renders the production IsoNim view. So a
## story added, renamed or removed here changes both surfaces, and neither can
## carry a story the other lacks.
##
## This module is plain data: it compiles natively (for the StoryBook
## generator) and to JavaScript (for the editor and the StoryBook bundle), and
## imports nothing from either surface.

import std/[sets, strutils]

type
  CodeTracerStory* = object
    exportName*: string
      ## The CSF export name. StoryBook derives the story's id and its
      ## sidebar name from it (`FleetSnapshot` -> `...--fleet-snapshot`,
      ## "Fleet Snapshot"), so changing it changes the story's URL.
    name*: string
      ## The title the story's frame shows (the golden-layout tab of a panel
      ## story) and the story's name in the editor.
    kind*: string
      ## `panel`, `view`, `component` or `layout`: how the surface is framed
      ## (`storybook/stories/lib/surfaces.js` `renderSurface`).
    surface*: string
      ## The surface `mountCodeTracerStory` dispatches on.
    fixture*: string
      ## The fixture the surface's viewmodel is built over.
    check*: string
      ## A named StoryBook play check (`storybook/stories/lib/plays.js`) run
      ## after the default "the surface mounted" check; empty for none.
    description*: string

  CodeTracerStorySection* = object
    title*: string
      ## The StoryBook title (`CodeTracer/Agent Harbor`); part of every
      ## story id in the section.
    group*: string
      ## The editor's story-group name.
    module*: string
      ## The generated CSF file's stem (`<module>.stories.js`).
    description*: string
    stories*: seq[CodeTracerStory]

const storyKinds* = ["panel", "view", "component", "layout"]

func story(exportName, name, kind, surface: string; fixture = "populated";
           check = ""; description = ""): CodeTracerStory =
  CodeTracerStory(exportName: exportName, name: name, kind: kind,
                  surface: surface, fixture: fixture, check: check,
                  description: description)

func panel(exportName, name, surface: string; fixture = "populated";
           check = ""; description = ""): CodeTracerStory =
  story(exportName, name, "panel", surface, fixture, check, description)

func agentHarborSection(): CodeTracerStorySection =
  ## CodeTracer as an Agent Harbor front-end: the prototypes of the panels
  ## that show an Agent Harbor fleet, over the viewmodels of
  ## nim-agents-isonim-viewmodels fed through its data-source seam
  ## (`src/frontend/stories/agent_harbor_stories.nim`). Inventory items
  ## INV-P2-01, INV-P2-12.
  CodeTracerStorySection(
    title: "CodeTracer/Agent Harbor",
    group: "Agent Harbor",
    module: "AgentHarbor",
    description: "Prototypes of the panels that show an Agent Harbor fleet",
    stories: @[
      panel("FleetSnapshot", "Fleet Snapshot", "agent-harbor-fleet",
            "snapshot", "agent-harbor-fleet-snapshot",
            "Every session of the captured fleet, those waiting for a person first"),
      panel("FleetNeedsInput", "Fleet: Needs Input", "agent-harbor-fleet",
            "needs-input", "agent-harbor-fleet-needs-input",
            "The snapshot under the needs-input filter"),
      panel("FleetFailed", "Fleet: Failed", "agent-harbor-fleet",
            "failed", "agent-harbor-fleet-failed",
            "The snapshot under the failed filter"),
      panel("FleetSelected", "Fleet: Selected Session", "agent-harbor-fleet",
            "selected", "agent-harbor-fleet-selected",
            "The snapshot with its first session selected"),
      panel("FleetLoading", "Fleet: Loading", "agent-harbor-fleet",
            "loading", "agent-harbor-fleet-loading",
            "Waiting for the server's first answer"),
      panel("FleetError", "Fleet: Error", "agent-harbor-fleet",
            "error", "agent-harbor-fleet-error",
            "The server could not be reached"),
      panel("FleetEmpty", "Fleet: Empty", "agent-harbor-fleet",
            "empty", "agent-harbor-fleet-empty",
            "A server with no sessions"),
    ])

func panelsSection(): CodeTracerStorySection =
  CodeTracerStorySection(
    title: "CodeTracer/Panels",
    group: "Panels",
    module: "CodeTracerSurfaces",
    description: "Every CodeTracer panel over its populated fixture",
    stories: @[
      panel("AgentActivity", "Agent Activity", "agent-activity"),
      panel("AgentWorkspace", "Agent Workspace", "agent-workspace"),
      panel("Build", "Build", "build"),
      panel("Calltrace", "Calltrace", "calltrace"),
      panel("CalltraceEditor", "Calltrace Editor", "calltrace-editor"),
      panel("CommandPalette", "Command Palette", "command-palette"),
      panel("DebugControls", "Debug Controls", "debug-controls"),
      panel("LiveMcrDebugControls", "Live MCR Debug Controls",
            "debug-controls", "live-mcr"),
      panel("DeepReview", "Deep Review", "deepreview"),
      panel("Editor", "Editor", "editor"),
      panel("Errors", "Errors", "errors"),
      panel("EventLog", "Event Log", "event-log"),
      panel("Filesystem", "Filesystem", "filesystem"),
      panel("Flow", "Flow", "flow"),
      panel("FrameViewer", "Frame Viewer", "frame-viewer", check = "frame-viewer"),
      panel("PixelHistory", "Pixel History", "pixel-history"),
      panel("ShaderDebug", "Shader Debugger", "shader-debug"),
      panel("LowLevelCode", "Low Level Code", "low-level-code"),
      panel("NoSource", "No Source", "no-source"),
      panel("PointList", "Point List", "point-list"),
      panel("Repl", "Repl", "repl"),
      panel("RequestPanel", "Request Panel", "request-panel"),
      panel("Scratchpad", "Scratchpad", "scratchpad"),
      panel("Search", "Search", "search"),
      panel("SearchResults", "Search Results", "search-results"),
      panel("Shell", "Shell", "shell"),
      panel("State", "State", "state"),
      panel("StepList", "Step List", "step-list"),
      panel("TerminalOutput", "Terminal Output", "terminal-output"),
      panel("TestResults", "Test Results", "test-results"),
      panel("TraceLog", "Trace Log", "trace-log"),
      panel("Vcs", "VCS", "vcs"),
      panel("WelcomeScreen", "Welcome Screen", "welcome-screen"),
    ])

func shellPieces(kind: string): seq[CodeTracerStory] =
  ## The shell's building blocks, shown as a bare `component` and inside the
  ## app frame as a `view`; the two sections list the same pieces.
  @[
    story("MenuShell", "Menu Shell", kind, "menu-shell"),
    story("StatusShell", "Status Shell", kind, "status-shell"),
    story("SessionTabs", "Session Tabs", kind, "session-tabs"),
  ]

func autoHidePieces(kind: string): seq[CodeTracerStory] =
  @[
    story("AutoHideBottomStrip", "Auto Hide Bottom Strip", kind,
          "auto-hide-bottom-strip"),
    story("AutoHideCollapsedIcons", "Auto Hide Collapsed Icons", kind,
          "auto-hide-collapsed-icons"),
    story("AutoHideOverlayTabs", "Auto Hide Overlay Tabs", kind,
          "auto-hide-overlay-tabs"),
    story("AutoHideSideStrip", "Auto Hide Side Strip", kind,
          "auto-hide-side-strip"),
  ]

func componentsSection(): CodeTracerStorySection =
  CodeTracerStorySection(
    title: "CodeTracer/Components",
    group: "Components",
    module: "CodeTracerComponents",
    description: "The shell's building blocks, unframed",
    stories: shellPieces("component") & autoHidePieces("component"))

func viewsSection(): CodeTracerStorySection =
  CodeTracerStorySection(
    title: "CodeTracer/Views",
    group: "Views",
    module: "CodeTracerViews",
    description: "The shell's building blocks in the app frame",
    stories: shellPieces("view") &
      @[story("DebugShell", "Debug Shell", "view", "debug-shell")] &
      autoHidePieces("view") &
      @[story("AutoHideSideStripCollapsed", "Auto Hide Side Strip Collapsed",
              "view", "auto-hide-side-strip", "collapsed")])

func fixturesSection(): CodeTracerStorySection =
  CodeTracerStorySection(
    title: "CodeTracer/Fixtures",
    group: "Fixtures",
    module: "CodeTracerFixtures",
    description: "Panels in their loading, empty and alternative states",
    stories: @[
      panel("BuildRunning", "Build Running", "build", "loading"),
      panel("ErrorsEmpty", "Errors Empty", "errors", "empty"),
      panel("TerminalEmpty", "Terminal Empty", "terminal-output", "empty"),
      panel("TerminalLoading", "Terminal Loading", "terminal-output", "loading"),
      panel("WelcomeRecord", "Welcome Record", "welcome-screen", "record"),
      panel("WelcomeOnlineTrace", "Welcome Online Trace", "welcome-screen",
            "online"),
    ])

func layoutsSection(): CodeTracerStorySection =
  func debug(exportName, name, fixture: string): CodeTracerStory =
    story(exportName, name, "layout", "default-debug", fixture)
  CodeTracerStorySection(
    title: "CodeTracer/Layouts",
    group: "Layouts",
    module: "CodeTracerLayouts",
    description: "The default debugging layout and the app shell",
    stories: @[
      debug("DefaultDebug", "Default Debug", "populated"),
      debug("McrVisualDebug", "MCR Visual Debug", "mcr-visual"),
      debug("NoirFilesystemActive", "Noir Filesystem Active", "filesystem-active"),
      debug("NoirStateActive", "Noir State Active", "state-active"),
      debug("NoirCalltraceActive", "Noir Calltrace Active", "calltrace-active"),
      debug("NoirCalltraceSearchStatusReport",
            "Noir Calltrace Search Status Report",
            "calltrace-search-status-report"),
      debug("NoirMenuViewOpen", "Noir Menu View Open", "menu-view-open"),
      debug("NoirStatusExpanded", "Noir Status Expanded", "status-expanded"),
      debug("NoirFixedSearchVisible", "Noir Fixed Search Visible",
            "fixed-search-visible"),
      debug("NoirSearchResultsPopulated", "Noir Search Results Populated",
            "search-results-populated"),
      debug("NoirCommandPaletteOpen", "Noir Command Palette Open",
            "command-palette-open"),
      debug("NoirBuildOpen", "Noir Build Open", "build-open"),
      debug("NoirTraceLogOpen", "Noir Trace Log Open", "trace-log-open"),
      debug("NoirDebugControlsHeader", "Noir Debug Controls Header",
            "debug-controls-header"),
      story("StandaloneAppShell", "Standalone App Shell", "layout",
            "standalone-app-shell"),
      panel("Welcome", "Welcome", "welcome-screen"),
    ])

func terminalOutputSection(): CodeTracerStorySection =
  CodeTracerStorySection(
    title: "CodeTracer/Compatibility/Terminal Output",
    group: "Compatibility / Terminal Output",
    module: "TerminalOutput",
    description: "The terminal output panel's original stories",
    stories: @[
      panel("Populated", "Populated", "terminal-output", "demo",
            "terminal-output-populated"),
      panel("Empty", "Empty", "terminal-output", "empty",
            "terminal-output-empty"),
      panel("Loading", "Loading", "terminal-output", "loading",
            "terminal-output-loading"),
    ])

func codeTracerStorySections*(): seq[CodeTracerStorySection] =
  ## Every story, by section, in the order the editor lists them: the Agent
  ## Harbor prototypes first, then CodeTracer's existing surfaces.
  @[
    agentHarborSection(),
    panelsSection(),
    componentsSection(),
    viewsSection(),
    fixturesSection(),
    layoutsSection(),
    terminalOutputSection(),
  ]

func describe*(story: CodeTracerStory): string =
  ## The story's description, or one naming what it mounts.
  if story.description.len > 0: story.description
  else: story.kind & " " & story.surface & ", fixture " & story.fixture

func validateStorySections*(sections: seq[CodeTracerStorySection]): seq[string] =
  ## The problems that would make the two surfaces disagree or a story
  ## unreachable: a duplicate section title, group or module, a duplicate
  ## export or name inside a section (StoryBook ids and editor story refs
  ## must be unique), an export name StoryBook cannot index (it must be a
  ## capitalised identifier), and an unknown kind. Empty means valid.
  var titles, groups, modules: HashSet[string]
  for section in sections:
    if section.title in titles: result.add "duplicate section title " & section.title
    if section.group in groups: result.add "duplicate editor group " & section.group
    if section.module in modules: result.add "duplicate module " & section.module
    titles.incl section.title
    groups.incl section.group
    modules.incl section.module
    if section.stories.len == 0:
      result.add section.title & " has no stories"
    var exports, names: HashSet[string]
    for story in section.stories:
      let where = section.title & "/" & story.exportName
      if story.exportName in exports: result.add "duplicate export " & where
      if story.name in names: result.add "duplicate name " & section.title & "/" & story.name
      exports.incl story.exportName
      names.incl story.name
      if story.exportName.len == 0 or story.exportName[0] notin {'A'..'Z'} or
          not story.exportName.allCharsInSet(IdentChars):
        result.add "export name is not a capitalised identifier: " & where
      if story.kind notin storyKinds:
        result.add "unknown kind " & story.kind & " in " & where
      if story.surface.len == 0 or story.fixture.len == 0:
        result.add "missing surface or fixture in " & where
