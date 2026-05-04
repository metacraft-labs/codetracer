# CodeTracer Storybook Visual Brief

CodeTracer is a debugging and replay UI for inspecting recorded program
execution. The Storybook surfaces must render the production IsoNim DOM with
the same CSS and shell context as the Electron app, so isolated panel review can
catch visual regressions before full GUI tests.

The important rule is that Storybook may mock ViewModel data, but it must not
mock or reimplement component DOM. Storybook stories should call the real
IsoNim ViewModel constructors and `src/frontend/viewmodel/views/*.nim` render
or mount functions.

## Shared Design Goals

- Match the dark CodeTracer Electron UI from `src/frontend/index.html`.
- Use the app CSS from `frontend/styles/default_dark_theme_electron.css`.
- Preserve the app shell context: `#root-container`, `#auto-hide-layout-row`,
  `#ROOT`, `.session-container`, and `#main`.
- Panels should look like CodeTracer work surfaces, not generic Storybook
  cards.
- Text should be legible, clipped content should be intentional, and images or
  icons should not be broken.

## What Must Not Happen

- Missing app CSS links in the Storybook iframe.
- Bare unstyled HTML controls.
- Storybook-local colors/fonts overriding CodeTracer CSS.
- DOM mounted outside the app shell when the production selector depends on
  app-shell ancestors.
- Broken asset URLs under `/public/resources` or `/public/third_party`.
