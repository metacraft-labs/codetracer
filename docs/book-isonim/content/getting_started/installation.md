---
title: Installation
order: 1
---
# Installation

:::caution
CodeTracer can only be installed on Linux and macOS currently.
:::

## Download binaries
### Recommended: automatically
We provide a automatic installer that installs CodeTracer in the best possible way for your current system. You can run it by running the following in a terminal:
```
user $ curl "https://downloads.codetracer.com/install.sh" | sh
```

:::caution
On macOS it's recommended that you install homebrew beforehand. This is because the installer tries to install ruby from homebrew to enable our ruby recording
features. Make sure you install homebrew in order to not lose this feature.
:::

### Manually on Linux
Here is a list of our Linux packages:

- [Ubuntu (`deb.codetracer.com`)](https://deb.codetracer.com/)
- [Debian (`deb.codetracer.com`)](https://deb.codetracer.com/)
- [Red Hat (`rpm.codetracer.com`)](https://rpm.codetracer.com/)
- [Fedora (`rpm.codetracer.com`)](https://rpm.codetracer.com/)
- [Gentoo (metacraft-overlay)](https://github.com/metacraft-labs/metacraft-overlay)
- [Arch Linux (AUR)](https://aur.archlinux.org/packages/codetracer)
- [AppImage (amd64)](https://downloads.codetracer.com/CodeTracer-latest-amd64.AppImage)

:::tip
You can place the downloaded app in a location of your choosing (e.g. `~/.local/bin`)
:::

### Manually on macOS
You can download a `.dmg` app bundle from our website:

- [Download CodeTracer for macOS (`.dmg`, arm64)](https://downloads.codetracer.com/CodeTracer-latest-arm64.dmg)

:::tip
You can place the downloaded app in a location of your choosing (e.g., the `Applications` folder on macOS).
When you launch CodeTracer for the first time, it will prompt you to complete the remaining installation steps, such as adding the command-line utilities to your PATH.
:::

:::caution
Upon the first launch, macOS users will see the error message "CodeTracer is damaged and can't be opened". To resolve this problem, please execute the command `xattr -c <path/to/CodeTracer.app>`.

We expect this inconvenience will be remedied soon through our enrollment in the Apple Developer program that will ensure CodeTracer is properly signed and whitelisted by Apple. See [this discussion](https://discussions.apple.com/thread/253714860?sortBy=rank) for more details.
:::

:::caution
Recording ruby on macOS requires you to install ruby through [homebrew](https://brew.sh), otherwise trying to record ruby programs will fail due to the built-in ruby binary on macOS being more than 7 years old.

Once homebrew is installed, simply install ruby with `user $ brew install ruby`.
:::

:::note
Python recordings reuse whichever interpreter resolves when you run `python` (or `python3`) in your shell. Install the `codetracer_python_recorder` package in that environment (for example `pip install codetracer_python_recorder`) before running `ct record my_script.py`. You can point CodeTracer at a specific interpreter by setting `CODETRACER_PYTHON_INTERPRETER`. See the [Python getting-started guide](../getting_started/python.md) for a full walkthrough covering installation, recording, and replay.
:::

## Installation from source

### Linux (and other Nix-based systems)

#### Prerequisites

On systems that are not NixOS, you need to install `direnv` and `nix`.

Nix should not be installed through your distribution's package manager, but from [here](https://nixos.org/download/).

Direnv should be set up in your shell, as shown [here](https://direnv.net/docs/hook.html).

#### Building from source
1. Clone the repository with submodules: `git clone https://github.com/metacraft-labs/codetracer.git --recursive`
2. Enter the created directory
3. Add the following text to `~/.config/nix/nix.conf` if it doesn't already exist:
   ```
   experimental-features = nix-command flakes
   ```
4. Run `nix develop`
5. Run `direnv allow`
6. To build codetracer simply run `just build`. The location of the resulting binary will be `./src/build-debug/bin/ct`
7. Now every time you enter the `codetracer` directory your environment should be updated

:::tip
Users of Visual Studio Code might encounter issues when using `code .`. To fix them do the following:
:::

1. Run `direnv deny`
1. Run `code .`
1. Run `direnv allow`

### macOS

#### Prerequisites

The only dependencies for the macOS build are `git`, `bash` and `homebrew`.

#### Building from source
1. Clone the repository with submodules: `git clone https://github.com/metacraft-labs/codetracer.git --recursive`
2. Enter the created directory
3. Run `./non-nix-build/build.sh` from the root of the cloned repository. This will install all prerequisites like Rust, Nim and others using homebrew
4. The resulting binary can be found at `./non-nix-build/CodeTracer.app/Contents/MacOS/bin/ct`, and a DMG installer is created at `./non-nix-build/CodeTracer.dmg`.


### Building and running the tests

Currently, you can run the db-backend (Rust) tests:

```bash
# inside src/db-backend:
cargo test --release --bin db-backend # test most cases: non-ignored
cargo test --release --bin db-backend -- --ignored # test the ignored cases: ignored by default as they're slower
```

some initial simple end to end Playwright GUI tests:

```bash
just test-gui
```
