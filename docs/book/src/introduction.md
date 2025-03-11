# Introduction

Welcome to the codetracer-desktop wiki. Here you can find information on almost every topic
regarding codetracer development and usage.

## Installation
> [!CAUTION]
> Codetracer can only be installed on Linux and macOS currently.

### Prerequisites
On systems that are not NixOS, you need to install `direnv` and `nix`.

Nix should not be installed through your distribution's package manager, but from [here](https://nixos.org/download/).

Direnv should be set up in your shell, as shown [here](https://direnv.net/docs/hook.html).

### Installation
1. Setup SSH with our private GitLab instance: <https://gitlab.metacraft-labs.com>
1. Clone the repository with submodules: `git clone gitlab@gitlab.metacraft-labs.com:codetracer/codetracer-desktop.git --recursive`
1. Enter the created directory
1. For first-time setup:
   - Create a PAT from [here](https://gitlab.metacraft-labs.com/-/user_settings/personal_access_tokens)
   - Create a new token with at least `read_api` and `read_repository` access
   - Add the following text to `~/.config/nix/nix.conf`
   ```
   access-tokens = gitlab.metacraft-labs.com=PAT:<token>
   experimental-features = nix-command flakes
   ```
   - And replace `<token>` with your PAT
1. Run `nix develop`
1. Run `direnv allow`
1. To build codetracer simply run `just build`
1. Now every time you enter the `codetracer-desktop` directory your environment should be updated

<!-- Question: Is an access token required for GitHub right now? It might be needed if we use the GitHub API more than a couple of times a second
TODO:
1. Change repository URL
1. Remove references to GitLab
-->


> [!TIP]
> Users of Visual Studio Code might encounter issues when using `code .`. To fix them do the following:
> 1. Run `direnv deny`
> 1. Run `code .`
> 1. Run `direnv allow`

### Building and running the tests

Coming soon!

### Enabling `cachix`

<!-- TODO(alexander): I removed the detailed cachix guide, as it's sensitive, and we don't have a public codetracer cache yet  -->
<!-- either include it in an internal docs in the rr-backend, or re-include here when this is discussed again -->

Cachix is a cache for nix that allows you to save time on compiling codetracer and related projects. We'll discuss using a public codetracer cache
for the open sourced parts, however this is available only internally for now.

