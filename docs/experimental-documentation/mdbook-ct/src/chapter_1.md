# Introduction

Welcome to the codetracer-desktop wiki. Here you can find information on almost every topic
regarding codetracer development and usage.

## What is codetracer
Codetracer is a debugging environment, based on the concept of record and replay, developed as a powerful tool to easily
debug complex applications.

## Installation
> [!CAUTION]
> Codetracer can only be installed on Linux and macOS.

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
To start running tests do the following:

1. Run `tester build` - Builds tester
1. Run `tester parallel` - Runs the tests

### Enabling `cachix`
> [!NOTE]
> This step is optional

<!-- TODO: Scrap or completely rewrite the cachix instructions for end users. Alternatively, make this an internal developer guide -->

Cachix is a cache for nix that allows you to save time on compiling codetracer and related projects. To enable `cachix` do the following:

1. Log into [cachix](https://www.cachix.org/) with your personal GitHub account
1. Create an authentication token
1. Run `cachix authtoken --stdin`
1. Paste the token and click enter
1. Press `CTRL + D` to save the token
1. Run `cachix use metacraft-labs-codetracer`
1. Run `direnv allow`, `nix develop`, or `just build-nix` to auto-download cached binaries if available

### Explicit `cachix` setup
> [!NOTE]
> You have to be an admin for the private cache. Ask an administrator to get added.

Our current `cachix` setup pushes binaries from CI, but if you want to manually push to `cachix` as well, or want to know how pushing works, you can do the following:

1. Go to [this page](https://app.cachix.org/organization/metacraft-labs/cache/metacraft-labs-codetracer/settings/authtokens)
1. Create an auth token with `Read+Write` permissions
1. Locally register it as described in the above heading

To push the dev shell to `cachix` use either one of the following commands:

1. Automatically: `just cachix-push-devshell`
1. Manually: `cachix push metacraft-labs-codetracer "$(nix build --print-out-paths .#devshells.x86_64-linux.default)"`

