# Main config
## The `default_config.yaml` file
The `default_config.yaml` contains most configuration options for codetracer in YAML format.

Codetracer stores this file in 2 different places:

1. In `config` during development, or `/etc/codetracer/` when installed globally
1. In `<your project>/.codetracer/` for per-project configuration

Note that some fields cannot be per-project. Such fields are marked on this page.

### Codetracer mode
By enabling the `test` field, you can enable test mode. It was previously used
for Nim UI tests, however it should be obsolete by now and should be removed soon.

<!-- TODO: remove the `test` field when ready-->

### Features
You have the ability to enable/disable different features of codetracer to make your debugging environment more customisable.
Here's a list:

1. `calltrace`
1. `flow`
1. `trace`
1. `events`
1. `history` - Experimental
1. `repl`

Each of these settings is a dictionary, that looks like this:
```yaml
flow:
  enabled: true
  ui: parallel
```
Most features only have the `enabled` field, though some might have additional settings, like flow.

#### Flow settings
You can modify the following flow settings:

1. `ui` - Can be either `parallel`, `inline`, or `multiline`

#### Calltrace settings
You can modify the following calltrace settings:

1. `callArgs` - whether we should load args/return values for callstack/calltrace

### Telemetry
The opt-in telemetry enables the sending of anonymised usage statistics and error reports to the CodeTracer team.
This allows us to detect and fix common issues quicker and gain insight into the most important features for our community.

> [!NOTE]
> This is yet to be implemented

> [!WARNING]
> This is a global setting

### Debug
The `debug` field enables/disables debug messages.

> [!WARNING]
> This is a global setting

### Layout
The `layout` field sets the default Window management layout file that should be loaded. 

The file is usually `<your project>/.codetracer/layout.json`, and is initially created as a copy of 
`/etc/codetracer/fallback_layout.json`.

If your layout is broken, or incompatible with the current version of CodeTracer, the application will try its best to
fix the issue. If the issue is not fixed automatically, run `just reset-layout` in order to hard-reset to the default
layout file.

### Theme
The `theme` field sets the default theme file that should be loaded. 

<!-- TODO: Implement custom themes, when 1.0 is near release -->

# Legacy config
Additional legacy config can be found under `config/old`. It's mostly old tmux scripts.
