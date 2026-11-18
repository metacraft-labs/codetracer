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
      ## The story's name in StoryBook and the editor, and the title its frame
      ## shows (the golden-layout tab of a panel story) unless `frameTitle`
      ## names the panel.
    frameTitle*: string
      ## The panel's own name for its golden-layout tab (`Initiatives`),
      ## where the story's name says which state it shows (`Initiatives:
      ## Error`); empty: the story's name (`frameTitleOf`).
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
    state*: string
      ## What the story claims to show: `data` (its surface over realistic
      ## data, the default) or a declared `empty`, `loading` or `error`
      ## state. `storybook/scripts/check-story-render.mjs` (`just
      ## storybook-check-render`) fails a `data` story that renders a
      ## placeholder, an empty panel or a component's empty / loading / error
      ## fallback, and a story that declares a state but does not show it.
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
const storyStates* = ["data", "empty", "loading", "error"]
  ## The states a story may declare (`CodeTracerStory.state`).

func story(exportName, name, kind, surface: string; fixture = "populated";
           check = ""; description = ""; state = "data"): CodeTracerStory =
  CodeTracerStory(exportName: exportName, name: name, kind: kind,
                  surface: surface, fixture: fixture, check: check,
                  description: description, state: state)

func panel(exportName, name, surface: string; fixture = "populated";
           check = ""; description = ""; state = "data"): CodeTracerStory =
  story(exportName, name, "panel", surface, fixture, check, description, state)

func sessionActivityStories(): seq[CodeTracerStory] =
  ## The session activity timeline (`agent-harbor-session-activity`): one
  ## session's activity as a cardless timeline, framed as the Agent Activity
  ## panel, over the invented timelines and the invented `session-run`
  ## scenario (`stories/agent_harbor_stories.createSessionActivityStoryVM`).
  ## Every story runs the play check that holds the timeline cardless.
  const surface = "agent-harbor-session-activity"
  const check = "agent-harbor-session-activity"
  func activity(exportName, name, fixture, description: string;
                state = "data"; check = check): CodeTracerStory =
    panel(exportName, name, surface, fixture, check, description, state)
  @[
    activity("SessionActivity", "Session Activity", "populated",
             "A session with every group kind, each group closed: reads, searches, " &
               "shell commands with one failed, edits with their totals, a repeated hook"),
    activity("SessionActivityShort", "Session Activity: Short", "short",
             "A few lines and no group"),
    activity("SessionActivityKinds", "Session Activity: Every Kind", "every-kind",
             "One line of each kind of event, none grouped"),
    activity("SessionActivityGroupOpen", "Session Activity: Group Open", "group-open",
             "The shell commands' group open: its commands one line each"),
    activity("SessionActivityDetails", "Session Activity: Details", "details",
             "An edit's diff and a failed command's arguments and output open, each with Copy"),
    activity("SessionActivityCommandTrace", "Session Activity: Command Trace", "command-trace",
             "The commands' traces open: a pipeline with a failing stage, a long-running " &
               "child, a child that outlives its parent, a command with no trace"),
    activity("SessionActivityRunning", "Session Activity: Running", "running",
             "A command still running inside a group, named on the group line"),
    activity("SessionActivityNeedsInput", "Session Activity: Needs Input", "needs-input",
             "The agent waits on its question"),
    activity("SessionActivityFailed", "Session Activity: Failed", "failed",
             "Failed commands in a group, then the failure the agent stopped on: red once"),
    activity("SessionActivityLong", "Session Activity: Long Session", "long",
             "About four hundred events over twelve turns, with pauses; the list scrolls"),
    activity("SessionActivityReadingBack", "Session Activity: Reading Back", "reading-back",
             "The reader scrolled away while lines arrived: the view holds its place " &
               "and offers the new lines"),
    activity("SessionActivityFocused", "Session Activity: Focused Line", "focused",
             "A group line with the focus"),
    activity("SessionActivityLongNames", "Session Activity: Long Names", "long-names",
             "Long messages wrap; long paths are cut in their middle, long commands at their end"),
    activity("SessionActivityFilter", "Session Activity: Filtered", "filter",
             "The list filter keeps the lines that name the upload client"),
    activity("SessionActivityAgainstCards", "Session Activity: Against The Cards",
             "against-cards",
             "The same session's events as the cardless timeline and as today's " &
               "Agent Activity cards, side by side",
             check = "agent-harbor-session-activity-against-cards"),
    activity("SessionActivityEmpty", "Session Activity: Empty", "empty",
             "A session with no events yet", state = "empty"),
    activity("SessionActivityLoading", "Session Activity: Loading", "loading",
             "Waiting for the session's events", state = "loading"),
    activity("SessionActivityError", "Session Activity: Error", "error",
             "The session's events could not be read", state = "error"),
    activity("SessionActivityUnresolvable", "Session Activity: Unresolvable Session",
             "unresolvable",
             "A session the server does not hold: it says so, never an empty timeline",
             state = "error"),
    activity("SessionActivityPlayback", "Session Activity: Playback", "playback-session-run",
             "One session's work event by event while another session's events interleave; " &
               "its first frame is before the session's first event",
             state = "empty", check = "agent-harbor-session-activity-playback"),
    activity("SessionActivityPlaybackExpanded", "Session Activity: Playback, Group Open",
             "playback-session-run+expanded",
             "The same, with the shell group opened when it forms and kept open while " &
               "lines arrive below it",
             state = "empty", check = "agent-harbor-session-activity-playback"),
  ]

func agentHarborSection(): CodeTracerStorySection =
  ## CodeTracer as an Agent Harbor front-end: the prototypes of the panels
  ## that show an Agent Harbor fleet, over the viewmodels of
  ## nim-agents-isonim-viewmodels fed through its data-source seam
  ## (`src/frontend/stories/agent_harbor_stories.nim`). Inventory items
  ## INV-P2-01, INV-P2-12 (the fleet list); INV-C-01 to INV-C-06, INV-D-01,
  ## INV-D-02 (sessions as tabs, in the strip, the sidebar and docked);
  ## INV-D-04, INV-P2-26 (initiatives); INV-D-05, INV-P2-44 (initiative
  ## progress).
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
            "Waiting for the server's first answer",
            state = "loading"),
      panel("FleetError", "Fleet: Error", "agent-harbor-fleet",
            "error", "agent-harbor-fleet-error",
            "The server could not be reached",
            state = "error"),
      panel("FleetEmpty", "Fleet: Empty", "agent-harbor-fleet",
            "empty", "agent-harbor-fleet-empty",
            "A server with no sessions",
            state = "empty"),
      panel("FleetFilteredEmpty", "Fleet: Filter Leaves Nothing", "agent-harbor-fleet",
            "filtered-empty", "agent-harbor-fleet-filtered-empty",
            "The working set under the Queued filter: no session matches",
            state = "empty"),
      panel("FleetExpanded", "Fleet: Activity Unfolded", "agent-harbor-fleet",
            "expanded", "agent-harbor-fleet-expanded",
            "The snapshot with one row's activity lines unfolded"),
      story("SessionTabsSingleLine", "Session Tabs: One Line", "view", "agent-harbor-session-tabs", "single-line",
            "agent-harbor-session-tabs",
            "The working set as tabs on one line, the rest in the overflow menu"),
      story("SessionTabsActiveOverflowed", "Session Tabs: Active Tab From The Overflow", "view", "agent-harbor-session-tabs", "single-line-active-late",
            "agent-harbor-session-tabs-active",
            "A late tab active (it takes the last visible place); the overflow menu open"),
      # The same menu over a panel's ground rather than the window's: a panel
      # lies under the caption bar, as in the shell, where the menu drops over
      # whichever panel is below the bar.
      story("SessionTabsMenuOverPanel", "Session Tabs: Overflow Menu Over A Panel", "view",
            "agent-harbor-session-tabs", "menu-over-panel",
            "agent-harbor-session-tabs-active",
            "The overflow menu opening over the panel under the caption bar"),
      story("SessionTabsMultiLine", "Session Tabs: Several Lines", "view", "agent-harbor-session-tabs", "multi-line",
            "agent-harbor-session-tabs-multi",
            "The working set wrapping onto several lines"),
      story("SessionTabsSingleLineOverflow", "Session Tabs: One Line, 40 Sessions", "view", "agent-harbor-session-tabs", "single-line-40",
            "agent-harbor-session-tabs-overflow",
            "Forty invented sessions over five initiatives on one line"),
      story("SessionTabsMultiLineOverflow", "Session Tabs: Several Lines, 40 Sessions", "view", "agent-harbor-session-tabs", "multi-line-40",
            "agent-harbor-session-tabs-multi-overflow",
            "Forty invented sessions over five initiatives, wrapped"),
      story("SessionTabsLongNames", "Session Tabs: Long Names", "view", "agent-harbor-session-tabs", "long-names",
            "agent-harbor-session-tabs",
            "Invented sessions with very long titles"),
      story("SessionTabsNeedsInputWins", "Session Tabs: Every Wait Needs Input", "view", "agent-harbor-session-tabs", "needs-input-wins",
            "agent-harbor-session-tabs",
            "The other effective-status policy: an ended turn reads needs input too"),
      story("SessionTabsFocusedInitiative", "Session Tabs: Initiative Focused", "view", "agent-harbor-session-tabs", "focused-initiative",
            "agent-harbor-session-tabs-focus",
            "An initiative selected: its tabs highlighted, its first active"),
      story("SessionTabsEmpty", "Session Tabs: Empty", "view", "agent-harbor-session-tabs", "empty",
            "agent-harbor-session-tabs-empty",
            "A server with no sessions",
            state = "empty"),
      story("SessionTabsLoading", "Session Tabs: Loading", "view", "agent-harbor-session-tabs", "loading",
            "agent-harbor-session-tabs-loading",
            "Waiting for the server's first answer",
            state = "loading"),
      story("SessionTabsError", "Session Tabs: Error", "view", "agent-harbor-session-tabs", "error",
            "agent-harbor-session-tabs-error",
            "The server could not be reached",
            state = "error"),
      story("SessionListSidebar", "Session List: Sidebar", "view", "agent-harbor-session-list", "sidebar",
            "agent-harbor-session-list",
            "The tabs as a sidebar list, grouped by initiative"),
      story("SessionListSidebarUngrouped", "Session List: Sidebar, Ungrouped", "view", "agent-harbor-session-list", "sidebar-ungrouped",
            "agent-harbor-session-list",
            "The sidebar in launch order, no groups"),
      story("SessionListSidebarCollapsed", "Session List: Sidebar Collapsed", "view", "agent-harbor-session-list", "sidebar-collapsed",
            "agent-harbor-session-list-collapsed",
            "The sidebar collapsed to a rail of status marks"),
      story("SessionListSidebarOverflow", "Session List: Sidebar, 40 Sessions", "view", "agent-harbor-session-list", "sidebar-40",
            "agent-harbor-session-list",
            "Forty invented sessions over five initiatives; the list scrolls"),
      story("SessionListDocked", "Session List: Docked", "panel", "agent-harbor-session-list", "docked",
            "agent-harbor-session-list",
            "The tabs docked as a panel"),
      story("SessionListDockedOverflow", "Session List: Docked, 40 Sessions", "panel", "agent-harbor-session-list", "docked-40",
            "agent-harbor-session-list",
            "Forty invented sessions docked as a panel"),
      story("InitiativeTabs", "Initiative Tabs", "view", "agent-harbor-initiative-tabs", "tabs",
            "agent-harbor-initiative-tabs",
            "One tab per initiative with its state and n/m milestones; the active one with its recordings"),
      story("InitiativeTabsPopup", "Initiative Tabs: Progress Popup", "view", "agent-harbor-initiative-tabs", "popup",
            "agent-harbor-initiative-tabs-popup",
            "The first initiative's progress popup, as on hover"),
      # The same popup over a panel's ground rather than the window's: a
      # panel lies under the caption bar, as in the shell, where the popup
      # drops over whichever panel is below the bar.
      story("InitiativeTabsPopupOverPanel", "Initiative Tabs: Popup Over A Panel", "view",
            "agent-harbor-initiative-tabs", "popup-over-panel",
            "agent-harbor-initiative-tabs-popup",
            "The progress popup opening over the panel under the caption bar"),
      story("InitiativeTabsElsewhere", "Initiative Tabs: Sessions Started Elsewhere", "view", "agent-harbor-initiative-tabs", "elsewhere",
            "agent-harbor-initiative-tabs-elsewhere",
            "The [N agent harbor sessions] menu open"),
      story("InitiativeTabsElsewhereOverPanel", "Initiative Tabs: Elsewhere Menu Over A Panel", "view",
            "agent-harbor-initiative-tabs", "elsewhere-over-panel",
            "agent-harbor-initiative-tabs-elsewhere",
            "The [N agent harbor sessions] menu opening over the panel under the caption bar"),
      story("InitiativeTabsNext", "Initiative Tabs: Next Session", "view", "agent-harbor-initiative-tabs", "next",
            "agent-harbor-initiative-tabs-inbox",
            "Next taken: the first waiting session in view, its position in the inbox"),
      story("InitiativeTabsAutoSwitch", "Initiative Tabs: Auto-Switch", "view", "agent-harbor-initiative-tabs", "auto-switch",
            "agent-harbor-initiative-tabs-inbox",
            "Auto-switch on: after the instruction, the next waiting session came up"),
      story("InitiativeTabsRecordingsMany", "Initiative Tabs: Many Recordings", "view", "agent-harbor-initiative-tabs", "recordings-many",
            "agent-harbor-initiative-tabs-recordings",
            "Twelve recordings: five buttons and +7 on a wide bar, the active one and +11 on a compact one; one loading, one failed, one missing"),
      story("InitiativeTabsOverflow", "Initiative Tabs: 40 Sessions Over 5", "view", "agent-harbor-initiative-tabs", "overflow-40",
            "agent-harbor-initiative-tabs",
            "Five invented initiatives and forty sessions"),
      story("InitiativeTabsOverflowMenuOverPanel", "Initiative Tabs: Overflow Menu Over A Panel", "view",
            "agent-harbor-initiative-tabs", "overflow-menu-over-panel",
            "agent-harbor-initiative-tabs-overflow-menu",
            "Forty invented sessions over five initiatives, the +N menu opening over the panel under the caption bar"),
      # The menu hangs from its chip; with the chip near the window's left
      # edge (a narrow bar draws only the short active tab before it), it
      # shifts right only as far as the window requires.
      story("InitiativeTabsOverflowMenuNearLeft", "Initiative Tabs: Overflow Menu Near The Left Edge", "view",
            "agent-harbor-initiative-tabs", "overflow-menu-near-left",
            "agent-harbor-initiative-tabs-overflow-menu",
            "Forty invented sessions over five initiatives, the shortest-named one active and the +N menu open"),
      story("InitiativeTabsLongNames", "Initiative Tabs: Long Names", "view", "agent-harbor-initiative-tabs", "long-names",
            "agent-harbor-initiative-tabs",
            "Invented initiatives with very long names"),
      story("InitiativeTabsRealPlans", "Initiative Tabs: Real Plans", "view", "agent-harbor-initiative-tabs", "real",
            "agent-harbor-initiative-tabs",
            "The real running plans and the real fleet sessions: Agent Harbor reports no session's plan yet, so only the capturing host's own session is associated (with the CodeTracer plan)"),
      story("InitiativeTabsEmpty", "Initiative Tabs: Empty", "view", "agent-harbor-initiative-tabs", "empty",
            "agent-harbor-initiative-tabs-empty",
            "No initiative is running",
            state = "empty"),
      story("InitiativeTabsLoading", "Initiative Tabs: Loading", "view", "agent-harbor-initiative-tabs", "loading",
            "agent-harbor-initiative-tabs-loading",
            "Waiting for the server's first answer",
            state = "loading"),
      story("InitiativeTabsError", "Initiative Tabs: Error", "view", "agent-harbor-initiative-tabs", "error",
            "agent-harbor-initiative-tabs-error",
            "The server could not be reached",
            state = "error"),
      story("SessionListSidebarTreeFolded", "Session List: Initiatives Tree, Folded", "view", "agent-harbor-session-list", "sidebar-tree-folded",
            "agent-harbor-session-list-tree",
            "The sidebar as the initiatives tree, its first two nodes folded"),
      story("SessionListEmpty", "Session List: Empty", "view", "agent-harbor-session-list", "empty",
            "agent-harbor-session-list-empty",
            "A server with no sessions",
            state = "empty"),
      story("SessionListLoading", "Session List: Loading", "view", "agent-harbor-session-list", "loading",
            "agent-harbor-session-list-loading",
            "Waiting for the server's first answer",
            state = "loading"),
      story("SessionListError", "Session List: Error", "view", "agent-harbor-session-list", "error",
            "agent-harbor-session-list-error",
            "The server could not be reached",
            state = "error"),
      panel("Initiatives", "Initiatives", "agent-harbor-initiatives", "populated",
            "agent-harbor-initiatives",
            "The running initiatives of the captured plans and their sessions"),
      panel("InitiativesSelected", "Initiatives: Selected", "agent-harbor-initiatives", "selected",
            "agent-harbor-initiatives-selected",
            "The initiative most sessions work on, selected"),
      panel("InitiativesOverflow", "Initiatives: 40 Sessions Over 5", "agent-harbor-initiatives", "overflow-40",
            "agent-harbor-initiatives",
            "Five invented initiatives with forty sessions"),
      panel("InitiativesLongNames", "Initiatives: Long Names", "agent-harbor-initiatives", "long-names",
            "agent-harbor-initiatives",
            "Invented initiatives and sessions with very long names"),
      panel("InitiativesRealPlans", "Initiatives: Real Plans", "agent-harbor-initiatives", "real",
            "agent-harbor-initiatives",
            "The real running plans and the real fleet sessions; only the capturing host's own session is associated with a plan (Agent Harbor reports no association yet)"),
      panel("InitiativesEmpty", "Initiatives: Empty", "agent-harbor-initiatives", "empty",
            "agent-harbor-initiatives-empty",
            "A server with no running initiative",
            state = "empty"),
      panel("InitiativesLoading", "Initiatives: Loading", "agent-harbor-initiatives", "loading",
            "agent-harbor-initiatives-loading",
            "Waiting for the server's first answer",
            state = "loading"),
      panel("InitiativesError", "Initiatives: Error", "agent-harbor-initiatives", "error",
            "agent-harbor-initiatives-error",
            "The server could not be reached",
            state = "error"),
      panel("InitiativeProgress", "Initiative Progress", "agent-harbor-initiative-progress", "current",
            "agent-harbor-progress",
            "The progress of the initiative most sessions work on"),
      panel("InitiativeProgressBlocked", "Initiative Progress: Blocked Milestone", "agent-harbor-initiative-progress", "blocked",
            "agent-harbor-progress-blocked",
            "An initiative with a blocked milestone"),
      panel("InitiativeProgressEvent", "Initiative Progress: Milestone Completed", "agent-harbor-initiative-progress", "progress-event",
            "agent-harbor-progress",
            "After a progress event: the current milestone completed"),
      panel("InitiativeProgressLongNames", "Initiative Progress: Long Names", "agent-harbor-initiative-progress", "long-names",
            "agent-harbor-progress",
            "An invented initiative with very long milestone titles"),
      panel("InitiativeProgressNoSummary", "Initiative Progress: No Summary", "agent-harbor-initiative-progress", "no-summary",
            "agent-harbor-progress",
            "A plan that states no executive summary"),
      panel("InitiativeProgressRealPlan", "Initiative Progress: Real Plan", "agent-harbor-initiative-progress", "real-plan",
            "agent-harbor-progress",
            "A real running plan's progress (the CodeTracer plan, the one a real session runs)"),
      panel("InitiativeProgressUnknown", "Initiative Progress: Unknown Initiative", "agent-harbor-initiative-progress", "unknown",
            "agent-harbor-progress-empty",
            "An initiative the server does not know",
            state = "empty"),
      panel("InitiativeProgressLoading", "Initiative Progress: Loading", "agent-harbor-initiative-progress", "loading",
            "agent-harbor-progress-loading",
            "Waiting for the server's first answer",
            state = "loading"),
      panel("InitiativeProgressError", "Initiative Progress: Error", "agent-harbor-initiative-progress", "error",
            "agent-harbor-progress-error",
            "The server could not be reached",
            state = "error"),
      # Playback stories (`agent_harbor_playback.nim`): each surface over a
      # synthetic scenario replayed on a clock, which the story host's chrome
      # plays, pauses, steps and seeks. Each opens at the scenario's first
      # frame (a host can open it at a named moment instead).
      story("SessionTabsPlayback", "Session Tabs: Playback", "view",
            "agent-harbor-session-tabs", "playback-front-ends", "agent-harbor-playback",
            "Sessions from several front-ends start, ask, are answered, fail and end; a tab appears mid-run"),
      story("SessionListPlayback", "Session List: Playback", "view",
            "agent-harbor-session-list", "playback-front-ends", "agent-harbor-playback",
            "The sidebar's initiatives tree while its sessions move between states"),
      story("InitiativeTabsPlayback", "Initiative Tabs: Playback", "view",
            "agent-harbor-initiative-tabs", "playback-initiative-run", "agent-harbor-playback",
            "An initiative's milestones move and its recordings appear loading, fail and turn ready"),
      panel("InitiativesPlayback", "Initiatives: Playback", "agent-harbor-initiatives",
            "playback-front-ends", "agent-harbor-playback",
            "The running initiative while its sessions and milestones move"),
      panel("InitiativeProgressPlayback", "Initiative Progress: Playback",
            "agent-harbor-initiative-progress", "playback-initiative-run",
            "agent-harbor-playback",
            "An initiative's milestones over its run: one blocked and resumed, the plan completed"),
      panel("FleetPlayback", "Fleet: Playback", "agent-harbor-fleet", "playback-front-ends",
            "agent-harbor-playback",
            "The fleet list while sessions start, need input, fail, end and are removed"),
    ] & sessionActivityStories())

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
      panel("CommandPalette", "Command Palette", "command-palette"),
      # The toolbar in the caption bar, where the app draws it.
      story("DebugControls", "Debug Controls", "view", "debug-controls"),
      story("LiveMcrDebugControls", "Live MCR Debug Controls", "view",
            "debug-controls", "live-mcr"),
      story("DeepReview", "Deep Review", "layout", "deepreview", check = "deep-review",
            description = "A review with src/shield.nr selected: the VCS panel in " &
              "DeepReview mode and the file's diff tab, with the values the " &
              "recording holds beside the changed lines"),
      panel("Editor", "Editor", "editor", check = "editor-gutter"),
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
      panel("Shell", "Shell", "shell", check = "shell-rows"),
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
      @[story("DebugShell", "Debug Shell", "view", "debug-shell",
              check = "debug-shell")] &
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
      panel("BuildRunning", "Build Running", "build", "running"),
      panel("ErrorsEmpty", "Errors Empty", "errors", "empty",
            state = "empty"),
      panel("TerminalEmpty", "Terminal Empty", "terminal-output", "empty",
            state = "empty"),
      panel("TerminalLoading", "Terminal Loading", "terminal-output", "loading",
            state = "loading"),
      panel("WelcomeRecord", "Welcome Record", "welcome-screen", "record"),
      panel("WelcomeOnlineTrace", "Welcome Online Trace", "welcome-screen",
            "online"),
    ])

func agenticWindows(): seq[CodeTracerStory] =
  ## CodeTracer as an Agent Harbor front-end in whole windows: one moment of
  ## one invented project per story (`stories/layout_story_data.nim`, its
  ## fixture names the moment), the window as the app composes it -- caption
  ## bar with the Agent Harbor tabs the story shows, the panels in the
  ## session container, the status bar -- with Deep Review, the debugger
  ## panels, Test Results and the agent's session side by side: sessions as
  ## tabs (one row, several rows, a sidebar), initiatives as tabs with their
  ## recording buttons, the sessions started elsewhere, Previous/Next with
  ## auto-switch, and the initiatives and their progress, in context.
  func window(exportName, name, moment, description: string): CodeTracerStory =
    # The moments whose editor replays a recording made before the clamp
    # (`storybook_components.mountReplayEditor`): their play checks that the
    # editor shows that revision, not the reviewed one.
    const replayMoments = ["debug-failing-test", "needs-input", "inbox-next",
                           "remote-test-triage", "initiatives-popup",
                           "session-sidebar", "top-bar-one-row", "top-bar-rows",
                           "omnibox-routing"]
    story(exportName, name, "layout", "agentic-window", moment,
          check = (if moment in replayMoments: "layout-editor-before-clamp" else: ""),
          description = description)
  @[
    window("L1FailingTestAgentAtWork", "L1 Failing Test, Agent At Work",
           "debug-failing-test",
           "Debugging shield_never_negative in its recording while the agent " &
             "clamps the damage: initiative tabs with recording buttons, editor, " &
             "the failing nargo test, Variables, the call trace, the agent's session"),
    window("L2ReviewingAnAgentsChange", "L2 Reviewing An Agent's Change",
           "review-agent-change",
           "The agent's clamp in Deep Review (changed lines with recorded values), " &
             "the tests it ran with their recordings, and the call trace of the " &
             "recording, opened from its session tab"),
    window("L3AgentNeedsInput", "L3 Agent Needs Input Mid-Debugging", "needs-input",
           "Next took the view to the drained-field test's question; its agent " &
             "asks to open a recording in a new tab, waiting for one-click approval"),
    window("L4AgentHarborArrangement", "L4 Agent Harbor Arrangement",
           "harbor-arrangement",
           "The Initiatives panel docked left, each initiative over its sessions, the " &
             "session in view in the centre, its change in Deep Review on the right"),
    window("L5RemoteTestRunsStreaming", "L5 Remote Test Runs Streaming",
           "remote-test-runs",
           "nargo test on the arm64 and macOS runners streaming into Test Results " &
             "with a recording per test, beside the agent that started them and " &
             "its initiative's progress"),
    window("L6InitiativesPopupAndElsewhere", "L6 Initiatives, Popup And Sessions Elsewhere",
           "initiatives-popup",
           "Four initiatives as tabs, the progress popup over Shield model " &
             "hardening and the sessions-started-elsewhere menu open"),
    window("L7ControlCenter", "L7 Control Center Tab", "control-center",
           "The control center as a full-window tab: every initiative and its " &
             "state, the selected one's progress, the sessions by initiative"),
    window("L8AgentDeliversADeepReview", "L8 Agent Delivers A Deep Review",
           "agent-delivers-review",
           "The agent's session ends with its result, which opened Deep Review on " &
             "the changed lines with recorded values and the tests it ran"),
    window("L9SessionTabsInASidebar", "L9 Session Tabs In A Sidebar", "session-sidebar",
           "The sessions as a sidebar list beside a debugging layout"),
    window("L10SessionTabsOnOneRow", "L10 Session Tabs On One Row", "top-bar-one-row",
           "The sessions as tabs on one row of the caption bar, the rest in the " &
             "open overflow menu"),
    window("L11SessionTabsOnSeveralRows", "L11 Session Tabs On Several Rows",
           "top-bar-rows",
           "The sessions as tabs wrapping onto several rows; the caption bar grows"),
    window("L12OmniboxInstructionRouted", "L12 Omnibox Instruction Routed",
           "omnibox-routing",
           "An instruction typed in the omnibox for an agent, with where it can " &
             "go: the session in view, the initiative's manager agent, a UI action"),
    window("L13InboxMovesToTheNextSession", "L13 Inbox Moves To The Next Session",
           "inbox-next",
           "Auto-switch on: once the drained-field question was answered the view " &
             "moved to the next waiting session, the macOS timeout"),
    window("L14RemoteTestFailureTriaged", "L14 Remote Test Failure Triaged",
           "remote-test-triage",
           "negative_field_fails timed out on macOS: its remote recording opened " &
             "from the Runners tab, the failed row selected, the agent's report"),
  ]

func layoutsSection(): CodeTracerStorySection =
  func debug(exportName, name, fixture: string): CodeTracerStory =
    story(exportName, name, "layout", "default-debug", fixture)
  CodeTracerStorySection(
    title: "CodeTracer/Layouts",
    group: "Layouts",
    module: "CodeTracerLayouts",
    description: "Whole windows: the agentic surfaces in realistic development " &
      "moments, the default debugging layout and the app shell",
    stories: agenticWindows() & @[
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
            "terminal-output-empty",
            state = "empty"),
      panel("Loading", "Loading", "terminal-output", "loading",
            "terminal-output-loading",
            state = "loading"),
    ])

const agentHarborPanelNames = [
  ("agent-harbor-fleet", "Fleet Snapshot"),
  ("agent-harbor-session-list", "Sessions"),
  ("agent-harbor-initiatives", "Initiatives"),
  ("agent-harbor-initiative-progress", "Initiative Progress"),
  ("agent-harbor-session-activity", "Agent Activity"),
]
  ## Each Agent Harbor panel's own name: what its golden-layout tab says in
  ## every story of it, whichever state the story shows.

func withAgentHarborPanelNames(section: CodeTracerStorySection): CodeTracerStorySection =
  result = section
  for story in result.stories.mitems:
    if story.kind == "panel":
      for (surface, title) in agentHarborPanelNames:
        if story.surface == surface: story.frameTitle = title

func codeTracerStorySections*(): seq[CodeTracerStorySection] =
  ## Every story, by section, in the order the editor lists them: the Agent
  ## Harbor prototypes first, then CodeTracer's existing surfaces.
  @[
    agentHarborSection().withAgentHarborPanelNames(),
    panelsSection(),
    componentsSection(),
    viewsSection(),
    fixturesSection(),
    layoutsSection(),
    terminalOutputSection(),
  ]

func frameTitleOf*(story: CodeTracerStory): string =
  ## The title the story's frame shows: the panel's own name where the
  ## story names one, else the story's name.
  if story.frameTitle.len > 0: story.frameTitle else: story.name

func describe*(story: CodeTracerStory): string =
  ## The story's description, or one naming what it mounts.
  if story.description.len > 0: story.description
  else: story.kind & " " & story.surface & ", fixture " & story.fixture

func validateStorySections*(sections: seq[CodeTracerStorySection]): seq[string] =
  ## The problems that would make the two surfaces disagree or a story
  ## unreachable: a duplicate section title, group or module, a duplicate
  ## export or name inside a section (StoryBook ids and editor story refs
  ## must be unique), an export name StoryBook cannot index (it must be a
  ## capitalised identifier), an unknown kind or state, and a fixture named
  ## for a state (`empty`, `loading`, `error`) in a story that does not
  ## declare that state. Empty means valid.
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
      if story.state notin storyStates:
        result.add "unknown state " & story.state & " in " & where
      # A fixture named for a state shows that state, so the story must say
      # so: the render check holds a `data` story to showing data.
      for word in ["empty", "loading", "error"]:
        if (story.fixture == word or story.fixture.endsWith("-" & word)) and
            story.state != word:
          result.add where & ": fixture " & story.fixture & " shows the " &
            word & " state; declare state = \"" & word & "\""
