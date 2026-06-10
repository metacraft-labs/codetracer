# Julia Test Fallback Research

## Detection

- Project markers: `m12-julia.fixture` or `Project.toml`.
- Source discovery: `.jl`.
- Implemented provider: `julia-fallback`.

## Run Commands

- File fixture: `julia --project=<project-root> <file>`.
- Nix fallback package: `julia`.

## Source Discovery And Entry Points

- M12 treats a Julia test file, typically `test/runtests.jl`, as the fixture entry point.

## Recording Feasibility

- Native recording is not advertised in M12.
- Local validation on Linux with `nixpkgs#julia` ran the fixture successfully,
  but `ct-mcr record --use-interpose` exited 1 during Julia startup with
  `Error during libstdcxxprobe: fork: Success`.
- The provider should keep run support and a clear unsupported-recording
  diagnostic until Julia recording produces a successful non-empty trace.

## Limitations And Capability Diagnostics

- `canRunSingle=false` and `canRecordSingle=false`.
- Julia `Test` does not provide a stable built-in machine-readable single-test selector for this provider.
- `canRecordFile=false`; file recording returns an unsupported-recording diagnostic.
- Missing `julia` reports a missing-tool diagnostic for run actions.
