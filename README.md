[![CI Status](https://github.com/metacraft-labs/codetracer/actions/workflows/codetracer.yml/badge.svg?branch=main)](https://github.com/metacraft-labs/codetracer/actions/workflows/codetracer.yml)
[![Discord](https://img.shields.io/discord/1326949714679038014?label=Discord&logo=discord&style=flat)](https://discord.gg/aH5WTMnKHT)

# Introduction

CodeTracer is a user-friendly time-traveling debugger designed to support a wide range of programming languages.

It records the execution of a program into a sharable self-contained trace file. You can load the produced trace files in a GUI environment that allows you to move forward and backward
through the execution and to examine the history of all memory locations. They say a picture is worth a thousand words — well, a video is even better! Watch the demo below to see CodeTracer in action:

[![Watch the video](https://img.youtube.com/vi/xZsJ55JVqmU/maxresdefault.jpg)](https://www.youtube.com/watch?v=xZsJ55JVqmU)

## The Benefits of Time-Travel

Compared to traditional debuggers, CodeTracer gives you two major superpowers:

* **Once you capture a bug in a recording, consider it squashed!**

  Bugs that are hard to reproduce can be painful to fix — you’ve surely been there. Once such a bug is captured with CodeTracer, you'll rarely need more than 30 minutes to track it down! This is largely a consequence of the next superpower:

* **Most bugs are easily revealed when you know the origin of any value in the program.**

  All programs produce output. Some examples are bytes generated as a response to a web request, pixels being drawn on your screen or perhaps a simple log line written to the terminal.

  When CodeTracer creates a recording, it captures a user-extensible set of output events relevant to the program. The GUI displays these events in a searchable chronological event log.

  Consider a misbehaving program that prints unexpected output to a log file midway through its execution. Clicking on the specific output event in CodeTracer will take you to the precise moment and code line where it was generated.

  The unexpected value must be originating from some variable that's being passed to the logging function. With CodeTracer, you can now ask the question "Where did this value come from?". CodeTracer will find another moment in the execution, potentially multiple seconds earlier, in a completely different part of the program where this particular memory location was last written to.

  This could be memory corruption or a genuine logical error. Either way, CodeTracer will report the origin. Let's say that you end up in the correct function that is responsible for computing the problematic value, but another input there leads to the issue. You can continue the search by repeating the question "Where did this input come from"? It usually takes just a few of these jumps to earlier moments in time to arrive at the root cause for the bug.

  Every time you jump to a new moment in the execution, you can fearlessly explore your surroundings by stepping forward or backwards, having access to a back button that can always get you to any previous point of interest. At every point of the journey, our novel UI shows you details about the past and future program states at a glance and you know your position in the precisely recorded call trace of the program.

  These features combined, make for a truly powerful debugging experience.

## Current state of the project and 2025 roadmap

The initial release of CodeTracer supports the Noir programming language. It has been developed in collaboration with the Blocksense team and currently requires the use of the [Blocksense Noir Compiler](https://github.com/blocksense-network/noir), which is included in the CodeTracer distribution.

CodeTracer’s open-source development is made possible by the generous support of Aztec Network, Arbitrum Foundation, and Aptos Foundation. During 2025, CodeTracer will evolve into a comprehensive Web3 development toolkit by gaining support for many additional smart contract and zero-knowledge programming languages. Most of its functionality will be packaged into reusable libraries that will power the creation of block explorers with advanced transaction tracing capabilities and omniscient debugging plugins for Visual Studio Code and other IDEs.

CodeTracer uses an [open format](https://github.com/metacraft-labs/runtime_tracing) for its trace files and we've started several community-driven projects which aim to add support for other programming languages:

* [Ruby](https://github.com/metacraft-labs/codetracer-ruby-recorder)
* [Python](https://github.com/metacraft-labs/codetracer-python-recorder)

Metacraft Labs is also developing an alternative back-end, capable of working with [RR](https://rr-project.org/) recordings, which will make CodeTracer suitable for debugging large-scale programs in a variety of system programming languages such as C/C++, Rust, Nim, D, Zig, Go, Fortran and FreePascal.

To shape our priorities and to help us understand the demographics of our user base better, please fill out [CodeTracer Developer Preferences Survey](https://form.typeform.com/to/M2Z28VFj?utm_source=Github).

To accelerate our development, please consider donating to our Open Collective campaign. Anyone who contributes more than €50 before June 2025 will get early access to our beta releases for system programming languages, forever.

[![CodeTracer OpenCollective](https://img.shields.io/badge/Donate%20On-OpenCollective-green?style=for-the-badge)](https://opencollective.com/codetracer)

## The features of CodeTracer in more depth

Once you have time travel, you can re-imagine how a debugger works from the ground up! Here are some of the features of CodeTracer that set it apart from traditional debuggers:

### Omniscience

When CodeTracer breaks at a certain line of code, it knows not only the past but also the future. You can immediately see the values of all variables in the current function right next to the source code. This includes variables in loops where you can easily scroll through the iterations. Taken code branches are highlighted, while the non-executed code is immediately grayed out.

![omniscience](https://downloads.codetracer.com/feature-highlights/omniscience.webp "omniscience")

### Tracepoints

Many developers tend to transition from using interactive debugging early on in their careers, to mostly relying on carefully placed print statements as they start to face harder problems in distributed and real-time systems.

CodeTracer gives you the best of both worlds. A tracepoint allows you to see the effects of adding additional code to your program, without recompiling and rerecording it.

The added code can feature if statements, additional function calls and various ways to print or plot the captured data. The output is typically produced in seconds.

![tracepoint](https://downloads.codetracer.com/feature-highlights/tracepoint.webp "tracepoint")

### Call Trace

Instead of a stack trace limited to a single moment in time, CodeTracer shows you the entire tree of function calls in the recorded execution. You can navigate and filter it in various ways and the clever collapsing and expanding algorithms still allow you to obtain a classic stack trace whenever you need it.

![calltrace](https://downloads.codetracer.com/feature-highlights/calltrace.webp "calltrace")

### State and History Explorer

Every variable in CodeTracer has a history. You can see all the values that the variable held during the entire execution of the program and for each of them you can jump to the originating expression that computed it. CodeTracer follows the path of trivial copies in assignments to save you extra time when tracking down more convoluted bugs.

![state-and-history](https://downloads.codetracer.com/feature-highlights/state-and-history.webp "state-and-history")

### Event Log

The event log gives you a chronological view over anything of interest in your program, interleaved with the tracepoint outputs. Clicking on any event takes you to the precise moment in time when it was produced, which gives you excellent starting points for your investigations. Tracking down the origins of anomalous events and program states through the history of the involved variables is the essence of debugging with CodeTracer.

![eventlog](https://downloads.codetracer.com/feature-highlights/eventlog.webp "eventlog")

### Terminal Output

The terminal output panel renders the recorded `stdout` and `stderr` events like a standard terminal. Clicking anywhere in the output takes you to the exact moment when the specific character was generated. This allows for a fallback to a more traditional print-style debugging when the expressivity of tracepoints is not sufficient. In the future, CodeTracer will allow you to slide through the states of the terminal through time which will help for debugging highly interactive TUI apps.

![terminal](https://downloads.codetracer.com/feature-highlights/terminal.webp "terminal")

### Mouse Stepping

Since CodeTracer is aware of all past and future control flow, it offers some convenient shortcuts for quickly navigating the program execution by interacting with its source code:

* Jump to a line: Middle-click on any undimmed line in the current function to quickly step to it. If you use a mouse without a middle button, you can achieve the same with `Ctrl+Click` or by pressing `Ctrl+F8`(as a special kind of `continue`) after navigating to the respective line with your keyboard.
* Jump into a call: Double middle-click on the function name in a call expression to jump into it. If you use a mouse without a middle button, you can achieve the same with `Ctrl+Alt+Click` or by pressing `Ctrl+F11`(as a special kind of `step-in`) after navigating to the respective call expression with your keyboard.

Explore the right-click context menu for additional operations.

### Scratchpad

The scratchpad provides a play area where you can pin values from different locations and moments in time. You can explore their differences both manually and algorithmically to gain quick insights into the behavior of your program.

# Installing CodeTracer

## Recommended: using the CodeTracer installer
>
> [!WARNING]
> On NixOS, this script currently installs CodeTracer as a raw AppImage, since our Nix package is not yet merged in nixpkgs.
> Nix users which want to use the package should install it manually from source.

On any system, you can use the CodeTracer installer script by running the following command:

```
user $ curl "https://downloads.codetracer.com/install.sh" | sh
```

You may be asked for sudo access depending on your installation method.

This script is handy, because it installs CodeTracer in the best possible manner depending on your OS.

> [!CAUTION]
> CodeTracer requires ruby to be installed through [homebrew](https://brew.sh) for ruby support. It's recommended that you install homebrew if possible
> so that you can automatically get ruby support through the installer.

## Installing CodeTracer binaries manually

Click on the icons below that corresponds to your distribution or packaging model:

<a href="https://deb.codetracer.com/"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/9/9e/UbuntuCoF.svg"></a>
<a href="https://deb.codetracer.com/"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/6/66/Openlogo-debianV2.svg"></a>
<a href="https://rpm.codetracer.com/"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/d/d8/Red_Hat_logo.svg"></a>
<a href="https://rpm.codetracer.com/"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/3/3f/Fedora_logo.svg"></a>
<a href="https://github.com/metacraft-labs/metacraft-overlay"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/4/48/Gentoo_Linux_logo_matte.svg"></a>
<a href="https://aur.archlinux.org/packages/codetracer"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/1/13/Arch_Linux_%22Crystal%22_icon.svg"></a>
<a href="https://downloads.codetracer.com/CodeTracer-latest-amd64.AppImage"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/7/73/App-image-logo.svg"></a>
<a href="https://downloads.codetracer.com/CodeTracer-latest-arm64.dmg"><img width="75px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/1/1b/Apple_logo_grey.svg"></a>

PGP Key signatures:

[![Download macOS Signature](https://img.shields.io/badge/Download-macOS%20Signature-blue?style=for-the-badge)](https://downloads.codetracer.com/CodeTracer-latest-arm64.dmg.asc)
[![Download AppImage Signature](https://img.shields.io/badge/Download-AppImage%20Signature-blue?style=for-the-badge)](https://downloads.codetracer.com/CodeTracer-latest-amd64.AppImage.asc)
[![Download PGP Key](https://img.shields.io/badge/Download-PGP%20key-blue?style=for-the-badge)](https://downloads.codetracer.com/CodeTracer.pub.asc)

> [!CAUTION]
> When launched for the first time, macOS users will see the error message "CodeTracer is damaged and can't be opened".
> To resolve this problem, please execute the command `user $ xattr -c <path/to/CodeTracer.app>`.
>
> We expect this inconvenience will be remedied soon through our enrollment in the Apple Developer program which will ensure CodeTracer is properly signed and whitelisted by Apple.
> See [this discussion](https://discussions.apple.com/thread/253714860?sortBy=rank) for more details.

> [!CAUTION]
> Recording ruby on macOS requires you to install ruby through [homebrew](https://brew.sh), otherwise trying to record ruby programs will fail
> due to the built-in ruby binary on macOS being more than 7 years old.
>
> Once homebrew is installed, simply install ruby with `user $ brew install ruby`.

## Building from source

### Linux

The Metacraft Labs team is using [Nix](https://nixos.org/) to define a reproducible development environment for working on CodeTracer. Linux is our primary development platform, while some of our team members use macOS. Building on Windows will be supported in the near future.

To enter the Nix development environment, perform the following steps:

1) [Install Nix](https://zero-to-nix.com/start/install/).
2) Clone this repository.
3) At the repository root, execute `git submodule update --init --recursive`.
4) At the repository root, execute `nix develop` (or `direnv allow` for users of `direnv`).
5) In the resulting shell, you can build all targets by running `just build-once` or `just build` if you intend to make continuous changes to the source code.

#### NixOS

On NixOS, you can install our Nix package by running `just build-nix`.

### macOS

On macOS, we do not yet have support for Nix, instead we compile by using the non-nix-build scripts:

1. Clone this repository
1. Open a terminal and run `bash non-nix-build/build.sh`
1. Wait until it finishes installing and packaging
1. The end result will be a `CodeTracer.dmg` file that can be found under the `non-nix-build` folder.
1. For quicker testing without manually unpacking CodeTracer every time you can experiment with the contents of the `non-nix-build/CodeTracer.app` folder, which is equivalent to the final app bundle

### Windows (non-Nix bootstrap)

For Windows local development without Nix, use the scripts under `non-nix-build/windows/`:

1. Inspect pinned versions and source refs (Rust, Node.js, uv, Nim, ct-remote, Cap'n Proto, Tup): `non-nix-build/windows/toolchain-versions.env`
1. In Git Bash, source the environment (auto-installs missing tools): `source env.sh`
1. In PowerShell, dot-source the environment (auto-installs missing tools): `. .\env.ps1`

This workflow bootstraps pinned tools into a shared user cache (`%LOCALAPPDATA%/codetracer/windows-diy` by default) and keeps setup deterministic for Windows contributors.
When `env.sh` is sourced, it also ensures `libs/tree-sitter-nim/src/parser.c` is generated when missing or stale.
The parser script prefers local `libs/tree-sitter-nim/node_modules/.bin/tree-sitter` and falls back to an isolated cached `tree-sitter-cli` install when needed, so generation does not require building native addons for the full grammar package.
`env.sh` also restores caller shell options (it does not leave `set -e` enabled) and auto-installs missing Node deps in `node-packages` by default so `stylus.cmd`/`webpack.cmd` are available for `tup`/`just` (`WINDOWS_DIY_SETUP_NODE_DEPS=0` disables this behavior).
For `ct-remote`, the default is `CT_REMOTE_WINDOWS_SOURCE_MODE=auto`: on Windows x64 it uses local `../codetracer-ci` source publish output when available and otherwise falls back to pinned download, while on Windows arm64 it routes to local source and does not fall back to pinned x64 download. `CT_REMOTE_WINDOWS_SOURCE_RID` defaults by architecture (`win-x64` on x64, `win-arm64` on arm64) and remains overridable. Local-source publish now prefers `CT_REMOTE_WINDOWS_PUBLISH_SCRIPT` (default `<CT_REMOTE_WINDOWS_SOURCE_REPO>/non-nix-build/windows/publish-desktop-client.ps1`) so host-global `dotnet` is not required when that helper is present. Use `CT_REMOTE_WINDOWS_SOURCE_MODE=local|download` and `CT_REMOTE_WINDOWS_SOURCE_REPO=<path>` as needed (`download` is x64-only).
For Nim, the default is `NIM_WINDOWS_SOURCE_MODE=auto`: try building from pinned Nim/csources source refs with deterministic cache reuse, and fall back to pinned `nim-<version>_x64.zip` when source bootstrap fails. Override with `NIM_WINDOWS_SOURCE_MODE=source|prebuilt`.
For Cap'n Proto, the default is `CAPNP_WINDOWS_SOURCE_MODE=auto`: use pinned prebuilt ZIP on Windows x64 and source mode on non-x64, with deterministic source-cache reuse. Override with `CAPNP_WINDOWS_SOURCE_MODE=source|prebuilt`.
For Tup, the default is `TUP_WINDOWS_SOURCE_MODE=auto`: build from pinned source (`https://github.com/zah/tup.git` ref `variants-for-windows`) with deterministic source-cache reuse to preserve Windows variant support. `auto` only falls back to prebuilt when you explicitly provide both `TUP_WINDOWS_PREBUILT_URL` and `TUP_WINDOWS_PREBUILT_SHA256`; otherwise it remains source-only by design. Override with `TUP_WINDOWS_SOURCE_MODE=source|prebuilt`.

## Running the terminal (TUI) and native (GPUI) front-ends

Besides the Electron desktop app, CodeTracer has two native front-ends that share
the same debugger core: a terminal UI (`codetracer-tui`) and a native GPU-rendered
window (`codetracer-gpui`). Both open an existing recording.

### Build

Everything below runs at the repository root of a checkout that sits beside its
sibling repositories (see `AGENTS.md`), inside the development environment. To run
a single command in that environment without entering an interactive shell, prefix
it with `repro exec . --` (the first run in a fresh checkout takes several minutes
while the environment is built):

```bash
repro exec . -- just build-once   # ct and replay-server -> src/build-debug/bin/
repro exec . -- just build-tui    # the terminal UI -> build/bin/codetracer-tui
repro exec . -- just build-gpui   # the native window -> build/bin/codetracer-gpui
```

`just build-once` is the full build; you need it once so that `ct` (to record and
launch) and `replay-server` (the debugger engine both front-ends talk to) exist.

The front-ends compile against the sibling checkouts `../isonim-tui` and
`../isonim-gpui`. These must contain the revisions this repository pins in
`flake.lock`. Check with:

```bash
for r in isonim-tui isonim-gpui; do
  git -C ../$r merge-base --is-ancestor "$(jq -r ".nodes[\"$r\"].locked.rev" flake.lock)" HEAD \
    && echo "$r: ok" || echo "$r: behind the pin"
done
```

If one is behind and you do not want to move that checkout, build against a
detached worktree at the pinned revision instead:

```bash
for r in isonim-tui isonim-gpui; do
  rev=$(jq -r ".nodes[\"$r\"].locked.rev" flake.lock)
  git -C ../$r fetch -q origin
  if [ -d ../$r-pin ]; then git -C ../$r-pin checkout -q --detach "$rev"
  else git -C ../$r worktree add -q --detach ../$r-pin "$rev"; fi
done
export ISONIM_TUI_SRC=$PWD/../isonim-tui-pin/src ISONIM_GPUI_SRC=$PWD/../isonim-gpui-pin/src
```

The GPUI front-end also needs `isonim-gpui`'s Rust shim. Build it in the same
`isonim-gpui` checkout whose sources you compile against (`../isonim-gpui`, or
`../isonim-gpui-pin` above), through that repository's own environment:

```bash
(cd ../isonim-gpui && repro exec . -- bash -c 'cd rust && cargo build --features gpui-backend')
```

Plain `cargo build` (the `just rust-build` default) builds a shim without a window
backend, which is what the GPUI test lanes use; with it `codetracer-gpui` renders
nothing and exits immediately.

### Get a recording

```bash
repro exec . -- ct record -o /tmp/ct-calc test-programs/calc/main.py
```

`-o` names the trace folder to create. For a Python program laid out as a package
(`from app.util import ...` inside `app/main.py`), put the package's parent
directory on `PYTHONPATH`, exactly as you would to run it with `python`; without it
the recording fails with `ModuleNotFoundError`. Set it *inside* the environment
(the development environment sets its own `PYTHONPATH`, replacing one exported
before `repro exec`):

```bash
repro exec . -- env PYTHONPATH=$PWD/myproject ct record -o /tmp/ct-app myproject/app/main.py
```

`just test-tui` also records a small fixture corpus on its first run and caches it
under `test-logs/tui-fixtures/<name>-<hash>/` (`calc-…`, `wide_state-…`,
`noir_space_ship-…`); any of those folders can be opened directly.

### Launch

```bash
src/build-debug/bin/ct replay --ui=tui /tmp/ct-calc    # terminal UI, via ct
build/bin/codetracer-tui /tmp/ct-calc                 # the same, directly
```

Running a built binary does not need the development environment. `ct` finds
`build/bin/codetracer-tui` in the checkout it was built from (`CODETRACER_TUI_BIN`
overrides it), and the front-end finds `src/build-debug/bin/replay-server` the same
way; set `REPLAY_SERVER_BIN=<path>` to use a different engine build.

The native window needs a graphical session and its runtime libraries, which the
development environment provides:

```bash
repro exec . -- bash -c 'LD_LIBRARY_PATH=$CODETRACER_GPUI_RUNTIME_LIB_PATH src/build-debug/bin/ct replay --ui=gpui /tmp/ct-calc'
```

Without a display, `--report-plan` prints the window's render plan as JSON and
exits, which is a quick way to check that a build works:

```bash
repro exec . -- bash -c 'LD_LIBRARY_PATH=$CODETRACER_GPUI_RUNTIME_LIB_PATH build/bin/codetracer-gpui --report-plan /tmp/ct-calc'
```

With no display at all, a windowed launch currently prints nothing and waits;
stop it with `Ctrl+c`.

### Useful options (TUI)

| option | effect |
|---|---|
| `--theme=dark\|light\|plain` | colour mode; detected from the terminal background when absent |
| `--palette=terminal` | use only the terminal's own sixteen colours, so your terminal theme decides |
| `--truecolor` / `--no-color` | force 24-bit colour / render without colour |
| `--goto=TICK` | open at a given point of the recording |
| `--headless` | print one settled screen as plain text and exit (works without a terminal; `ct replay --ui=tui --headless <trace>`) |

`codetracer-tui --help` lists the rest.

### In the TUI

- `q` (or `Ctrl+c`) quits; `n`/`F10` steps over, `s`/`F11` steps in, `c` continues;
  `p`, `b`, `rf`, `rc` do the same in reverse.
- `F12` opens the menu (also a click on `≡`); `Tab` cycles panes.
- `:` opens the command prompt. `:icons nerd|graphics|unicode|text` picks the
  toolbar glyphs, `:theme dark|light` switches the theme, `:resize <percent>` sizes
  the focused pane, and `:reset-layout` returns to the default layout.

### Where the layout is remembered

Each front-end remembers its own last layout, separately from the others:

- TUI: `$XDG_STATE_HOME/codetracer/tui-layout.json` (`~/.local/state/codetracer/`
  when `XDG_STATE_HOME` is unset), next to the `icons` choice.
- GPUI: `gpui-layout.json` in the same directory.

`CODETRACER_TUI_LAYOUT_DIR=<dir>` replaces that directory for both, which is how
to experiment without touching your saved layout. `:reset-layout` (TUI) or
`codetracer-gpui --reset-layout` deletes only that front-end's file.

### Running the TUI in a tmux split

```bash
tmux split-window -v -c "$PWD" "build/bin/codetracer-tui /tmp/ct-calc || read"
```

The pane closes when you quit; `|| read` keeps it open if the TUI exits with an
error, so the message stays readable. For 24-bit colour inside tmux, tmux has to
know the outer terminal supports it. If the TUI's status line reports that tmux
withholds 24-bit colour, add the line it suggests to your `tmux.conf`, for example:

```
set -as terminal-features ',xterm*:RGB'
```

(or start the TUI with `--truecolor`).

## The CodeTracer CLI

When you launch the CodeTracer GUI, it will offer you the option to also install the CodeTracer CLI. It provides convenient ways to create and load trace files from the command-line or to integrate CodeTracer w
ith CI processes.

Run `ct --help` to see the full list of supported subcommands, but the most commonly used ones are the following:

`<application>` can be a source file or a project folder (depending on the language):

1. `ct run <application>` - Creates a recording and load it in CodeTracer with a single command.
1. `ct record <application>` - Creates a trace file that can be loaded later or shared. On Windows, recordings use the TTD backend (`ct record --backend ttd`) and require an elevated shell. For Python scripts this reuses the interpreter you would get by running `python` in the same shell (honoring the `CODETRACER_PYTHON_INTERPRETER`, `PYTHON_EXECUTABLE`, `PYTHONEXECUTABLE`, and `PYTHON` environment variables before falling back to `PATH`) and that interpreter must have the `codetracer_python_recorder` package installed (run `ct doctor python` to verify).
1. `ct replay` - Launches the CodeTracer GUI with a previously recorded trace file. Common usages are:
   * `ct replay` - Opens a simple console-based dialog to choose what recording you want to replay.
   * `ct replay <program-name>` - Opens the last trace of an application.
   * `ct replay --id=<trace-id>` - Opens a trace by its trace id.
   * `ct replay --trace-folder=<trace-folder>` - Opens a trace by its trace folder.
1. `ct` - Launches the startup screen of the CodeTracer GUI.
1. `ct help`/`ct --help` - Gives you a help message.
1. `ct version`/`ct --version` - Returns the current version of CodeTracer.

## Keyboard Shortcuts

You can learn all CodeTracer keyboard shortcuts by examining the main menu and the tooltips over all buttons in the interface.
The default configuration should be familiar to users experienced with Microsoft Visual Studio™.

Since CodeTracer provides a reverse counterpart to most traditional debugging operations, we typically use the `Shift` modifier to indicate this (e.g. `F10` is "Next Step" while `Shift+F10` is "Previous Step").

The user config file located at `~/.config/codetracer/.config.yml` allows you to specify custom shortcuts for all operations.

# Contributing

Check out our [Contributors Guide](./CONTRIBUTING.md) for more details.

## License

CodeTracer is distributed under the GNU Affero General Public License (AGPLv3).

The wasm-sysroot is copied from the tree-sitter repo: (<https://github.com/tree-sitter/tree-sitter>) : specifically <https://github.com/tree-sitter/tree-sitter/tree/master/crates/language/wasm/include>. The C headers there are a modified version of glibc headers, which are originally under LGPL license.

# Miscellaneous

## Small Language Constructs

CodeTracer includes a miniature Lisp-like language called **small** used in some of the example programs. The constructs demonstrate how a language can integrate with the [`runtime_tracing`](https://github.com/metacraft-labs/runtime_tracing) format.

### Core constructs

| Construct | Example | Description |
|-----------|---------|-------------|
| `(defun name (params...) expr...)` | `(defun add-one (x) (add x 1))` | Define a function |
| `(set var value)` | `(set x 1)` | Assign a value |
| `(set-deref ref value)` | `(set-deref r 5)` | Write through a reference |
| `(vector v1 v2 ...)` | `(vector 1 2)` | Create a vector |
| `(# vec index)` | `(# v 0)` | Indexing |
| `(push vec value)` | `(push v 3)` | Append to a vector |
| `(loop i from to body)` | `(loop i 0 3 (print i))` | Simple loop |
| `(ref var)` | `(ref x)` | Create a reference |
| `(deref ref)` | `(deref r)` | Read from a reference |
| `(add a b)` | `(add 1 2)` | Integer addition |
| `(print expr ...)` | `(print x)` | Print to stdout |
| `(write-file path data)` | `(write-file "out.txt" "hi")` | Write a file |

### runtime\_tracing events

| Event | Purpose |
|-------|---------|
| `Write` | Terminal output produced by `print` |
| `WriteFile` | File creation via `write-file` |
| `WriteOther` | Other write operations |
| `Read` | Reads from standard input |
| `ReadFile` | Reading from files |
| `ReadOther` | Miscellaneous read operations |
| `ReadDir` | Directory listing |
| `OpenDir` | Opening a directory |
| `CloseDir` | Closing a directory |
| `Socket` | Network socket activity |
| `Open` | Opening files or sockets |
| `Error` | Error reporting |
| `TraceLogEvent` | Events generated by the tracer |

## Contributing

Check out our [Contributors Guide](./CONTRIBUTING.md) for more details.

## License

CodeTracer is distributed under the GNU Affero General Public License (AGPLv3).

The wasm-sysroot is copied from the tree-sitter repo: (<https://github.com/tree-sitter/tree-sitter>) : specifically <https://github.com/tree-sitter/tree-sitter/tree/master/crates/language/wasm/include>. The C headers there are a modified version of glibc headers, which are originally under LGPL license.
