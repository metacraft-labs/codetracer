## viewmodels/evidence_call_vm.nim
##
## AA-3's recogniser of the agent's evidence handoff now lives in
## `nim_agents/evidence_call` (CTF-M1: the signal-free logic of the agent
## viewmodels moved into nim-agents). This module keeps the old import path.

import nim_agents/evidence_call
export evidence_call
