## viewmodels/replay_open_setting.nim — the workspace setting `replay-open-in`:
## where a test's recording opens when no modifier is held, `new-tab` (the
## default) or `current-tab`, PER WORKSPACE (`Test-Results-Pane.md` §9.3,
## Multi-Window-Tab-Management "Which tab a replay opens in").
##
## ONE DOCUMENT FOR EVERY FRONT-END, `replay-open-in` in the native state root
## — the `table-columns` precedent (Horizontal-Overflow.md §5.2): the terminal
## and the GPUI window read and write it themselves
## (`viewmodel/host/native_test_host`), the desktop's main process does it for
## its renderer (`index/replay_open_in.nim`). One line per workspace:
##
##     /home/me/project<TAB>current-tab
##
## A workspace with no line, a missing or unreadable document and a line with
## a value this build does not know all answer the default. The workspace is
## the folder the Test Results pane lists, as an absolute path without a
## trailing separator.
##
## The commands that set it are here too, by their palette labels, so the
## three front-ends offer the same two words.
##
## Pure: C and JavaScript backends.

import std/strutils

import ./trace_open

export trace_open

const
  ReplayOpenSettingName* = "replay-open-in"
  ReplayOpenFileName* = "replay-open-in"
    ## The document's file name in the native state root.
  OpenRecordingsInNewTabLabel* = "Tests: Open Recordings in a New Tab"
  OpenRecordingsInCurrentTabLabel* = "Tests: Open Recordings in the Current Tab"
  ReplayOpenCommandPrefix* = "replayOpenIn:"
    ## The native omnibox entries' target: `replayOpenIn:<new-tab|current-tab>`.

type
  ReplayOpenEntry* = object
    workspace*: string
    policy*: TraceOpenPolicy

proc normalWorkspace*(path: string): string =
  ## The key a workspace is filed under: the path as given, its trailing
  ## separators removed (a root stays a root).
  result = path.strip()
  while result.len > 1 and result[^1] in {'/', '\\'}:
    result.setLen(result.len - 1)

proc parsePolicyWord*(word: string): tuple[ok: bool; policy: TraceOpenPolicy] =
  case word.strip().toLowerAscii()
  of $topNewTab: (true, topNewTab)
  of $topCurrentTab: (true, topCurrentTab)
  else: (false, topNewTab)

proc decodeReplayOpen*(text: string): seq[ReplayOpenEntry] =
  ## The document's lines, in order; a line that is not `<folder>\t<value>`
  ## with a known value is skipped (the default holds for its workspace).
  for raw in text.splitLines():
    let line = raw.strip(leading = false, chars = {'\r', ' '})
    if line.len == 0 or line.startsWith("#"):
      continue
    let tab = line.rfind('\t')
    if tab <= 0:
      continue
    let (ok, policy) = parsePolicyWord(line[tab + 1 .. ^1])
    if not ok:
      continue
    result.add ReplayOpenEntry(workspace: normalWorkspace(line[0 ..< tab]),
                               policy: policy)

proc encodeReplayOpen*(entries: seq[ReplayOpenEntry]): string =
  for e in entries:
    result.add normalWorkspace(e.workspace) & "\t" & $e.policy & "\n"

proc replayOpenFor*(text, workspace: string): TraceOpenPolicy =
  ## The setting for `workspace` in the document `text`: its LAST line for
  ## that workspace, or the default.
  result = topNewTab
  let key = normalWorkspace(workspace)
  if key.len == 0:
    return
  for e in decodeReplayOpen(text):
    if e.workspace == key:
      result = e.policy

proc withReplayOpen*(text, workspace: string;
                     policy: TraceOpenPolicy): string =
  ## The document with `workspace` set to `policy` — its other workspaces
  ## kept, in their order; the default is written too, so a choice made is a
  ## line a reader can see.
  let key = normalWorkspace(workspace)
  var entries: seq[ReplayOpenEntry] = @[]
  for e in decodeReplayOpen(text):
    if e.workspace != key:
      entries.add e
  if key.len > 0:
    entries.add ReplayOpenEntry(workspace: key, policy: policy)
  encodeReplayOpen(entries)

proc replayOpenCommandTarget*(policy: TraceOpenPolicy): string =
  ReplayOpenCommandPrefix & $policy

proc parseReplayOpenCommandTarget*(target: string):
    tuple[ok: bool; policy: TraceOpenPolicy] =
  if not target.startsWith(ReplayOpenCommandPrefix):
    return (false, topNewTab)
  parsePolicyWord(target[ReplayOpenCommandPrefix.len .. ^1])

proc replayOpenCommandLabel*(policy: TraceOpenPolicy): string =
  if policy == topNewTab: OpenRecordingsInNewTabLabel
  else: OpenRecordingsInCurrentTabLabel

proc replayOpenSetNote*(workspace: string; policy: TraceOpenPolicy): string =
  ## What a front-end says once the setting is written.
  (if policy == topNewTab: "test recordings open in a new tab"
   else: "test recordings open in the current tab") &
    (if workspace.len > 0: " in " & normalWorkspace(workspace) else: "")

proc replayOpenNoWorkspaceText*(): string =
  "no project folder is open, so there is no workspace to set " &
    ReplayOpenSettingName & " for"
