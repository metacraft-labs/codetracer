# Justfile-Oriented Build Driver Proof of Concept

This proof of concept demonstrates how the build, test, and packaging workflows
can be centralized around a hierarchy of [`just`](https://just.systems) files.
The goal is to use `just` as the single entry point that orchestrates the
existing tools (Tup, Webpack, Cargo, MdBook, etc.) without requiring developers
to memorize bespoke scripts.

## Layout

```
just/
  poc.just         # high-level driver invoked via `just poc <recipe>`
```

The root `justfile` exposes the proof of concept through a `poc` recipe. Any
existing workflows continue to function, but developers can try the centralized
approach by running, for example:

```shell
just poc build:all
```

## Key Recipes

The proof-of-concept driver groups related commands under namespaces:

- `workspace:*` recipes verify preconditions (tools installed, directories
  created).
- `build:*` recipes build each component (Tup application, frontend bundle,
  Rust backend, MdBook documentation) and aggregate into `build:all`.
- `build:appimage` prepares the bespoke AppDir and emits `CodeTracer.AppImage`
  using the existing shell scripts while checking required tooling.
- `build:mac-app` and `build:dmg` wrap the non-Nix macOS packaging scripts to
  create the `.app` bundle and `.dmg` image from the same centralized entry
  point.
- `dev:watch` coordinates Tup and Webpack watchers to mirror the current
  development workflow in a single command.
- `test:*`, `lint:rust`, and `format:rust` wrap existing verification steps so
  they can be invoked consistently from `just`.
- `ci:full` demonstrates how to encode CI pipelines as recipe dependencies to
  guarantee ordering.

See [`just/poc.just`](../just/poc.just) for the complete list of recipes and
implementation details.

## Extending the Driver

- Additional component-specific recipes can be captured in dedicated files and
  imported once we adopt the modular Justfile include feature.
- Scripts currently living in `non-nix-build/`, `appimage-scripts/`, or
  language-specific package managers can be wrapped in new namespaces to unify
  packaging workflows.
- CI systems can execute `just poc ci:full` to drive the same commands that
  developers run locally, ensuring parity.

## Next Steps

1. Validate the required `just` version across developer machines to ensure
   namespace recipes and shell configuration work consistently.
2. Split the proof-of-concept into composable Justfiles per component
   (e.g. `just/frontend.just`) and import them from the root driver so ownership
   can be delegated to the relevant teams.
3. Deprecate redundant shell scripts once their logic has been captured in a
   Justfile recipe with tests and documentation.
4. Integrate the `poc` entry point into CI and release automation after gaining
   confidence in the workflow.
