#!/usr/bin/env bash

set -e

pushd docs/book/

# TODO: eventually: a more fine-grained nix shell/env?
# nix-shell --command "mdbook build"

# for now depending on global project devshell 
mdbook build # build output is in the `book` directory

# If the worktree already exists at the given location it should be removed first
if [ -d "gh-pages" ]; then
    git worktree remove gh-pages
fi

# If the gh-pages branch already exists, delete it first
if git show-ref --verify --quiet refs/heads/gh-pages; then
    git branch -D gh-pages
fi

# Create a new orphan branch (this will overwrite any existing remote branch)
# so that the history is not kept, which can be very expensive.
git worktree add --orphan -B gh-pages gh-pages
cp -a book/. gh-pages

# Required by github pages to set up a custom domain
echo "docs.codetracer.com" > gh-pages/CNAME

git config user.name "Deploy from CI"
git config user.email ""
cd gh-pages
git add -A
git commit -m 'deploy new book'
git push origin +gh-pages
cd ..

# Clean the environment
git worktree remove gh-pages
popd
