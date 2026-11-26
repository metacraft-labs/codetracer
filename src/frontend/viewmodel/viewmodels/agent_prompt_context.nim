## viewmodels/agent_prompt_context.nim
##
## The prompt's "add context" attachments now live in `nim_agents/prompt_context`
## (CTF-M1: the signal-free logic of the agent viewmodels moved into
## nim-agents). This module keeps the old import path for CodeTracer's
## modules, the Electron main process and both native front-ends.

import nim_agents/prompt_context
export prompt_context
