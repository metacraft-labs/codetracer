#!/usr/bin/env bash
# book-isonim-nimcfg.sh <repo-root> — write docs/book-isonim/nim.cfg, the
# absolute sibling search paths the isonim-docs book compiles against.
#
# WHY A GENERATED FILE. The book's `config.nims` resolves its sibling
# `--path`s from `currentSourcePath()/../../..`, which is right locally and
# wrong in CI ("cannot open file: build_site" with the file present: the
# checkout's parent resolves differently under nix and symlinks) — and it is
# matched by the repo-wide `*.nims` line in .gitignore, so no checkout has it
# at all. The siblings are cloned next to the repository (<repo-root>/../<repo>),
# so the paths are pinned absolutely here. Nim reads nim.cfg beside a
# config.nims; extra --paths are harmless.
#
# ONE WRITER for the two callers that build the book: ci/deploy/docs.sh (the
# publish) and the `test-book-isonim` recipe (the book's suites). The suites
# ran without it and failed at `import docs_scaffold`. Each caller removes the
# file when it is done, so the tree stays clean.
set -euo pipefail
repo_root="${1:?usage: book-isonim-nimcfg.sh <repo-root>}"
siblings="$(cd "$repo_root/.." && pwd)"
cat >"$repo_root/docs/book-isonim/nim.cfg" <<NIMCFG
--path:"$siblings/isonim-docs/src"
--path:"$siblings/codetracer-design-system/nim"
--path:"$siblings/isonim/src"
--path:"$siblings/nim-everywhere/src"
--path:"$siblings/nim-faststreams"
--path:"$siblings/nim-stew"
--path:"$siblings/isonim/vendor/chronicles"
--path:"$siblings/isonim/vendor/serialization"
--path:"$siblings/isonim/vendor/json_serialization"
NIMCFG
