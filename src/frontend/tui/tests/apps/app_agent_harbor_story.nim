## tests/apps/app_agent_harbor_story.nim — CTF-P1b. The terminal story host
## (`tui/agent_harbor/ah_tui_story_host.nim`) as a child app: the Tier-2
## suites build every child from `tests/apps/<stem>.nim`
## (`testing/dual_snap.compileChildApp`), so this file is that module,
## included whole. `test_ctf_p1b_tui_views_cover_web_states.nim` spawns it.

include ../../agent_harbor/ah_tui_story_host
