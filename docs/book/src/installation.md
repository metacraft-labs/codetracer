# Installation

> [!CAUTION]
> Codetracer can only be installed on Linux and macOS currently.

## Download binaries

### Linux
You can download the Linux AppImage from our website:
[![Download AppImage](https://img.shields.io/badge/Download-Linux%20AppImage-blue?style=for-the-badge)](https://downloads.codetracer.com/CodeTracer-25.07.1-amd64.AppImage)

> [!TIP]
> You can place the downloaded app in a location of your choosing (e.g. `~/.local/bin`)

### macOS
macOS binaries are temporarily unavailable but will be restored soon.
You can download a `.dmg` app bundle from our website:
[![Download macOS](https://img.shields.io/badge/Download-macOS-blue?style=for-the-badge)](https://downloads.codetracer.com/CodeTracer-25.07.1-arm64.dmg)

> [!TIP]
> You can place the downloaded app in a location of your choosing (e.g., the `Applications` folder on macOS).
When you launch CodeTracer for the first time, it will prompt you to complete the remaining installation steps, such as adding the command-line utilities to your PATH.

> [!CAUTION]  
> Upon the first launch, macOS users will see the error message "CodeTracer is damaged and can't be opened". To resolve this problem, please execute the command `xattr -c <path/to/CodeTracer.app>`. We expect this inconvenience will be remedied soon through our enrollment in the Apple Developer program that will ensure CodeTracer is properly signed and whitelisted by Apple. See https://discussions.apple.com/thread/253714860?sortBy=rank for more details.

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

> [!TIP]
> Users of Visual Studio Code might encounter issues when using `code .`. To fix them do the following:
> 1. Run `direnv deny`
> 1. Run `code .`
> 1. Run `direnv allow`

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

some initial simple end to end playwright tests:

```bash
just test-e2e
````
