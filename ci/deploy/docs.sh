#!/usr/bin/env bash

set -e

pushd docs/book/

# TODO: eventually: a more fine-grained nix shell/env?
# nix-shell --command "mdbook build"

# for now depending on global project devshell 
mdbook build # build output is in the `book` directory

# If the gh-pages branch already exists, this will overwrite it
# so that the history is not kept, which can be very expensive.
git worktree add --orphan -B gh-pages gh-pages
cp -a book/. gh-pages
git config user.name "Deploy from CI"
git config user.email ""
cd gh-pages
git add -A
git commit -m 'deploy new book'
git push origin +gh-pages
cd ..

popd
