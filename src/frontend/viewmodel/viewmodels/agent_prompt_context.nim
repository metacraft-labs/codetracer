## viewmodels/agent_prompt_context.nim
##
## **What the Agent Activity prompt's "add context" items attach, and how the
## attachments reach the agent** — one answer for the desktop's main process
## and the native hosts.
##
## The desktop's prompt has a `+` beside it that drops down four items
## (`views/isonim_agent_activity_view.renderAddFilesButton`): *Upload
## attachment*, *Files & folders*, *Editor selection* and *Recording /
## trace*. Each adds a path to `AgentActivityVM.contextPaths`, the prompt
## shows the paths as chips, and when the prompt is sent the paths go with it
## as a header the agent reads in-band (`index/ipc_subsystems/acp_ipc`'s
## `onAcpPrompt`). The terminal and the GPUI window send their prompts
## themselves (`viewmodel/host/native_agent_host`), so the header and the
## editor selection's spelling live here, where all three read them.
##
## Pure, no imports beyond `std/strutils`: the Electron main process compiles
## it as well as both front-end backends.

import std/strutils

type
  AgentAddContextItem* = enum
    ## The `+` menu's items, in the desktop's order.
    aciUpload = "Upload attachment"
    aciFilesFolders = "Files & folders"
    aciEditorSelection = "Editor selection"
    aciRecording = "Recording / trace"

const
  AgentContextPathsHeading* = "Context paths:"
    ## The first line of the header a prompt with attachments carries.
  AgentNoEditorSelectionReason* = "no file is open in the editor"
    ## Why *Editor selection* is disabled on a front-end with no file
    ## shown in its editor.

func label*(item: AgentAddContextItem): string = $item

func contextPromptText*(text: string; paths: openArray[string]): string =
  ## The prompt the agent receives: `text` after a header naming each
  ## attached path, or `text` alone when nothing is attached —
  ##
  ##     Context paths:
  ##     - src/parser.nim
  ##     - src/parser.nim:12-18
  ##
  ##     <text>
  if paths.len == 0:
    return text
  result = AgentContextPathsHeading & "\n"
  for p in paths:
    result.add "- " & p & "\n"
  result.add "\n"
  result.add text

func editorSelectionContext*(path: string; first, last: int): string =
  ## What *Editor selection* attaches: the editor's file and the
  ## lines its selection covers (1-based, inclusive), `path:first-last` — or
  ## `path:line` for a selection on one line (the caret's line when nothing is
  ## selected). "" when no file is shown.
  if path.len == 0:
    return ""
  let a = max(1, min(first, last))
  let b = max(1, max(first, last))
  if a == b: path & ":" & $a
  else: path & ":" & $a & "-" & $b

func withContextPath*(paths: openArray[string]; path: string): seq[string] =
  ## `paths` with `path` attached: appended once (a path already attached is
  ## not attached twice), blanks ignored.
  result = @paths
  let p = path.strip()
  if p.len > 0 and p notin result:
    result.add p
