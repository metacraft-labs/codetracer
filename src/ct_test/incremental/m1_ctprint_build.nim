## CI-safe `ct-print` resolution for the M1 parity test.
##
## `test_executed_functions_seekable_matches_ctprint` anchors correctness by
## comparing the in-process seekable read against the ACTUAL `ct-print
## --json-events` output.  That comparison is only meaningful if `ct-print` is
## present — but in CI it is NOT pre-built, and the impl prototype historically
## relied on a stray `/tmp/ctprint_build/ct-print` artifact that does not exist
## on a clean checkout.  Depending on that artifact would make the parity anchor
## either hard-fail (binary missing) or — worse — silently not run.
##
## This module removes that dependency: `ensureCtPrint` resolves `ct-print` via
## the documented precedence (`$CT_PRINT` / `PATH` / the known build path) and,
## when none of those resolve, BUILDS it deterministically from the
## `codetracer-trace-format-nim` source that the ct_test build already links
## (`incremental/ctfs_seekable.nim` imports the same package).  The build uses
## the SAME `results` pin and zstd include the `ct_test` `config.nims` derives,
## so it works inside the Nix dev shell and in CI without any pre-staged binary.
##
## Only when the trace-format-nim SOURCE itself cannot be located (a genuinely
## degraded environment) does it return an `Err`, so the test can SKIP with a
## clear reason rather than fail confusingly or pass vacuously.

import std/[os, osproc, strutils, streams]
import results

const
  ## The trace-format-nim entry point for the `ct-print` utility, relative to
  ## that package's `src` directory.
  CtPrintSourceRel = "codetracer_ct_print.nim"

proc traceFormatNimSrcDir(): string =
  ## Locate the `codetracer-trace-format-nim` `src` directory the ct_test build
  ## links against.  Precedence mirrors `nim.cfg` / `config.nims`:
  ##   1. `$CODETRACER_TRACE_FORMAT_NIM_SRC` (CI / worktree / standalone clones);
  ##   2. the relative sibling checkout, resolved from THIS source file's path
  ##      (`src/ct_test/incremental` -> repo root -> workspace root ->
  ##      `codetracer-trace-format-nim/src`) — the normal workspace layout.
  ## Returns "" when neither resolves.
  let envSrc = getEnv("CODETRACER_TRACE_FORMAT_NIM_SRC")
  if envSrc.len > 0 and dirExists(envSrc):
    return envSrc
  # currentSourcePath() points at THIS file; walk up to the workspace root.
  let here = currentSourcePath().parentDir()          # .../src/ct_test/incremental
  let repoRoot = here.parentDir().parentDir().parentDir()  # repo root (codetracer/)
  let workspaceRoot = repoRoot.parentDir()
  let sibling = workspaceRoot / "codetracer-trace-format-nim" / "src"
  if dirExists(sibling):
    return sibling
  ""

proc resultsPinPath(): string =
  ## The `results >= 0.5` package path the trace-format-nim sources need (their
  ## `?` operator expands to the `.v` field that version introduced).  Mirrors
  ## `config.nims`'s `pinNewerResults`: `$CODETRACER_RESULTS_SRC` else the newest
  ## `~/.nimble/pkgs2/results-0.5*`.  Returns "" when none is found.
  let envSrc = getEnv("CODETRACER_RESULTS_SRC")
  if envSrc.len > 0 and dirExists(envSrc):
    return envSrc
  let pkgs2 = getHomeDir() / ".nimble" / "pkgs2"
  if dirExists(pkgs2):
    var best = ""
    for kind, p in walkDir(pkgs2):
      if kind == pcDir and p.lastPathPart.startsWith("results-0.5"):
        if best.len == 0 or p.lastPathPart > best.lastPathPart:
          best = p
    return best
  ""

proc zstdIncludeFlags(): seq[string] =
  ## Re-surface the zstd dev include directories out of `NIX_CFLAGS_COMPILE`
  ## (encoded as `-isystem <dir>` token pairs), mirroring `config.nims`'s zstd
  ## shim, so the trace-format-nim CTFS reader's `#include <zstd.h>` resolves.
  ## Empty outside Nix (the header then comes from the system include path).
  result = @[]
  let nixCflags = getEnv("NIX_CFLAGS_COMPILE")
  if nixCflags.len == 0:
    return
  let toks = nixCflags.splitWhitespace()
  var i = 0
  while i < toks.len:
    if toks[i] == "-isystem" and i + 1 < toks.len:
      if "zstd" in toks[i + 1]:
        result.add("--passC:-isystem " & toks[i + 1])
      i += 2
    else:
      i += 1

proc resolveCtPrintPrecedence(): string =
  ## `$CT_PRINT` (if it points at an existing file) -> `ct-print` on `PATH` ->
  ## the known `/tmp` build path (if it happens to exist).  Returns "" when none
  ## resolve.  Kept independent of `ctfs_trace.resolveCtPrint` so this module has
  ## no dependency cycle with the production reader.
  let envPath = getEnv("CT_PRINT")
  if envPath.len > 0 and fileExists(envPath):
    return envPath
  let onPath = findExe("ct-print")
  if onPath.len > 0:
    return onPath
  const known = "/tmp/ctprint_build/ct-print"
  if fileExists(known):
    return known
  ""

proc execCmd2(args: seq[string]; output: var string): int =
  ## Run `nim <args...>` WITHOUT a shell (args passed directly to the process),
  ## capturing combined stdout+stderr into `output`.  Avoids any shell-quoting
  ## of the `-p:`/`--passC:` flags or paths containing spaces.
  let p = startProcess("nim", args = args,
    options = {poStdErrToStdOut, poUsePath})
  output = p.outputStream.readAll()  # blocks until the pipe closes (process exit)
  result = p.waitForExit()
  p.close()

proc buildCtPrint(srcDir, outBin: string): Result[void, string] =
  ## Build `ct-print` from `srcDir/codetracer_ct_print.nim` into `outBin`, with
  ## the `results` pin and zstd include the ct_test build uses.  The compiled
  ## binary is byte-identical in behaviour to the dev-shell `ct-print` (same
  ## source, same `--mm:arc -d:release` flags as the package's `buildCtPrint`
  ## nimble task).
  let srcFile = srcDir / CtPrintSourceRel
  if not fileExists(srcFile):
    return err("ct-print source not found at " & srcFile)
  createDir(outBin.parentDir())
  var args = @[
    "c", "-d:release", "--mm:arc", "--hints:off", "--warnings:off",
    "-p:" & srcDir,
  ]
  let resultsPin = resultsPinPath()
  if resultsPin.len > 0:
    args.add("-p:" & resultsPin)
  for f in zstdIncludeFlags():
    args.add(f)
  args.add("-o:" & outBin)
  args.add(srcFile)
  # Invoke the compiler via the args form (no shell, so paths with spaces and
  # the `--passC:-isystem <dir>` flags survive unquoted).
  var output = ""
  let code = execCmd2(args, output)
  if code != 0:
    return err("building ct-print failed (exit " & $code & "):\n" & output)
  if not fileExists(outBin):
    return err("ct-print build reported success but produced no binary at " & outBin)
  ok()

proc ensureCtPrint*(): Result[string, string] =
  ## Resolve a usable `ct-print` for the parity test, BUILDING it from the
  ## trace-format-nim source when it is not already available.  Returns the path
  ## to a runnable `ct-print`, or an `Err` ONLY when neither a pre-built binary
  ## nor the source to build one can be found — in which case the caller SKIPS
  ## the parity check with that reason (it never silently passes, and never
  ## hard-fails on a missing `/tmp` artifact alone).
  let pre = resolveCtPrintPrecedence()
  if pre.len > 0:
    return ok(pre)
  let srcDir = traceFormatNimSrcDir()
  if srcDir.len == 0:
    return err("ct-print is not available and its source " &
      "(codetracer-trace-format-nim) could not be located; set $CT_PRINT or " &
      "$CODETRACER_TRACE_FORMAT_NIM_SRC")
  # Build into a stable per-user temp dir so repeat test runs reuse it.
  let outBin = getTempDir() / "m1_ctprint_build" / "ct-print"
  if fileExists(outBin):
    return ok(outBin)
  let buildRes = buildCtPrint(srcDir, outBin)
  if buildRes.isErr:
    return err(buildRes.error)
  ok(outBin)
