# Changelog

All notable changes to this project will be documented in this file.

## Next release
???

Other new developments:

- Various UI improvements:
  - Fixed certain tooltips and popups produced by the editor widget being clipped in the first lines of code
  - Fixed incorrect text highlighting persistance after selecting a file in the global search bar

## 25.07.1 - 2025-07-22

We are releasing our initial Arbitrum Stylus and WASM support with this version!

Now CodeTracer can record and replay [Arbitrum Stylus](https://arbitrum.io/stylus) contracts.
It can also record and replay Rust programs compiled to WASM: we implemented a wasm codetracer recorder, 
forking [the wazero WASM runtime](https://wazero.io/) : https://github.com/metacraft-labs/codetracer-wasm-recorder/ which is the based for the
Stylus and WASM support.

One can go through the [Stylus docs](https://docs.codetracer.com/getting_started/stylus.html) in our
new docs website and follow the steps to replay an example Stylus program. One can also read how to try to build and debug simple Rust wasm programs following [Getting started with WASM](https://docs.codetracer.com/getting_started/wasm.html).


Other new developments:

* db-backend now supports a new experimental binary runtime_tracing format (using capnproto internally, but this might be a subject to change)
* various bugfixes related to managing processes, stability
* internal tmpdir handling generalization: improving usage by different accounts
* improvements in config schema
* osx native menu and other improvements
* various user interface improvements: 
  * deletable iteration in input
  * prevent text selection in footer
  * long value truncation
  * various other fixes


## 25.05.1 - 2025-05-05

The first release for a while, including our progress since March:

* Fixes:
    * Reopening closed editors bugfix
    * Ruby support: fixing the omniscience support,
        a rudimentary way to override the interpreter and 
        point to a newer refactored version of the Ruby recorder
    * Using `trace_paths.json` as part of the language detection for db-based traces
    * Fix the db-backend support for multiple values for each tracepoint step
* Integration with the proprietary rr backend for native languages 
    (currently requires a separate setup for the rr backend,  and custom configuration pointing to it)

## 25.03.3 - 2025-03-31

The second weekly release. It includes:

* A linking fix for our macOS build
* New stepping/state panel e2e test helpers


## 25.03.2 - 2025-03-24

The first of our weekly releases. It includes some of our initial fixes and improvements
after the initial release:

* Fixes, automations and improvements for our builds: hopefully fixing #21
* A first iteration of an improved notification/error message UX
* Refactoring and cleanup of the `ct` entrypoint source code
* Move the contributors guide to `mdbook`
* Restoring the e2e playwright-based ui tests: adapting them to the publicly released DB backend and initial work on expanding them

## 25.03.1 - 2025-02-17, 2025-03-4

The initial release of CodeTracer with support for Noir debugging.

It features the initial designs of our Call Trace, Event Log, State
and History Explorer, Scratchpad and File Explorer panels.

It offers basic support for Noir tracepoints (no function evaluation)
and the lite display mode of OmniScience.

(Initial version 25.02.1 open sourced on 17 February, 
after a repo/history cleanup, superseded by current initial 25.03.1 version from 4 March)

