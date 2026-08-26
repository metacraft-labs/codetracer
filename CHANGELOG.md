# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Breaking changes

- **`ct list` now lists every artifact CodeTracer holds, not only recordings —
  and its columns changed.** It read the trace index and printed the trace
  columns, so a review dataset that `ct download` had unpacked was on the
  machine, openable with `ct review`, and invisible to the only listing the CLI
  has. It now lists recordings *and* review datasets, from the artifact model,
  with the kind as its own column.

  **Three columns the recording rows used to carry are gone**, and the removal
  is recorded here rather than left to be noticed: the recorded program's
  **arguments**, the **`ran in <workdir>`** column, and the **date**. They are
  facts a recording has and a review dataset does not, and the row is now
  kind-neutral. A fourth, the **full 36-character id appended at the end of the
  line**, was dropped by accident and **has been put back** — it is what
  `ct replay` takes, and the leading column is a shortened prefix for reading.
  A script that parsed the text rows should move to `--format json`.

- **`ct list --format json` emits artifact rows, not the trace records it used
  to.** Each entry is now `{kind, artifactId, displayName, summary, protection,
  access, openCommand}`, with `kind` a token from the artifact registry
  (`recording`, `review-dataset`). The previous shape was the serialised
  internal `Trace` object; nothing in this repository parsed it.

- **`ct upload` no longer prints the browser `replay/confirm` URL.** It was
  printed on one of the three upload paths — the single-file recording one,
  never the sliced recording path that is the normal shape for an MCR
  recording, and never for a review dataset. The kind-neutral share link
  (`/{orgSlug}/{artifactId}/download`), which every path now prints, opens the
  same web app.

- **`ct upload` and `ct download` print one sharing view instead of four
  different success blocks.** A recording and a review dataset are now
  described in the same words, in the same order; the id is called
  `Artifact id` on both (it used to be `Recording ID` on one path and
  `Artifact ID` on the other, for values in the same namespace). A sliced
  recording upload, which previously reported only `Upload finalized: N
  slices`, now reports its id, its access and its protection like every other
  upload — and its share link when the service names the artifact back, which
  on that path it may not (the recording kind's upload-session request carries
  no artifact id, so the service names the result itself).

- **`ct download` writes a machine-readable view to standard error when its
  output is not a terminal.** Standard output is unchanged and still carries
  the locator and nothing else — the recording id, or the unpacked review
  dataset's directory — because that is what the desktop app consumes. The new
  stderr line carries the same view a human is shown, including the warning
  that the service served a payload sealed for a *different* artifact than the
  link asked for.

- **`ct upload --visibility` with no value is now refused instead of silently
  meaning `--visibility=tenant`.** All three spellings — `--visibility=`, a
  bare `--visibility`, and `--visibility ""` — exit non-zero and name the
  accepted values. The argument parser dropped the first two before the command
  saw them, so an access-control setting a user typed had no effect and nothing
  said so. **`--visibility <VALUE>` and `--visibility=<VALUE>` both continue to
  work**, and an unrecognised value is refused by name against the closed set.

- **`ct record --backend <value>` now refuses a value the host cannot honour
  instead of silently recording with MCR.** `--backend rr` on macOS,
  `--backend ttd` on Linux, and any value that is not a recording backend at all
  (a misspelling) previously produced an **MCR** recording, with no diagnostic
  and a zero exit status. A script that asked for an rr recording got an MCR one
  and had no way to find out. Such an invocation now exits non-zero, before
  anything is recorded, with a message naming the requested backend, the host,
  the values valid on that host, and — in a parenthetical — where the requested
  one *is* available, so a misspelling is distinguishable from a backend that is
  simply not available here:

  ```
  error: --backend ttd cannot be honoured on this host.
         requested: ttd
         host:      linux
         valid on linux: mcr, rr
         (ttd is available on windows)
  ```

  **This is a behaviour change, not a bug fix, and scripts relying on the old
  silent fallback will start failing.** The fix is to drop the flag (MCR is the
  default on every host) or to pass `--backend mcr`, which now *pins* MCR rather
  than coinciding with the default. The flag continues to be ignored for
  languages with a dedicated recorder, where it names nothing the recorder can
  act on.

  Two values are **not** affected: `db` and `materialized`. They are the
  desktop's spelling for "record with the dedicated, materialized-trace
  recorder", they are not native backends, and the desktop puts `db` on the
  `ct record` command line itself for every target it did not classify as
  native — including files whose extension it does not recognise. They are
  accepted, select nothing native, and print a `note:` on stderr when the target
  turns out to be native.

- **The replay-worker socket now carries the language as a *name*, not as an
  enum ordinal, so `codetracer` and `ct-native-replay` must be upgraded
  together.** The `LoadLocals`, `LoadValue`, `LoadReturnValue` and
  `EvaluateWithAddress` queries used to put `Lang` on the wire as a
  `serde_repr` integer, which made the *declaration order* of two
  independently-maintained enums — one in this repository, one in
  `codetracer-native-backend` — a binary contract. The two had already
  diverged (the backend has a `Small` variant this one does not; this one has
  the whole blockchain-VM block the backend does not), so the integers agreed
  only for the low ordinals and silently disagreed above them. They now travel
  as `"c"`, `"cpp"`, `"rust"`, … and a name the backend cannot debug is
  rejected at the boundary, by name, instead of being narrowed onto a default.

  **This is deliberately not backward compatible in either direction.**
  `ct-native-replay` is discovered on `PATH` rather than bundled, so a
  mismatched pair is a real deployment state. It fails loudly rather than
  misreading: the worker answers `error: parsing query error: … expected a
  string` (old core, new worker) or `… invalid type: string`, `expected u8`
  (new core, old worker), and the core surfaces that as a query error. Nothing
  decodes a value with the wrong language's loader.

  The failure is, however, **partial and therefore easy to misread**: every
  query that does not carry a language — stepping, breakpoints, the callstack,
  jumping — keeps working on a skewed pair, so a session starts and navigates
  normally and only the *variables* fail to load. If values fail while
  everything else works, check that `ct-native-replay --version` comes from the
  same release as `ct`.

### Fixed

- **Values in C and C++ code are no longer decoded with the Rust value
  loader when the replay stops inside a header.** Neither `.h` nor any of the
  C++ header spellings (`.hpp`, `.hh`, `.hxx`, `.h++`, `.ipp`, `.tcc`) mapped
  to a language, so an rr replay stopping in an inline function, a template
  body, or any `std::` internal resolved to `Unknown` — and the native worker's
  value-loader lookup ended in a catch-all that handed `Unknown` to the **Rust**
  loader. Locals in those frames were rendered as Rust-shaped values with no
  diagnostic anywhere. The header extensions are now mapped, the catch-all is
  gone, and a language with no value loader is reported as an error and
  degraded to the raw debugger representation instead of being guessed at.

- **A binary whose language cannot be determined is now recorded as
  `unknown` rather than as `c`.** `ct-native-replay record` treated "no DWARF
  evidence and no recognisable source extension" as C — one branch even printed
  `lang: Unknown (defaulting to C)` — which was indistinguishable from a real C
  binary to everything downstream, including the code that then declined to
  consult the source extensions because it thought the language was already
  known.

### Added

- **`ct upload --visibility <tenant|tenant-or-invite>`** — one access-control
  flag for every artifact kind, saying who may read the stored copy. An
  unrecognised or missing value is refused by name against the closed set. For
  a recording the setting is recorded locally and **not** sent: that kind's
  upload API cannot carry an access record, and the command says so rather than
  displaying a setting the service was never told.

- **`ct upload` now shows what it is about to share, before asking anything.**
  Every upload — not only an encrypted one — prints who will be able to open
  the artifact, who will be able to change it, and what protection the payload
  will carry, ahead of the password prompt and ahead of any bytes moving.

- **`ct list` says what to do when there is nothing to list**, instead of
  printing an empty response: it names `ct record <PROGRAM>` and
  `ct download <LINK>`.

- **`ct record` and `ct run` now really ask `ct-native-replay` what a target
  is.** The core has always contained a delegation to the native backend for a
  target that no file extension or project manifest could identify — and it had
  always delegated to `ct-native-replay debuginfo lang`, a subcommand that has
  never existed in any released build. The argument parse failed, stdout was
  empty, and the empty string became "unknown language", which is
  indistinguishable from a recognizer that looked and found nothing. The call
  site now invokes `ct-native-replay recognize --format=json <target>` and
  consumes its result, so an extension-less native binary is recognized from its
  own bytes (ELF/Mach-O/PE container, Go build sections and runtime symbols,
  DWARF `DW_AT_language`, GNAT symbols, and the DWARF source-language mix).

  Two consequences worth knowing:

  - Recognition is **recomputed on every invocation** and nothing is cached, so
    a rebuilt binary can never be reported as the language its predecessor was.
  - `--lang` **skips recognition entirely** rather than overriding it, so a
    `--lang` recording spawns no recognizer at all. Its trace metadata is
    correspondingly thinner: nothing computed the target's components, container
    format, interpreter or debug info, and their absence means "not computed"
    rather than "the target had none".

  A `ct-native-replay` whose recognition schema this build of CodeTracer does not
  understand is refused by name, with the version found and the versions
  supported, rather than being parsed on a guess.

- `ct record --help` now describes what `--backend` actually does — the MCR
  default, the per-host value sets, and the refusal — instead of the three words
  "Record backend".

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
- Generate packages for some of the mainstream Linux distributions: <https://github.com/metacraft-labs/codetracer/issues/56> :
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
forking [the wazero WASM runtime](https://wazero.io/) : <https://github.com/metacraft-labs/codetracer-wasm-recorder/> which is the based for the
Stylus and WASM support.

One can go through the [Stylus docs](https://docs.codetracer.com/getting_started/stylus.html) in our
new docs website and follow the steps to replay an example Stylus program. One can also read how to try to build and debug simple Rust wasm programs following [Getting started with WASM](https://docs.codetracer.com/getting_started/wasm.html).

Other new developments:

- db-backend now supports a new experimental binary runtime\_tracing format (using capnproto internally, but this might be a subject to change)
- various bugfixes related to managing processes, stability
- internal tmpdir handling generalization: improving usage by different accounts
- improvements in config schema
- osx native menu and other improvements
- various user interface improvements:
  - deletable iteration in input
  - prevent text selection in footer
  - long value truncation
  - various other fixes

## 25.05.1 - 2025-05-05

The first release for a while, including our progress since March:

- Fixes:
  - Reopening closed editors bugfix
  - Ruby support: fixing the omniscience support,
        a rudimentary way to override the interpreter and
        point to a newer refactored version of the Ruby recorder
  - Using `trace_paths.json` as part of the language detection for db-based traces
  - Fix the db-backend support for multiple values for each tracepoint step
- Integration with the proprietary rr backend for native languages
    (currently requires a separate setup for the rr backend,  and custom configuration pointing to it)

## 25.03.3 - 2025-03-31

The second weekly release. It includes:

- A linking fix for our macOS build
- New stepping/state panel e2e test helpers

## 25.03.2 - 2025-03-24

The first of our weekly releases. It includes some of our initial fixes and improvements
after the initial release:

- Fixes, automations and improvements for our builds: hopefully fixing #21
- A first iteration of an improved notification/error message UX
- Refactoring and cleanup of the `ct` entrypoint source code
- Move the contributors guide to `mdbook`
- Restoring the e2e playwright-based ui tests: adapting them to the publicly released DB backend and initial work on expanding them

## 25.03.1 - 2025-02-17, 2025-03-4

The initial release of CodeTracer with support for Noir debugging.

It features the initial designs of our Call Trace, Event Log, State
and History Explorer, Scratchpad and File Explorer panels.

It offers basic support for Noir tracepoints (no function evaluation)
and the lite display mode of OmniScience.

(Initial version 25.02.1 open sourced on 17 February,
after a repo/history cleanup, superseded by current initial 25.03.1 version from 4 March)
