## What a worktree agent session started from the desktop asks Agent Harbor
## for (codetracer-pm DeepReview/Agentic-Coding-Integration.md §6.8): the
## repository the task runs on and the task itself.

import std/strutils

proc harborTaskWorkspace*(launcherUserWorkspace, startFolder,
                          workspaceFolder: string): string =
  ## The user's working copy a new session runs on. Once a session showed an
  ## agent's worktree, the project folder (`startFolder`) names that worktree,
  ## so the launcher's record of the user's own folder comes first; the main
  ## process's `workspaceFolder` is the last resort, since the renderer is not
  ## sent it. Without the trailing '/' the folder names the repository, and
  ## its last component is the project.
  for candidate in [launcherUserWorkspace, startFolder, workspaceFolder]:
    let folder = candidate.strip(leading = false, chars = {'/'})
    if folder.len > 0:
      return folder
  ""

proc taskFromAgentPrompt*(prompt: string): string =
  ## The task in a prompt typed in the omnibox, which keeps its `/ai` query
  ## prefix in the text (§8.1), or in the Agent Activity prompt box.
  result = prompt.strip
  if result == "/ai":
    return ""
  if result.startsWith("/ai ") or result.startsWith("/ai\t"):
    result = result[4 .. ^1].strip
