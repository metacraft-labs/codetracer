# Desktop stylesheets: what is live

Status: Current · Last checked 2026-11-19 against `src/frontend/styles/Tupfile`
and `loadTheme` in `src/frontend/renderer.nim`.

Before styling anything, read the root `AGENTS.md` section "Styling with the
design system" and `docs/UI-Design-Decisions.md`.

## Themes

`loadTheme` loads `frontend/styles/{name}_theme_electron.css`. Only themes that
the `Tupfile` builds can load.

| File | State | Notes |
|---|---|---|
| `default_dark_theme.styl` | **live** | Dark theme values; imported by the two below |
| `default_dark_theme_electron.styl` | **live** | The desktop dark theme (built to CSS) |
| `default_dark_theme_extension.styl` | **live** | Extension / web build of the dark theme |
| `default_white_theme.styl` | **live** | Light theme values (`COLOR_MODE = "Light"`) |
| `default_white_theme_electron.styl` | **live** | The desktop light theme (built to CSS) |
| `default_black_theme.styl` | legacy | Listed in `themeProgramNames` (renderer.nim) but never built: choosing it loads a missing file. Don't copy from it. |
| `default_light_theme.styl` | legacy | Not built, not the light theme. The light theme is `default_white`. Don't copy from it. |
| `mac_classic_theme.styl` | legacy | Listed in `themeProgramNames` but never built. Don't copy from it. |

## Shared files

| File | What it is |
|---|---|
| `codetracer.styl` | Imports every component stylesheet; each `*_electron` theme imports it |
| `defaults.styl` | Old shared constants (some raw colours); prefer tokens |
| `generated/` | **Generated** from the design system by `scripts/tokens-to-styl.sh`. Never edit; `ci/test/design-tokens-fresh.sh` fails if stale |
| `components/button.styl` | Imported first: control sizes and the shared looks (`control-button*()`, `key-focus()`, `button-icon()`, `mask-icon()`, `tooltip-look()`) |
| `components/shared_widgets.styl` | Dropdown surface and rows, segmented tabs, tab icons, the key-focus catch-all |
| `components/checkmark.styl` | The design-system checkbox `.ct-checkmark` |
| `components/legacy.styl` | Old CSS of unknown use, still imported. Don't add to it or copy from it |
| `subwindow.styl`, `loader.styl` | The installer/sub-window and the loading spinner, built separately |
| `contrast_floors.nim` | Minimum contrast numbers the terminal and GPUI front-ends' chrome is graded against |

## Rules the checks enforce

`python3 ci/test/ui-design-decisions.py` fails when:

- a recorded design decision's code is gone;
- any stylesheet sizes something in px (write rem or em, root 16px);
- a component uses an icon variable missing from a theme;
- a component stylesheet gains a raw colour (hex, `rgb()`, `hsl()`). Today's
  counts are in `ci/test/raw-colour-baseline.json`: lower a count when you
  replace colours with tokens, never raise it.

Component pages (what a button, checkbox, dropdown, tooltip or panel must look
like): `libs/codetracer-design-system/docs/components/`.
