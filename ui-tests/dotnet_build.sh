#!/usr/bin/env bash

# useful mostly for nixos for now!

# DEPENDS on $NIX_NODE being set up by the nix shell hook
# or in some other way: pointing to valid node binary for nix


dotnet build

# TODO: eventually check if node already the correct nix one?
#   and replace only if not?
#   possible maybe with readelf -d binary | grep RUNPATH
#   or comparing the binaries?

if ! diff "$NIX_NODE" bin/Debug/net8.0/.playwright/node/linux-x64/node ; then
  #   echo "different"
  rm --force bin/Debug/net8.0/.playwright/node/linux-x64/node && \
    cp "$NIX_NODE" bin/Debug/net8.0/.playwright/node/linux-x64/node;
  exit 0
fi
# echo "same"

