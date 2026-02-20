#!/usr/bin/env bash

set -e

nix flake check --override-input codetracer-ruby-recorder path:./libs/codetracer-ruby-recorder
