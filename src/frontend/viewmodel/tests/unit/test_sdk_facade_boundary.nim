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

  const guardScript = "ci/test/sdk-facade-boundary.sh"

  const notRunToken = "NOT RUN   bash-version"
    ## The one line the guard prints when it cannot run at all. See the
    ## bash-version preamble in `ci/test/sdk-facade-boundary.sh`.

  proc runGuard(root: string; envPrefix = ""): tuple[output: string, exitCode: int] =
    execCmdEx(envPrefix & "bash " & (repoRoot / guardScript) &
              " --root " & quoteShell(root))

  proc guardCouldNotRun(r: tuple[output: string, exitCode: int]): bool =
    ## Exit 2 AND the token, not either alone. Exit 2 is also the guard's
    ## "unknown argument" and "no such root", and neither of those is an
    ## environment problem to be excused — they are this suite calling it
    ## wrongly, and must still fail.
    r.exitCode == 2 and r.output.contains(notRunToken)

  template reportNotRun(r: untyped): untyped =
    ## ONE NAMED FAILURE INSTEAD OF FOUR CONTENT ONES.
    ##
    ## Until the guard learned to say `NOT RUN`, every case below reported its
    ## own `exitCode == 0` and `output.contains(...)` reds whenever the checker
    ## had not executed — four findings, one of which was this suite's own
    ## negative control claiming a violation had been detected. A reader could
    ## not tell that from a real breach of the SDK boundary.
    ##
    ## Now: if the checker could not run, this fails once, says why in the
    ## checker's own words, and stops. The suite is still RED — a boundary that
    ## went unchecked is not a pass — but red about the right thing.
    checkpoint("the SDK boundary checker did not run, so nothing about the " &
               "boundary is established. It said:")
    checkpoint(r.output.strip())
    check false

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

  test "a checker that cannot run says NOT RUN, and does not say VIOLATION":
    ## THE CONTRACT THAT WAS MISSING, and the reason the other four cases can
    ## be trusted.
    ##
    ## `ci/test/sdk-facade-boundary.sh` needs `mapfile`, a bash-4 builtin.
    ## macOS's /bin/bash is 3.2, and a LOGIN shell puts it ahead of the nix dev
    ## shell's 5.3 — `bash -lc` got 3.2 and `bash -c` got 5.3 on the same
    ## machine, in the same dev shell. Under 3.2 the guard printed one `OK`,
    ## then four `mapfile: command not found`, then `unbound variable` for
    ## every array it had failed to fill, and exited non-zero. The four cases
    ## below turned that into four content failures — one of them
    ## `VIOLATION consumer-facade-only`, this suite's own negative control.
    ##
    ## Four findings were reported. Nothing had been checked.
    ##
    ## DRIVEN WITH THE REAL CODE, NOT A FAKE. `CT_SDK_FACADE_MIN_BASH` raises
    ## the version the guard demands; set above any bash that exists, the
    ## re-exec search finds nothing and the guard takes exactly the path it
    ## takes on a 3.2-only machine. Asserting the OUTPUT and the EXIT CODE,
    ## because "could not run" and "found a violation" have to be
    ## distinguishable by a caller — that distinction is the whole fix.
    let r = runGuard(repoRoot, envPrefix = "CT_SDK_FACADE_MIN_BASH=99 ")
    check r.exitCode == 2
    check r.output.contains(notRunToken)
    check r.output.contains("Nothing about the SDK boundary has been established")
    # The half that makes it a fix rather than a nicer message: an unrunnable
    # checker must not emit the vocabulary of a finding.
    check not r.output.contains("VIOLATION")
    check not r.output.contains("OK        facade-present")
    # And `guardCouldNotRun` must recognise it, since every case below relies
    # on that to fail once and by name instead of four times and wrongly.
    check guardCouldNotRun(r)

  test "the guard passes on this repository":
    let r = runGuard(repoRoot)
    if guardCouldNotRun(r):
      reportNotRun(r)
    else:
      let (output, exitCode) = r
      if exitCode != 0:
        echo output
      check exitCode == 0
      check output.contains("OK        facade-present")
      check output.contains("OK        consumer-facade-only")

  test "a deliberate reach past the facade fails the check":
    let root = syntheticTree("../src/frontend/viewmodel/store/replay_data_store")
    defer: removeDir(root)
    let r = runGuard(root)
    if guardCouldNotRun(r):
      reportNotRun(r)
    else:
      let (output, exitCode) = r
      check exitCode != 0
      check output.contains("VIOLATION consumer-facade-only")
      check output.contains("That is an SDK internal")

  test "the same consumer importing only the facade passes":
    let root = syntheticTree("../src/frontend/viewmodel/codetracer_embed")
    defer: removeDir(root)
    let r = runGuard(root)
    if guardCouldNotRun(r):
      reportNotRun(r)
    else:
      let (output, exitCode) = r
      if exitCode != 0:
        echo output
      check exitCode == 0
      check output.contains("OK        consumer-facade-only")

  test "this file is itself a declared consumer":
    # If the marker at the top of this file were removed, the suite above
    # would still pass while asserting nothing about a real consumer. This is
    # the check that notices.
    let r = runGuard(repoRoot)
    if guardCouldNotRun(r):
      reportNotRun(r)
    else:
      let (output, exitCode) = r
      check exitCode == 0
      check not output.contains("consumer-declared: no file declares")
    let source = readFile(currentSourcePath())
    check source.contains("## SDK-CONSUMER:")
