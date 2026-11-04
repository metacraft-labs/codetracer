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

## Where stories are declared

Every story is declared once, in Nim:
`src/frontend/stories/codetracer_stories.nim` (sections, export names, the
surface and fixture each story mounts, and an optional named play check).
`just storybook-stories` (run by every StoryBook recipe) writes the CSF files
from it into the git-ignored `stories/generated/`, with `stories.json` listing
every story's id. Do not add a story in a `*.stories.js` file: add it to the
declaration. The same declaration is the user project of CodeTracer's IsoNim
Editor instance (`just isonim-editor-codetracer`, served on port 6106; `--smoke`
checks it), so both review surfaces always show the same stories.

`stories/lib/` holds the harness both surfaces use: `surfaces.js` frames a
story by its kind and calls the Nim mount (the editor loads it into its
preview frame as a plain ES module, so it must not import StoryBook);
`csf.js` makes the CSF story objects; `plays.js` holds the named play checks.

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
