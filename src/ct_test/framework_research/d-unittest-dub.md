# D unittest / dub research notes (M11)

## Detection

- Project: `dub.json`, `dub.sdl`, or conventional `source/` / `test/`
  directories.
- File: `.d`.
- Source discovery: lightweight parser for `unittest` blocks.

## Commands

- Dub project: `dub test`.
- File: `ldc2 -unittest -main -run <relative-file.d>`.
- Single test: unsupported for built-in `unittest` blocks because the language
  feature does not assign stable framework names to individual blocks.

## Discovery and locations

`unittest` blocks are source constructs, not named framework items. M11 uses
source parsing and selectors of the form `<relative-file>:<line>`.

## Results and output

D compilers and Dub report process-level success/failure. M11 captures command
output and maps the file/project command result to normalized test events.

## Recording

File-level recording is attempted through the native recorder by wrapping the
same `ldc2 -unittest -main -run` command. If `ct-mcr`/`ct_cli` is unavailable,
the provider returns an explicit recorder diagnostic.

## Limitations

- Single `unittest` block run/record is unsupported without a custom named
  runner.
- Per-block status/output is unavailable from the built-in runner.
