# Crystal spec research notes (M11)

## Detection

- Project: `shard.yml` or `spec/`.
- File: `*_spec.cr`.
- Source discovery: parse `describe`, `context`, and `it` calls with literal
  string names.

## Commands

- Project: `crystal spec --no-color`.
- File: `crystal spec --no-color <relative-file>`.
- Single spec: `crystal spec --no-color <relative-file>:<line>`.

## Discovery and locations

Crystal spec supports line selectors. M11 source parsing records suites and
examples with selectors matching the framework's `file:line` addressing.

## Results and output

M11 captures process-level output and pass/fail status. Crystal's formatter
output can be parsed later for per-example status if the provider needs richer
event streams.

## Recording

File-level recording builds a debug spec runner for the requested spec file and
records that runner through the native recorder. Single-example recording is
not advertised because line selectors are interpreted by the framework process
and the compiled spec executable path is transient.

## Limitations

- Dynamic spec names are not discovered.
- Single-example run is supported through line selectors; single-example record
  returns a precise unsupported diagnostic.
