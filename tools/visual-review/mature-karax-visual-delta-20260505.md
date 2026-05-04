# Mature Karax Visual Delta Report - 2026-05-05

<!-- cspell:ignore Karax viewmodel capturable RMSE -->

Branch: `codetracer-viewmodel`

## Method

- Storybook was rebuilt with
  `nix shell nixpkgs#nodejs --command bash -lc 'just storybook-build'`.
- Current Storybook stories were captured with
  `tools/visual-review/capture-storybook.mjs`.
- `wide` (`1920x1080`) was used for Karax references captured at `1920x1080`.
- `laptop` (`1440x900`) was used for the older full-page Karax references
  captured as `2161x3766`; those metrics are useful for trend tracking but are
  dominated by viewport/full-page framing.
- Screenshot metrics were generated with `tools/visual-review/compare-screenshots.sh`,
  which resizes the reference image to the current capture before computing RMSE/MAE.
- Generated captures, dumps, and diff images remain ignored under
  `tools/visual-review/{screenshots,reports,compare,dumps}`.

## Summary

The mature Karax states now have matching capturable Storybook stories. The
closest comparisons are the `1920x1080` default Noir layout variants: their
largest remaining deltas are mostly intentional richer IsoNim content, not empty
or broken rendering. The older full-page references and panel-only current
stories are documented separately because their RMSE/MAE numbers are dominated
by app-frame and viewport mismatch.

No small shell/chrome/CSS fix was applied in this pass; the visible differences
that remain would require either new full-layout stories for panel-only states or
deliberate content downgrades, which this audit avoided.

## Per-Surface Results

| Surface | Current story | Viewport | RMSE | MAE | Status |
| --- | --- | --- | ---: | ---: | --- |
| Default layout | `default-layout` | laptop | 0.148885 | 0.056060 | Framing-dominated; current shell is populated and richer. |
| Terminal | `terminal-output` | laptop | 0.098892 | 0.028241 | Panel story vs full-layout Karax terminal state; metric is directional only. |
| Scratchpad | `scratchpad` | laptop | 0.098082 | 0.029454 | Panel story vs full-layout Karax scratchpad state; metric is directional only. |
| Filesystem active | `noir-filesystem-active` | wide | 0.100905 | 0.025215 | Good app-frame match; richer editor/calltrace/event rows dominate. |
| State active | `noir-state-active` | wide | 0.100905 | 0.025215 | Same base Karax/current pixels as filesystem active; focus change is not visibly distinct. |
| Calltrace active | `noir-calltrace-active` | wide | 0.100905 | 0.025215 | Same base Karax/current pixels as filesystem active; richer calltrace text dominates. |
| Calltrace search/status | `noir-calltrace-search-status-report` | wide | 0.106128 | 0.026938 | Good app-frame match; current calltrace/search content is denser. |
| Menu open | `noir-menu-view-open` | wide | 0.074298 | 0.018578 | Good app-frame match; menu/status shell differences are localized. |
| Status expanded | `noir-status-expanded` | wide | 0.072659 | 0.018013 | Best layout match in this batch; status and agent panel richness remain. |
| Fixed search | `noir-fixed-search-visible` | laptop | 0.168908 | 0.057116 | Full-page reference mismatch; current search shell is richer. |
| Search results | `noir-search-results-populated` | laptop | 0.170998 | 0.060999 | Full-page reference mismatch plus richer current search result content. |
| Command palette | `noir-command-palette-open` | laptop | 0.094881 | 0.058993 | Full-page reference mismatch; overlay shape/content comparable. |
| Build | `noir-build-open` | laptop | 0.134460 | 0.048930 | Full-page reference mismatch; current build output behavior is richer. |
| Trace log | `noir-trace-log-open` | laptop | 0.123995 | 0.041831 | Full-page reference mismatch; table density/content differs intentionally. |
| Debug controls/header | `noir-debug-controls-header` | laptop | 0.148460 | 0.055652 | Full-page reference mismatch; header chrome is comparable. |
| Shell | `shell` | wide | 0.079896 | 0.037638 | Panel story vs full-layout Karax shell state; metric is not a parity signal. |
| REPL | `repl` | laptop | 0.073845 | 0.032278 | Panel story vs full-layout Karax REPL state; metric is directional only. |
| Low-level code | `low-level-code` | laptop | 0.073199 | 0.030190 | Panel story vs full-layout Karax low-level state; metric is directional only. |
| No source | `no-source` | laptop | 0.092624 | 0.020209 | Panel story vs full-layout Karax no-source state; metric is directional only. |
| Welcome | `welcome` | wide | 0.067437 | 0.011610 | Good standalone match; remaining delta is mostly typography/spacing. |
| Step list | `step-list` | wide | 0.088317 | 0.037435 | Panel story vs full-layout Karax step-list state; metric is directional only. |

## Top Remaining Deltas

1. Several Karax references are full-page `2161x3766` captures while current
   Storybook is viewport-framed. These need either custom-size capture support or
   new reference captures before RMSE/MAE can be treated as parity gates.
2. Shell, REPL, low-level, no-source, and step-list currently compare panel
   stories against full-layout Karax states. Full-layout Storybook variants would
   make these measurable in the same way as the Noir default variants.
3. The current IsoNim default layout intentionally shows richer editor syntax,
   calltrace rows, terminal/event-log rows, and populated panel behavior. These
   content differences should not be patched back to the older Karax state.
4. The remaining meaningful layout deltas are small chrome differences in tabs,
   status/menu treatment, scroll positions, and text wrapping rather than missing
   surfaces.
