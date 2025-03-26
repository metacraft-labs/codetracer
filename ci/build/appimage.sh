#!/usr/bin/env bash

set -e

export NIXPKGS_ALLOW_INSECURE=1

./appimage-scripts/build_appimage.sh
