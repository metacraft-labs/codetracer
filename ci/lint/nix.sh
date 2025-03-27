#!/usr/bin/env bash

set -e

export NIXPKGS_ALLOW_INSECURE=1

nix flake check --impure
