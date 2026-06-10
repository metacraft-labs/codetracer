# Assembly Executable Fallback Research

## Detection

- Project marker: `m12-assembly.fixture`.
- Source discovery: `.s`, `.S`, and `.asm`.
- Implemented provider: `assembly-fallback`.

## Run Commands

- File fixture: `gcc -g -no-pie -x assembler-with-cpp -o <tmp-exe> <file> && <tmp-exe>`.
- Nix fallback package: `gcc`.

## Source Discovery And Entry Points

- M12 treats one assembly source file as one executable entry point.

## Recording Feasibility

- Native recording through `ct-mcr` is feasible after building the executable with debug info.

## Limitations And Capability Diagnostics

- `canRunSingle=false` and `canRecordSingle=false`.
- There is no framework-level selector support.
- Missing `gcc` reports a missing-tool diagnostic.
