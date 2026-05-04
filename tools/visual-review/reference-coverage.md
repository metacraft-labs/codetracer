# Storybook Reference Coverage

This file tracks Karax reference captures used for IsoNim visual parity work.
Generated screenshots, HTML dumps, and computed-style dumps are intentionally
kept out of this repository; the rows below point to the local reference
worktree artifacts that agents should compare against.

## Reference Sets

- Full default/scratchpad/terminal baseline:
  `/home/zahary/metacraft/codetracer-main/ui-tests/reference-dumps/isonim-karax-reference-20260504T155511Z/`
- Expanded panel baseline:
  `/home/zahary/metacraft/codetracer-main/ui-tests/reference-dumps/isonim-karax-reference-20260504T220906Z/`
- Expanded panel baseline with isolated layout config:
  `/home/zahary/metacraft/codetracer-main/ui-tests/reference-dumps/isonim-karax-reference-20260504T222307Z/`

Some old Karax panels were less developed than current IsoNim surfaces. Use
these references for mature shell, Golden Layout, design-system class, and
spacing contracts. Do not downgrade richer current IsoNim behavior to match an
old empty, blocked, or partial Karax state.

## Coverage Matrix

| Surface | Reference status | Reference capture |
| --- | --- | --- |
| Default layout | captured | `20260504T160311Z_noir-electron-rendered` |
| Scratchpad visible | captured | `20260504T160414Z_noir-scratchpad-visible` |
| Terminal visible | captured | `20260504T160434Z_noir-terminal-visible` |
| Filesystem active | captured | `20260504T220916Z_noir-filesystem-active` |
| State active | captured | `20260504T220918Z_noir-state-active` |
| Calltrace active | captured | `20260504T220919Z_noir-calltrace-active` |
| Calltrace search status | captured | `20260504T220922Z_noir-calltrace-search-status-report` |
| Agent activity active | captured | `20260504T220923Z_noir-agent-activity-active` |
| Menu open | captured | `20260504T220925Z_noir-menu-view-open` |
| Status expanded | captured | `20260504T220927Z_noir-status-expanded` |
| Search results | captured | `20260504T222338Z_noir-search-results-karax-populated`; preserve newer IsoNim functionality if richer |
| Fixed search | captured | `20260504T222336Z_noir-fixed-search-karax-visible` |
| Point list | blocked | `20260504T220950Z_noir-point-list-open`; Karax raised unexpected `PointList` content |
| Step list | captured | `20260504T220952Z_noir-step-list-open` |
| Timeline | blocked | `20260504T222349Z_noir-timeline-blocked-no-factory`; Karax lacked a usable component factory |
| Trace log | captured | `20260504T222329Z_noir-trace-log-karax-open` |
| Build | captured | `20260504T222317Z_noir-build-karax-open`; preserve newer IsoNim output behavior if richer |
| Build errors | partial | `20260504T222538Z_noir-build-errors-karax-open-attached` and `20260504T222734Z_noir-build-errors-karax-direct-id0`; Karax content stayed empty |
| Shell | captured | `20260504T221002Z_noir-shell-open` |
| REPL | captured | `20260504T222331Z_noir-repl-karax-open` |
| Low-level code | captured | `20260504T222333Z_noir-low-level-code-karax-open` |
| No source | captured | `20260504T222334Z_noir-no-source-karax-open` |
| Command palette | captured | `20260504T222339Z_noir-command-palette-karax-open` |
| Debug controls/header | captured | `20260504T222314Z_noir-debug-controls-header` |
| Agent workspace | captured | `20260504T222341Z_noir-agent-workspace-karax-open`; preserve newer IsoNim behavior if richer |
| Agent activity deep review | captured | `20260504T222342Z_noir-agent-activity-deepreview-karax-open`; preserve newer IsoNim behavior if richer |
| Deep review panel | partial | `20260504T222344Z_noir-deepreview-panel-karax-open-empty` and `20260504T222427Z_deepreview-standalone-karax-sample`; old Karax state was underdeveloped |
| Flow | partial | `20260504T222348Z_noir-flow-select-attempt`; old frontend raised missing `ct/load-flow` response-kind handling |
| VCS | missing | No old panel implementation found |
| Request panel | missing | No old panel implementation found |
| Welcome screen | captured | `20260504T221201Z_welcome-screen` |

## Current Workflow

1. Capture current Storybook for a matching story with
   `tools/visual-review/capture-storybook.mjs --view <slug> --size laptop`.
2. Compare HTML and computed-style dumps against the reference capture with the
   same surface name.
3. Compare screenshots with `tools/visual-review/compare-screenshots.sh` when
   the reference capture is marked `captured`.
4. Patch the real IsoNim view/style/story shell, not a parallel mock.
5. Update this matrix when new reference captures become available.
