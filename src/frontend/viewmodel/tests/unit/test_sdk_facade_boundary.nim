## SDK-CONSUMER: the half of the Embed SDK's conformance suite that shells
## out. Split from `test_sdk_facade.nim` so that file can compile under
## `nim js` — see below.
##
## test_sdk_facade_boundary.nim
##
## The third property of the facade, and the only one a Nim compile cannot
## assert about itself: that reaching PAST the facade **fails a build**. Nim
## is perfectly happy to import an internal, so these cases run
## `ci/test/sdk-facade-boundary.sh` against synthetic trees and read its exit
## status.
##
## ## Why this is a separate file
##
## `execCmdEx` and `quoteShell` come from `std/osproc`, which does not compile
## on the JS target (`Error: cannot export: quoteShell`), and the temporary
## trees need `std/os`. While these four cases lived in `test_sdk_facade.nim`,
## that file — the whole of M2a's `test_session_lifecycle_and_error_taxonomy`
## evidence — could only ever run on the C backend.
##
## That was not a cosmetic limit. It hid a real defect: on the JS backend
## `nim_everywhere/async_compat.onComplete` queues even a synchronously
## resolved future's callback, so `DebuggerSession.launch` reached its
## `markReady` check before any handshake response had been observed and a
## launch the backend had REFUSED was reported as `dspReady` with an empty
## `failure`. The entire §6.3 error taxonomy was inert on the backend
## BlockTracer ships, and no suite could see it because no suite could be
## compiled for that backend. Front-End-Architecture.md §6 asks for the
## pyramid "on both the C and JS backends" for exactly this reason.
##
## So the split is not tidiness: it is what lets the `vm-unit-js` lane exist.
##
## Compile and run (C backend only — see above):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_sdk_facade_boundary.nim

import std/[os, osproc, random, strutils, times, unittest]

# ---------------------------------------------------------------------------
# The boundary itself
# ---------------------------------------------------------------------------

suite "Embed SDK facade — the boundary is enforced, not documented":

  # The guard is a bash script, so these run it. They are the only place in
  # this file that shells out, and the reason is that the property under test
  # is "a build fails", which no Nim expression can assert about itself.

  const repoRoot = currentSourcePath().parentDir.parentDir.parentDir
                     .parentDir.parentDir.parentDir
    ## src/frontend/viewmodel/tests/unit/<this file> -> six levels to the root.

  proc runGuard(root: string): tuple[output: string, exitCode: int] =
    execCmdEx("bash " & (repoRoot / "ci/test/sdk-facade-boundary.sh") &
              " --root " & quoteShell(root))

  proc writeConsumer(dir, name, body: string) =
    createDir(dir)
    writeFile(dir / name, body)

  proc syntheticTree(consumerImport: string): string =
    ## A minimal repo-shaped tree: a facade, one internal, and one declared
    ## consumer importing whatever the caller asks for.
    let root = getTempDir() / "ct-sdk-boundary-" & $epochTime().int64 &
               "-" & $rand(high(int))
    let vmDir = root / "src/frontend/viewmodel"
    createDir(vmDir)
    writeFile(vmDir / "codetracer_embed.nim",
      "const CodeTracerEmbedFacadeModule* = \"codetracer_embed\"\n")
    createDir(vmDir / "store")
    writeFile(vmDir / "store" / "replay_data_store.nim", "const X* = 1\n")
    writeConsumer(root / "consumer", "pane.nim",
      "## SDK-CONSUMER: synthetic\nimport " & consumerImport & "\n")
    # The guard enumerates through git, so the tree has to be a repo.
    discard execCmdEx("git -C " & quoteShell(root) & " init -q")
    root

  test "the guard passes on this repository":
    let (output, exitCode) = runGuard(repoRoot)
    if exitCode != 0:
      echo output
    check exitCode == 0
    check output.contains("OK        facade-present")
    check output.contains("OK        consumer-facade-only")

  test "a deliberate reach past the facade fails the check":
    let root = syntheticTree("../src/frontend/viewmodel/store/replay_data_store")
    defer: removeDir(root)
    let (output, exitCode) = runGuard(root)
    check exitCode != 0
    check output.contains("VIOLATION consumer-facade-only")
    check output.contains("That is an SDK internal")

  test "the same consumer importing only the facade passes":
    let root = syntheticTree("../src/frontend/viewmodel/codetracer_embed")
    defer: removeDir(root)
    let (output, exitCode) = runGuard(root)
    if exitCode != 0:
      echo output
    check exitCode == 0
    check output.contains("OK        consumer-facade-only")

  test "this file is itself a declared consumer":
    # If the marker at the top of this file were removed, the suite above
    # would still pass while asserting nothing about a real consumer. This is
    # the check that notices.
    let (output, exitCode) = runGuard(repoRoot)
    check exitCode == 0
    check not output.contains("consumer-declared: no file declares")
    let source = readFile(currentSourcePath())
    check source.contains("## SDK-CONSUMER:")
