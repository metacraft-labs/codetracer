# Installation

> [!CAUTION]
> CodeTracer can only be installed on Linux and macOS currently.

## Download binaries

### Linux
Here is a list of our Linux packages:

<a href="https://deb.codetracer.com/"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/9/9e/UbuntuCoF.svg"></a>
<a href="https://deb.codetracer.com/"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/6/66/Openlogo-debianV2.svg"></a>
<a href="https://rpm.codetracer.com/"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/d/d8/Red_Hat_logo.svg"></a>
<a href="https://rpm.codetracer.com/"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/3/3f/Fedora_logo.svg"></a>
<a href="https://github.com/metacraft-labs/metacraft-overlay"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/4/48/Gentoo_Linux_logo_matte.svg"></a>
<a href="https://aur.archlinux.org/packages/codetracer"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/1/13/Arch_Linux_%22Crystal%22_icon.svg"></a>
<a href="https://downloads.codetracer.com/CodeTracer-latest-amd64.AppImage"><img width="100px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/7/73/App-image-logo.svg"></a>

> [!TIP]
> You can place the downloaded app in a location of your choosing (e.g. `~/.local/bin`)

### macOS
You can download a `.dmg` app bundle from our website:

<a href="https://downloads.codetracer.com/CodeTracer-latest-arm64.dmg"><img width="75px" height="100px" src="https://upload.wikimedia.org/wikipedia/commons/1/1b/Apple_logo_grey.svg"></a>

> [!TIP]
> You can place the downloaded app in a location of your choosing (e.g., the `Applications` folder on macOS).
> When you launch CodeTracer for the first time, it will prompt you to complete the remaining installation steps, such as adding the command-line utilities to your PATH.

> [!CAUTION]  
> Upon the first launch, macOS users will see the error message "CodeTracer is damaged and can't be opened". To resolve this problem, please execute the command `xattr -c <path/to/CodeTracer.app>`. 
> 
> We expect this inconvenience will be remedied soon through our enrollment in the Apple Developer program that will ensure CodeTracer is properly signed and whitelisted by Apple. See [this discussion](https://discussions.apple.com/thread/253714860?sortBy=rank) for more details.

> [!CAUTION]
> Recording ruby on macOS requires you to install ruby through [homebrew](https://brew.sh), otherwise trying to record ruby programs will fail due to the built-in ruby binary on macOS being more than 7 years old.
> 
> Once homebrew is installed, simply install ruby with `user $ brew install ruby`.

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
6. To build codetracer simply run `just build`. The location of the resulting binary will be `./src/build-debug/bin/ct-legacy`
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
4. The resulting binary can be found at `./non-nix-build/CodeTracer.app/Contents/MacOS/bin/ct-legacy`, and a DMG installer is created at `./non-nix-build/CodeTracer.dmg`.


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
