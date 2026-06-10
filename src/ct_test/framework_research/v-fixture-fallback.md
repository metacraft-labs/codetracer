# V Fixture Fallback Research

## Detection

- Project marker: `m12-v.fixture`.
- Source discovery: `.v`.
- Implemented provider: `v-fallback`.

## Run Commands

- File fixture: `v run <file>`.
- Nix fallback package: `vlang`.

## Source Discovery And Entry Points

- M12 treats one V source file as a runnable fixture entry point.

## Recording Feasibility

- Native recording wraps `v run <file>`. This records the compiler/runner process and the launched executable path as observed by `ct-mcr`.

## Limitations And Capability Diagnostics

- `canRunSingle=false` and `canRecordSingle=false`.
- Framework-native single test support is not advertised.
- Missing `v` reports a missing-tool diagnostic.
