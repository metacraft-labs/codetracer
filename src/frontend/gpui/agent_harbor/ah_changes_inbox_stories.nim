## gpui/agent_harbor/ah_changes_inbox_stories.nim — CTF-P3. A story of the
## Changes panel or the Inbox, mounted in GPUI.
##
## The web mounts these stories (`storybook_components.nim`) with the story
## constructors of `stories/agent_harbor_changes_inbox_stories.nim`
## (`createChangesStoryVM`, `createInboxStoryVM`, `createInboxItemStoryVM`)
## and their host contexts; `mountChangesInboxStory` is the same for GPUI:
## the SAME constructors and contexts, so a GPUI story shows the viewmodel
## state the web story of the same id shows, drawn by `ah_changes_panel.nim`
## and `ah_inbox_panel.nim`. `ah_stories.mountAgentHarborStoryGpui` calls it
## for the three surfaces it names (`ChangesInboxSurfaces`), inside its
## reactive root.

import ../../stories/agent_harbor_playback
import ../../stories/agent_harbor_changes_inbox_stories
import ./ah_changes_panel
import ./ah_inbox_panel

export agent_harbor_changes_inbox_stories, ah_changes_panel, ah_inbox_panel

const
  ChangesInboxSurfaces* = ["agent-harbor-changes", "agent-harbor-inbox",
                           "agent-harbor-inbox-item"]
    ## The surfaces this module mounts.

type
  ChangesInboxMount* = object
    ## The viewmodel a mounted story shows (the one field its surface uses)
    ## and what its host was asked that has no viewmodel seam.
    changes*: ChangesVM
    inbox*: InboxVM
    inboxItem*: InboxItemVM
    requests*: StoryHostRequests

proc mountChangesInboxStory*(r: GpuiRenderer; host: GpuiElement; surface, fixture: string;
                             playback: AhPlayback; p: AhPalette;
                             widthPx: int): ChangesInboxMount =
  ## Builds the story's viewmodel with its constructor and mounts its view in
  ## `host`, `widthPx` wide. Call inside a reactive root; the caller disposes
  ## the viewmodel it returns. Raises `ValueError` for a surface this module
  ## does not mount, and (from the constructors) for a fixture the surface
  ## does not name.
  result.requests = StoryHostRequests()
  case surface
  of "agent-harbor-changes":
    result.changes = createChangesStoryVM(fixture)
    r.mountChangesPanel(host, result.changes, p, widthPx, changesStoryContext(fixture))
  of "agent-harbor-inbox":
    result.inbox = createInboxStoryVM(fixture, playback)
    r.mountInboxPanel(host, result.inbox, p, widthPx,
                      inboxStoryContext(fixture, result.requests))
  of "agent-harbor-inbox-item":
    result.inboxItem = createInboxItemStoryVM(fixture)
    r.mountInboxItemPage(host, result.inboxItem, p, widthPx,
                         inboxItemStoryContext(fixture, result.requests))
  else:
    raise newException(ValueError, "no GPUI rendering of the Changes or Inbox surface " &
                       surface & " (story fixture " & fixture & ")")

proc dispose*(m: ChangesInboxMount) =
  ## Disposes the viewmodel the story built.
  if m.changes != nil: m.changes.dispose()
  if m.inbox != nil: m.inbox.dispose()
  if m.inboxItem != nil: m.inboxItem.dispose()
