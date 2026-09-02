## Grade a body served at `/build-id.txt` — the ONE implementation of the rule.
##
## ## Why this program exists rather than a grep
##
## Two readers need this answer: `ci/test/web-bundle-assets.sh`, which grades
## the file it just wrote into the publish directory, and
## `ci/test/verify-build-id.sh`, which grades what a HOST returns after a
## deploy. A shell predicate in each would be two spellings of one rule, free
## to drift, and the drift would be silent in the direction that matters —
## a probe that accepts something the writer never writes reports green about
## a deployment nobody checked.
##
## So the rule is `platform/web_deployment.buildIdDefects`, a value in the
## product, unit-tested on both backends over inputs no network can produce —
## including the Cloudflare SPA fallback. This program is the thin shell around
## it.
##
## ## The trap it exists to close
##
## Cloudflare Pages answers an absent path with the entry document: **200 OK,
## `text/html`, ~9 KB of SPA**. A check that fetched `/build-id.txt` and
## asserted a 200 would therefore be green against every deployment that has
## never published the file — a check that cannot fail. `buildIdDefects` reads
## the BYTES: `builtFrom <40-hex>`, a branch, and equality with the revision
## under test. An HTML document fails it by name.
##
## Usage:
##   build_id_check <expected-commit|-> <label> <file>
##
## `-` for the expected commit asks only "is this a build identity at all",
## which is what a by-hand probe of an arbitrary host wants. A commit makes it
## the identity test a deploy needs.
##
## Exit: 0 clean, 1 defects (each printed as a sentence), 2 could not run.

import std/[os, strutils]

import ../../src/frontend/viewmodel/platform/web_deployment

when isMainModule:
  if paramCount() != 3:
    stderr.writeLine "usage: build_id_check <expected-commit|-> <label> <file>"
    quit 2
  let expectedArg = paramStr(1)
  let label = paramStr(2)
  let path = paramStr(3)

  let expected = if expectedArg == "-": "" else: expectedArg
  # A MALFORMED EXPECTATION IS A BROKEN INSTRUMENT, not a failing deployment.
  # `buildIdDefects` would happily report "this host serves X but the revision
  # under test is <garbage>", blaming the host for the caller's mistake — and
  # an empty `$GITHUB_SHA` would silently downgrade the whole check to "is this
  # a build identity at all", which is the vacuous form this file exists to
  # refuse. Exit 2, so a caller can tell it from a red deployment.
  if expected.len > 0 and not isCommitName(expected):
    stderr.writeLine "the expected commit is not a 40-hex object name: " &
      expected
    quit 2

  if not fileExists(path):
    stderr.writeLine label & ": no body to grade at " & path
    quit 2

  let body = readFile(path)
  let defects = buildIdDefects(body, expected)
  if defects.len == 0:
    let identity = parseBuildId(body)
    echo "ok: " & label & " publishes " & renderBuildId(identity).strip()
    quit 0
  for defect in defects:
    stderr.writeLine "  " & label & ": " & defect
  quit 1
