# Storybook Reference Coverage

<!-- cspell:ignore Karax karax worktree zahary isonim viewmodel -->
<!-- cspell:ignore deepreview capturable -->

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

## Current Storybook Audit

Last audited: 2026-05-05 on `codetracer-viewmodel`.

Current Storybook views are discovered with:

```sh
nix shell nixpkgs#nodejs --command node tools/visual-review/capture-storybook.mjs --list-views --no-build
```

The generated list includes all real IsoNim panel stories exported through
`mountCodeTracerStory`, plus structure stories for session tabs, menu/status
shells, debug shell, auto-hide controls, and default/app-shell layouts. The
capture tool also exposes source-slug aliases for `deepreview` and
`agent-activity-deepreview`, in addition to Storybook's display-name slugs
`deep-review` and `agent-activity-deep-review`; `status` aliases the
`status-shell` component story.

Representative partial/missing-reference surfaces were captured successfully at
`laptop` size on 2026-05-05:

| Surface | Current Storybook view | Current status |
| --- | --- | --- |
| Point list | `point-list` | confirmed current IsoNim panel, `tools/visual-review/reports/point-list-laptop.json` |
| Timeline | `timeline` | confirmed current IsoNim panel, `tools/visual-review/reports/timeline-laptop.json` |
| Flow | `flow` | confirmed current IsoNim panel with populated steps, `tools/visual-review/reports/flow-laptop.json` |
| VCS | `vcs` | confirmed current IsoNim panel, `tools/visual-review/reports/vcs-laptop.json` |
| Request panel | `request-panel` | confirmed current IsoNim panel, `tools/visual-review/reports/request-panel-laptop.json` |
| Deep review panel | `deepreview` | confirmed current IsoNim panel, `tools/visual-review/reports/deepreview-laptop.json` |
| Agent activity deep review | `agent-activity-deepreview` | confirmed current IsoNim panel, `tools/visual-review/reports/agent-activity-deepreview-laptop.json` |
| Auto-hide bottom tabs | `auto-hide-bottom-tabs` | confirmed current IsoNim component, `tools/visual-review/reports/auto-hide-bottom-tabs-laptop.json` |
| Auto-hide collapsed icons | `auto-hide-collapsed-icons` | confirmed current IsoNim component, `tools/visual-review/reports/auto-hide-collapsed-icons-laptop.json` |
| Auto-hide overlay tabs | `auto-hide-overlay-tabs` | confirmed current IsoNim component, `tools/visual-review/reports/auto-hide-overlay-tabs-laptop.json` |
| Auto-hide side strip | `auto-hide-side-strip` and `auto-hide-side-strip-collapsed` | confirmed populated and collapsed current IsoNim variants |
| Session tabs | `session-tabs` | confirmed current IsoNim component, `tools/visual-review/reports/session-tabs-laptop.json` |
| Default layout variants | `default-layout`, `standalone-app-shell`, `noir-filesystem-active`, `noir-state-active`, `noir-calltrace-active`, `noir-calltrace-search-status-report`, `noir-menu-view-open`, `noir-status-expanded` | confirmed current layout stories; use a non-default `--port` if another static server is already bound to `6106` |

Current confirmation does not change the old reference status below. Rows marked
`blocked`, `partial`, or `missing` still mean the old Karax reference capture is
blocked, partial, or absent; the current IsoNim story can still be valid and
capturable.

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
   Use repeated `--view` flags or `--views a,b,c` for batch captures. If the
   default port is occupied, pass `--port <free-port>`.
2. Compare HTML and computed-style dumps against the reference capture with the
   same surface name.
3. Compare screenshots with `tools/visual-review/compare-screenshots.sh` when
   the reference capture is marked `captured`.
4. Patch the real IsoNim view/style/story shell, not a parallel mock.
5. Update this matrix when new reference captures become available.
