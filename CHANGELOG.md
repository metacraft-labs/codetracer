# Changelog

All notable changes to this project will be documented in this file.

## 25.11.1 - 2025-11-07(hotfix)

Introduced a number of hotfixes for some bugs:

- macOS: Fix Rossetta popups by forcing native execution
- Linux: Fix AppImage RPATHs for some libraries

## 25.10.1 - 2025-10-30

We are releasing our new version enabling support for Python recordings!

They are based on our [codetracer-python-recorder](https://github.com/metacraft-labs/codetracer-python-recorder)
and one needs to install it (e.g. with `pip install codetracer-python-recorder`) to be able to use `ct record <script.py>`

One can read more in the [docbook section for Python](https://docs.codetracer.com/getting_started/python.html)

There are also some bugfixes, and a lot of work on various other features which are still in development.

Bugfixes:
  - bugfix(ruby): Fix ruby output being on a single line (fix for one of the newer ruby recorders this time)
  - bugfix(frontend): add uniform disabled style for future in both event log and terminal
  - security fixes, cleanups and upgrades of packages
Refactorings:
  - refactor additional parts of our frontend/index code

## 25.09.2 - 2025-09-25(hotfix)

Introduced a number of hotfixes for critical bugs:

- AppImage
  - Introduced additional points of termination for backend-manager(fixed fatal crash)
  - Removed raw usages of `/tmp` in parts of our codebase
  - Set relative rpath instead of depending on `LD_LIBRARY_PATH`(fixed fatal crash)
- macOS
  - Fix ruby not being symlinked
  - Removed raw usages of `/tmp` in parts of our codebase
  - Introduced additional points of termination for backend-manager
- Other fixes
  - The help message no longer uses the internal executable name instead of `ct`
  - The Gentoo package was renamed to `codetracer-bin` from `codetracer`
  - The AUR package now upgrades without having to uninstall it and delete its pacman caches

## 25.09.1 - 2025-09-19


We are releasing our initial version with DAP support and reformed frontend architecture!

- DAP support and frontend architecture reform:
  Our backend and frontend have been reformed: now we use DAP instead of our older custom protocol, and
  our frontend components are more self contained and independent: needed for our work on a CodeTracer extension.
  Our DAP support is tested more under VsCode. We don't implement many optional aspects yet, but we do implement our custom
  functionalities and queries, defining our custom extensions to DAP: `ct/`-namespaced custom requests and events.

- A new backend multiplexer:
  We have also added an experimental new backend multiplexer, which gets us closer to the ability to replay multiple traces/backend instances
  in the same session and window.

We have also many other important improvements:

- Integrated a reformed version of the Ruby recorder
- Support for our newer trace binary trace format "version 1", based on CBOR and Zstd seekable compression
- Generate packages for some of the mainstream Linux distributions: https://github.com/metacraft-labs/codetracer/issues/56 :
  please look at the README for links/more info!

- codetracer-wasm-recorder
 - Hotfix the locals array to resize itself dynamically, resolving an array out of bounds crash for our Stylus wasm recorder
- various bugfixes:
  - some fixes for `ct host`: the browser mode of codetracer and for our cloud integration
  - a bugfix for `ct record`: store sensible source folders if the context is not a git repo
  - various build fixes
- Various UI improvements:
  - Fixed certain tooltips and popups produced by the editor widget being clipped in the first lines of code
  - Fixed incorrect text highlighting persistance after selecting a file in the global search bar
- macOS support:
  - Fixed dead link preventing users from recording ruby correctly
  - CodeTracer no longer requires homebrew(homebrew is still required for ruby)
  - The CodeTracer team now officially supports all versions of macOS, since macOS 12 Monterey

## 25.07.1 - 2025-07-22

We are releasing our initial Arbitrum Stylus and WASM support with this version!

Now CodeTracer can record and replay [Arbitrum Stylus](https://arbitrum.io/stylus) contracts.
It can also record and replay Rust programs compiled to WASM: we implemented a wasm codetracer recorder, 
forking [the wazero WASM runtime](https://wazero.io/) : https://github.com/metacraft-labs/codetracer-wasm-recorder/ which is the based for the
Stylus and WASM support.

One can go through the [Stylus docs](https://docs.codetracer.com/getting_started/stylus.html) in our
new docs website and follow the steps to replay an example Stylus program. One can also read how to try to build and debug simple Rust wasm programs following [Getting started with WASM](https://docs.codetracer.com/getting_started/wasm.html).


Other new developments:

* db-backend now supports a new experimental binary runtime\_tracing format (using capnproto internally, but this might be a subject to change)
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
