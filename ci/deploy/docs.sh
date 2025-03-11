#!/usr/bin/env bash

set -e

pushd docs/book/

# TODO: eventually: a more fine-grained nix shell/env?
# nix-shell --command "mdbook build"

# for now depending on global project devshell 
mdbook build # build output is in the `book` directory

# TODO: deploy book to codetracer.com ? ask Zahary?

echo '###############################################################################'
echo "TODO upload book"
echo '###############################################################################'

popd
