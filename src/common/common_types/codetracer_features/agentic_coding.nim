## Agentic Coding Integration types for the CodeTracer GUI (M9).
##
## This module defines the ACP (Agent Communication Protocol) extension types
## for DeepReview data and agent progress tracking. These types are used to:
##
## 1. Extend the ACP protocol with DeepReview notifications so that the
##    agent runtime can push coverage, flow, and test results to the GUI
##    in real-time during agent work sessions.
##
## 2. Track agent progress with milestones displayed in the caption bar
##    progress indicator, giving users visibility into the agent's workflow.
##
## 3. Support workspace view switching between the user's workspace and
##    the agent's workspace, with integrated DeepReview annotations.
##
## The types follow the same camelCase naming convention used by the
## existing DeepReview types (see ``deepreview.nim``) so that JSON
## deserialization via ``cast[T](JSON.parse(...))`` works directly.
##
## Reference: codetracer-specs/DeepReview/Agentic-Coding-Integration.md

# ---------------------------------------------------------------------------
# ACP DeepReview notification types
# ---------------------------------------------------------------------------

type
  DeepReviewNotificationKind* = enum
    ## The kind of real-time notification the agent runtime sends to the GUI
    ## as DeepReview data is collected during an agent work session.
    CoverageUpdate    ## Per-file line coverage has been (re-)computed.
    FlowTraceUpdate   ## A function execution flow trace is available.
    TestComplete      ## A single test run has finished.
    CollectionComplete ## All DeepReview data collection is done.

  DeepReviewNotification* = object
    ## A single DeepReview notification from the agent runtime to the GUI.
    ## The ``sessionId`` ties the notification to the ACP session that
    ## initiated the agent work. The variant fields carry the payload
    ## specific to each notification kind.
    sessionId*: cstring
    case kind*: DeepReviewNotificationKind
    of CoverageUpdate:
      ## Updated line coverage for a single file.
      filePath*: cstring
      linesCovered*: seq[int]
      linesUncovered*: seq[int]
    of FlowTraceUpdate:
      ## A new or updated function execution flow trace.
      flowFilePath*: cstring
      functionKey*: cstring
      executionIndex*: int
      stepCount*: int
    of TestComplete:
      ## Result of a single test run during agent work.
      testName*: cstring
      passed*: bool
      durationMs*: int
      traceContextId*: cstring
    of CollectionComplete:
      ## Summary emitted when all data collection finishes.
      totalFiles*: int
      totalFunctions*: int
      totalTests*: int

  AcpDeepReviewCapability* = object
    ## Capability advertisement sent during ACP session initialisation.
    ## When the agent runtime supports DeepReview integration it includes
    ## this object in its capability list so the GUI knows it can expect
    ## ``DeepReviewNotification`` messages.
    supported*: bool
    version*: cstring          ## Semantic version of the DeepReview protocol extension.
    supportsRealtime*: bool    ## Whether the runtime streams updates or batches them.
    supportedLanguages*: seq[cstring] ## Languages for which coverage/flow is available.

# ---------------------------------------------------------------------------
# Agent progress and milestone tracking
# ---------------------------------------------------------------------------

type
  AgentProgressState* = enum
    ## High-level state of the agent's execution lifecycle.
    ## Displayed in the caption bar progress indicator.
    AgentIdle          ## No active task; waiting for user input.
    AgentInitializing  ## Agent session is starting up.
    AgentWorking       ## Actively executing a task.
    AgentWaitingInput  ## Paused; waiting for user approval or input.
    AgentPaused        ## Temporarily paused (user-initiated).
    AgentCompleted     ## Task completed successfully.
    AgentFailed        ## Task failed with an error.

  MilestoneStatus* = enum
    ## Status of an individual milestone within a task.
    MilestonePending     ## Not yet started.
    MilestoneInProgress  ## Currently being worked on.
    MilestoneCompleted   ## Finished successfully.
    MilestoneFailed      ## Finished with an error.
    MilestoneSkipped     ## Intentionally skipped (e.g. not applicable).

  Milestone* = object
    ## A discrete unit of work within an agent task.
    ## Milestones are displayed as progress indicators in the caption bar
    ## and as a checklist in the activity pane.
    id*: cstring               ## Unique identifier within the task.
    content*: cstring          ## Human-readable description of the milestone.
    priority*: cstring         ## Priority level: "high", "medium", "low".
    status*: MilestoneStatus   ## Current completion status.

  AgentProgress* = object
    ## Aggregated progress state for the current agent task.
    ## Updated by the agent runtime via ACP messages and consumed by
    ## the caption bar progress indicator and activity pane.
    state*: AgentProgressState
    taskName*: cstring             ## Short description of the active task.
    milestonesCompleted*: int      ## Number of milestones finished so far.
    milestonesTotal*: int          ## Total number of milestones in the task.
    currentMilestone*: cstring     ## The ``id`` of the milestone being worked on.
    milestones*: seq[Milestone]    ## Full list of milestones for drill-down display.

# ---------------------------------------------------------------------------
# Workspace view types
# ---------------------------------------------------------------------------

type
  WorkspaceViewKind* = enum
    ## Which workspace is currently displayed in the editor area.
    ## The user can toggle between their own files and the agent's
    ## working tree via the caption bar progress indicator click.
    UserWorkspace    ## The user's own editor files and panels.
    AgentWorkspace   ## The agent's working directory with DeepReview overlay.

  WorkspaceViewState* = object
    ## Tracks the current workspace view and associated metadata.
    activeView*: WorkspaceViewKind
    agentWorkspacePath*: cstring   ## Root directory of the agent's workspace.
    agentSessionId*: cstring       ## ACP session owning the agent workspace.

# ---------------------------------------------------------------------------
# Activity pane DeepReview integration
# ---------------------------------------------------------------------------

type
  ActivityDeepReviewSummary* = object
    ## Summary statistics displayed in the agent activity pane alongside
    ## the conversation history. Gives the user a quick overview of
    ## code quality metrics for the agent's recent changes.
    totalLinesCovered*: int
    totalLinesUncovered*: int
    coveragePercent*: float        ## 0.0 .. 100.0
    testsRun*: int
    testsPassed*: int
    testsFailed*: int
    functionsTraced*: int
    lastUpdatedMs*: int            ## Timestamp of the most recent update (epoch ms).

  ActivityFileEntry* = object
    ## A single file entry in the activity pane's DeepReview file list.
    ## Each entry shows the file path and a coverage ratio badge.
    path*: cstring
    coveredLines*: int
    totalLines*: int
    hasFlow*: bool

# ---------------------------------------------------------------------------
# IPC message channel names
# ---------------------------------------------------------------------------

const
  ## IPC channel for DeepReview notifications from agent runtime to renderer.
  IPC_DEEPREVIEW_NOTIFICATION* = "CODETRACER::acp-deepreview-notification"

  ## IPC channel for agent progress updates from agent runtime to renderer.
  IPC_AGENT_PROGRESS* = "CODETRACER::acp-agent-progress"

  ## IPC channel for workspace view switch requests (renderer to main).
  IPC_WORKSPACE_VIEW_SWITCH* = "CODETRACER::workspace-view-switch"
