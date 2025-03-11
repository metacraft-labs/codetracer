## Build systems

Codetracer uses nix, just, tup and direnv as parts of its build system.

## Breakdown of the different components
### Nix
The Nix package manager/build system deals with managing all dependencies, required by CodeTracer, as well as packaging
it for NixOS. It can package for other operating systems through an AppImage generator utility, however currently we are building our
appimages with custom shell scripts in `appimage-scripts`.

### Just

The `just` tool is used to trigger build commands and various other actions. It's semi-analogous to a Makefile. The following commands are
the most widely-used:

1. `just build` - Builds the project with Tup and starts the automatic build process, which is used for active development
1. `just build-once` - Just builds the project using Tup
1. `just build-nix` - Builds the project and packages it for Nix
1. `just build-docs` - Builds the documentation. More info can be found [here](https://dev-docs.codetracer.com/Misc/BuildDocs)
1. `just cachix-push-nix-package` - Pushes nix package artefacts to cachix
1. `just cachix-push-devshell` - Pushes the current dev shell to cachix
1. `just reset-db` - Resets the local user's trace database
1. `just clear-local-traces` - Clears the local user's traces
1. `just reset-layout` - Resets the GUI window arrangements layout if your user's layout is incompatible with the latest version of CodeTracer. Further [documentation](https://dev-docs.codetracer.com/Introduction/Configuration)
1. `just reset-config` - Resets the user's configuration if it's incompatible with the latest version of CodeTracer. Further [documentation](https://dev-docs.codetracer.com/Introduction/Configuration)

### Tup
The Tup build system is used for local builds of CodeTracer and deals with calling the actual low-level build instructions.

### Direnv
The `direnv` utility sets up your local environment for using CodeTracer.

## Packaging

### More detailed breakdown of the Nix package

Coming soon!

### Packaging for non-NixOS distributions

> [!TIP]
> If you're a user that wants a package for your distribution contact us. We're currently in the process of creating
> packages for popular distributions, such as Debian/Ubuntu, Fedora/RHEL, Arch Linux, Gentoo, Void, etc. 

To package for another Linux distribution with a ports-based package manager, you can utilise our AppImage(currently unreleased), 
which you can install to `/usr/bin`. Along with it, you should also install our icon and desktop file 
from `resources/` to the needed directories, such as `/usr/share/pixmaps` and `/usr/share/applications`.

### Packaging for Windows(DB-backend only)

Coming soon!

### Packaging for macOS(DB-backend only)

Coming soon!

