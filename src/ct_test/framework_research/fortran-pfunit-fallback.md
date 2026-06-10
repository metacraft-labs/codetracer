# Fortran pFUnit / gfortran Fallback Research

## Detection

- Project marker: `m12-fortran.fixture`.
- Source discovery: `.f90`, `.f95`, `.f03`, `.f08`, `.for`, and `.f`.
- Implemented provider: `fortran-fallback`.

## Run Commands

- File fixture: `gfortran -g -O0 -o <tmp-exe> <file> && <tmp-exe>`.
- Nix fallback package: `gfortran`.

## Source Discovery And Entry Points

- M12 treats each source file as one executable fixture entry point.
- Locations use fallback provenance because pFUnit metadata is not queried.

## Recording Feasibility

- Native executable traces are feasible through `ct-mcr` after compiling with debug info.

## Limitations And Capability Diagnostics

- `canRunSingle=false` and `canRecordSingle=false`.
- pFUnit support is intentionally not claimed without a project-aware pFUnit adapter and stable selector mapping.
- Missing `gfortran` produces an explicit missing-tool diagnostic.
