# Ada AUnit / gnatmake Fallback Research

## Detection

- Project marker: `m12-ada.fixture`.
- Source discovery: `.adb` and `.ads`.
- Implemented provider: `ada-fallback`.

## Run Commands

- File fixture: `gnatmake -g -o <tmp-exe> <file> && <tmp-exe>`.
- Nix fallback package: `gnat`.

## Source Discovery And Entry Points

- M12 uses Ada body files as executable fixture entry points.
- AUnit suite/case ranges are not parsed; the file item is a fallback location.

## Recording Feasibility

- File-level native recording is feasible when GNAT and `ct-mcr` are available.

## Limitations And Capability Diagnostics

- `canRunSingle=false` and `canRecordSingle=false`.
- AUnit test selectors are hidden until a reliable AUnit discovery/listing adapter exists.
- Missing `gnatmake` reports a missing-tool diagnostic.
