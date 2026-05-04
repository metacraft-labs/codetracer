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
