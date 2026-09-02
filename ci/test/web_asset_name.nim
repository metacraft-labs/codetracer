## Print the content-addressed name for one published asset, for the assembly
## step.
##
## ## Why the shell does not spell this name itself
##
## Because the shell is not what decides whether the name earns `immutable`.
## `platform/web_deployment.assetIsContentAddressed` decides that, and it is
## read by the cache table, by the deploy workflow's header sweep and by
## `verify-deployed-bytes.sh`. A `sed` in `web-bundle-assets.sh` that inserted a
## digest would be a SECOND description of the same convention, and the two
## would agree right up until somebody changed one — at which point the
## deployment would publish names the predicate rejects, `staticAssetGlobClass`
## would answer `ccMutableAsset`, and the only symptom would be that the site
## got slower.
##
## That is not hypothetical, it is the defect this program is the other half of.
## Until 2026-09-01 the cache class was tested with `/assets/app.9f2b1c.js` — a
## filename no assembly step had ever produced — so the class was validated on
## fiction while all three real paths went unchecked. This program is what makes
## the example and the output the same thing: it calls `contentAddressedPath`,
## which is what the unit test calls, and it REFUSES TO PRINT a name that
## `assetIsContentAddressed` would not accept. A disagreement between the
## producer and the predicate is now a failed assembly rather than a slow site.
##
## Compiled and run by `ci/test/web-bundle-assets.sh`, for the reason the
## manifest and render programs are: a Nim file no lane compiles is this
## repository's signature defect.
##
## Usage:
##   web_asset_name <path> <hex-digest>
##
## `path` is bundle-relative (`assets/wasm-worker.js`), `hex-digest` is the
## file's SHA-256 in hex; only the first `assetDigestLength` characters are
## used. Prints the new bundle-relative path on stdout and nothing else.
##
## Exit: 0 printed a content-addressed name, 2 could not.

import std/os

import ../../src/frontend/viewmodel/platform/web_deployment

when isMainModule:
  if paramCount() < 2:
    stderr.writeLine "usage: web_asset_name <path> <hex-digest>"
    quit 2
  let path = paramStr(1)
  let digest = paramStr(2)

  let named = contentAddressedPath(path, digest)
  if named.len == 0:
    stderr.writeLine "cannot content-address `" & path & "` with digest `" &
      digest & "`: a digest needs at least " & $assetDigestLength &
      " hex characters and the path needs an extension to sit in front of"
    quit 2

  # THE ASSERTION THAT MAKES THIS A BRIDGE RATHER THAN A STRING FORMATTER.
  # The published name and the predicate that grants `immutable` are two
  # functions in one module, and this is where they are made to agree on a real
  # input rather than on an illustrative one.
  if not assetIsContentAddressed("/" & named):
    stderr.writeLine "produced `" & named &
      "`, which assetIsContentAddressed rejects — the assembly step and the " &
      "cache class disagree, and the deployment would be served " &
      mutableAssetHeader & " for the whole of /assets/"
    quit 2

  # And it must be a DIFFERENT name, or the rename below is a no-op and every
  # deploy keeps publishing to the same address it just promised was immutable.
  if named == path:
    stderr.writeLine "produced the input path unchanged; nothing was addressed"
    quit 2

  echo named
