# DeepReview Visual Review Brief

## What You're Reviewing

The DeepReview GUI in CodeTracer — a code review workspace that augments diffs with execution-time data (variable values, coverage). It has two modes: a unified diff view (PR-style hunks) and a full files view (normal editor with diff highlights).

## Design Goals

- **Match CodeTracer's existing dark theme exactly**: background #1e1e1e, panels #252526, borders #3c3c3c, text #cccccc
- **Professional, IDE-quality appearance**: like VS Code's diff view or GitHub's PR diff, not a prototype
- **Information density without clutter**: file list, diff hunks, inline values, coverage badges should be readable at a glance
- **Consistent with the main CodeTracer editor** — the same fonts, spacing, border-radius, icon style

## Reference Tools

- VS Code's built-in diff editor
- GitHub PR diff view
- JetBrains IDE diff viewer

## What to Evaluate

1. **Overall layout**: Is the file list / diff area proportioned well? Does it look balanced?
2. **File list panel**: Are items readable? Is the diff status (A/M/D) badge clear? Are line counts visible?
3. **Unified diff hunks**: Are added/removed lines clearly distinguishable? Are file headers prominent enough?
4. **Inline values (Omniscience)**: Are they readable but unobtrusive? Do they blend with the code?
5. **Mode switcher and header**: Is the header compact? Are controls accessible?
6. **Expand buttons**: Are they visible but subtle?
7. **Color harmony**: Do the green/red/yellow diff colors work with the dark theme?
8. **Typography**: Is the code font consistent? Are sizes appropriate?
9. **Spacing**: Is there enough padding? Are elements aligned?
10. **Professional polish**: Would this pass a design review at a product company?

## How to Report

- Keep under 200 words
- Lead with overall impression and a rating (1-10)
- List the top 3-5 specific issues with exact locations (e.g., "file list items need 4px more vertical padding")
- End with priority fixes (what would have the biggest visual impact)
- Rating calibration: 4-5 = functional but rough, 6-7 = good with minor issues, 8-9 = near-shipping
