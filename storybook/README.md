# CodeTracer Storybook

Storybook harness for isolated CodeTracer IsoNim panels.

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
