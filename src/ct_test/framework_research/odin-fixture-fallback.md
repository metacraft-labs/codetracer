# Odin Fixture Fallback Research

## Detection

- Project marker: `m12-odin.fixture`.
- Source discovery: `.odin`.
- Implemented provider: `odin-fallback`.

## Run Commands

- Fixture package: `odin run <project-root> -debug`.
- Nix fallback package: `odin`.

## Source Discovery And Entry Points

- The containing Odin package is the executable entry point.
- File discovery creates one item per Odin source file, but file run executes the package because Odin compiles package units.

## Recording Feasibility

- Native recording should work for the compiled Odin executable through `ct-mcr`.

## Limitations And Capability Diagnostics

- `canRunSingle=false` and `canRecordSingle=false`.
- No standard test selector protocol is claimed in M12.
- Missing `odin` reports a missing-tool diagnostic.
