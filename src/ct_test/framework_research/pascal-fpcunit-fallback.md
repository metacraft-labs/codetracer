# Pascal FPCUnit / FPC Fallback Research

## Detection

- Project marker: `m12-pascal.fixture`.
- Source discovery: `.pas` and `.pp` files.
- Implemented provider: `pascal-fallback`.

## Run Commands

- File fixture: `fpc -g -Fu<project> -o<tmp-exe> <file> && <tmp-exe>`.
- Nix fallback package: `fpc`.

## Source Discovery And Entry Points

- M12 creates one file-level `TestItem` per Pascal source file.
- Location is reported as fallback provenance at line 1 because executable fallback cannot identify FPCUnit cases.

## Recording Feasibility

- File-level recording wraps the compile-and-run command with `ct-mcr record --use-interpose`.
- Real traces are feasible when FPC and `ct-mcr` are available.

## Limitations And Capability Diagnostics

- `canRunSingle=false` and `canRecordSingle=false`.
- FPCUnit selectors are not advertised because M12 does not implement reliable suite/case listing or single-case filtering.
- Missing FPC reports a toolchain diagnostic instead of exposing fake support.
