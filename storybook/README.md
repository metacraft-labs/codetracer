# CodeTracer Storybook

Storybook harness for isolated CodeTracer IsoNim panels, shell views,
building-block components, and default layouts.

## Commands

```bash
just build-storybook-components
just storybook
just storybook-build
```

The Nim bundle exports Storybook mount functions from
`src/frontend/storybook_components.nim` into `storybook/dist/components.js`.
Stories load that bundle and mount real ViewModels through the production
IsoNim views.

Fixtures may mock ViewModel/store state, but stories must not reimplement
component DOM in JavaScript. The DOM under test should come from the real
`src/frontend/viewmodel/views/*.nim` render or mount functions.

## Visual Review

The repeatable screenshot loop lives in `tools/visual-review/`:

```bash
nix shell nixpkgs#nodejs --command node tools/visual-review/capture-storybook.mjs
nix shell nixpkgs#nodejs --command node tools/visual-review/capture-storybook.mjs --view terminal-output --size laptop --no-build
```

The capture tool builds Storybook, serves `storybook/storybook-static`, captures
named stories at the configured viewport sizes, and writes diagnostics beside
the screenshots. The generated `reports/` and `screenshots/` directories are
ignored; keep the project brief, screen briefs, and capture script in git.
