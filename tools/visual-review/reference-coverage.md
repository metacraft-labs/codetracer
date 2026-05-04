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
| Search results | captured | `20260504T220948Z_noir-search-results-shield` |
| Fixed search | blocked | `20260504T220948Z_noir-fixed-search-blocked`; input existed but was hidden |
| Point list | blocked | `20260504T220950Z_noir-point-list-open`; Karax raised unexpected `PointList` content |
| Step list | captured | `20260504T220952Z_noir-step-list-open` |
| Timeline | blocked | `20260504T220954Z_noir-timeline-open`; layout tab API unavailable |
| Trace log | blocked | `20260504T220956Z_noir-trace-log-open`; layout tab API unavailable |
| Build | blocked | `20260504T220958Z_noir-build-open`; layout tab API unavailable |
| Build errors | blocked | `20260504T221000Z_noir-build-errors-open`; layout tab API unavailable |
| Shell | captured | `20260504T221002Z_noir-shell-open` |
| Agent workspace | blocked | `20260504T221004Z_noir-agent-workspace-open`; layout tab API unavailable |
| Agent activity deep review | blocked | `20260504T221006Z_noir-agent-activity-deepreview-open`; layout tab API unavailable |
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
