# CodeTracer Storybook

Storybook harness for isolated CodeTracer IsoNim panels, shell views,
building-block components, and default layouts.

## Commands

```bash
just build-storybook-components
just storybook-check-styles
just storybook
just storybook-build
```

The Nim bundle exports Storybook mount functions from
`src/frontend/storybook_components.nim` into `storybook/dist/components.js`.
Stories load that bundle and mount real ViewModels through the production
IsoNim views.

Storybook loads CodeTracer styles by parsing the production
`src/frontend/index.html`; do not copy app stylesheet lists or component visual
CSS into stories. Keep Storybook CSS limited to harness sizing/layout.

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
the screenshots. It also writes HTML and computed-style dumps that can be
compared against reference dumps from older known-good builds:

```bash
nix shell nixpkgs#nodejs --command node tools/visual-review/compare-style-dumps.mjs \
  --reference ../codetracer-main/ui-tests/reference-dumps/isonim-karax-reference-20260504T155511Z/20260504T160434Z_noir-terminal-visible.computed-styles.json \
  --current tools/visual-review/dumps/terminal-output-laptop.computed-styles.json \
  --out tools/visual-review/reports/terminal-vs-karax-reference.md
```

The generated `reports/`, `screenshots/`, and `dumps/` directories are ignored;
keep the project brief, screen briefs, and capture/comparison scripts in git.
