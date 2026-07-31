## MCR trace detection, portable enrichment, and pre-split slice detection
## for upload.
##
## Before uploading, MCR traces (stored in the CTFS container format) need
## to be enriched with binaries and debug symbols via `ct-mcr export --portable`.
## This module provides:
##
## - CTFS magic detection (5-byte header: C0 DE 72 AC E2)
## - ct-mcr binary discovery (env var, sibling, PATH)
## - Enrichment subprocess invocation
## - Pre-split slice detection (findSlicesDir, hasPreSplitSlices, countSlices)
##
## The detection intentionally avoids importing any ct_replayer or ct_recorder
## modules — those live in the codetracer-native-recorder repo. We rely solely
## on the 5-byte CTFS magic header to identify MCR traces.

import
  std/[os, osproc, strutils, strformat],
  ../trace/trace_container

# CTFS magic detection and container lookup used to be duplicated here.
# There is now a single implementation in ``trace/trace_container`` —
# the module that owns "what shape is this recording folder?" — and this
# module re-exports it so existing callers (and
# ``test_mcr_enrichment.nim``) keep their import surface.
export CtfsMagic, hasCtfsMagic, findCtFileInFolder

proc findCtMcrBinary*(): string =
  ## Locate the ct-mcr binary. Search order:
  ##   1. $CODETRACER_CT_MCR_CMD environment variable
  ##   2. Sibling of the running ct binary (same directory)
  ##   3. Anywhere on $PATH (via `which`)
  ##
  ## Returns the absolute path, or "" if not found.
  let envCmd = getEnv("CODETRACER_CT_MCR_CMD")
  if envCmd.len > 0 and fileExists(envCmd):
    return envCmd

  let siblingPath = getAppDir() / "ct-mcr"
  if fileExists(siblingPath):
    return siblingPath

  # Fall back to PATH lookup.
  let (output, exitCode) = execCmdEx("which ct-mcr")
  if exitCode == 0:
    let resolved = output.strip()
    if resolved.len > 0 and fileExists(resolved):
      return resolved

  return ""

proc findSlicesDir*(outputFolder: string): string =
  ## Find a pre-split slices directory within the output folder.
  ##
  ## When `ct-mcr record --split` is used, the trace output contains both
  ## the original .ct file and a companion `<name>_slices/` directory with
  ## individual slice .ct files and a manifest. This proc locates that
  ## directory by looking for any `.ct` file whose name + "_slices" is an
  ## existing subdirectory containing at least one `.ct` slice.
  ##
  ## Returns the absolute path to the slices directory, or "" if not found.
  if not dirExists(outputFolder):
    return ""
  for kind, path in walkDir(outputFolder):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".ct"):
      # Derive the expected slices directory name: trace.ct → trace.ct_slices/
      let slicesDir = path & "_slices"
      if dirExists(slicesDir):
        # Verify it actually contains .ct slice files (not just an empty dir).
        var hasSlice = false
        for sKind, sPath in walkDir(slicesDir):
          if sKind in {pcFile, pcLinkToFile} and sPath.endsWith(".ct"):
            hasSlice = true
            break
        if hasSlice:
          return slicesDir
  return ""

proc hasPreSplitSlices*(outputFolder: string): bool =
  ## Check if the trace output directory contains a _slices/ subdirectory
  ## with .ct slice files. This indicates client-side splitting was done
  ## during recording (via `ct-mcr record --split`).
  findSlicesDir(outputFolder).len > 0

proc countSlices*(slicesDir: string): int =
  ## Count the number of .ct slice files in a slices directory.
  ## Returns 0 if the directory does not exist or contains no .ct files.
  if not dirExists(slicesDir):
    return 0
  for kind, path in walkDir(slicesDir):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".ct"):
      result.inc

proc enrichMcrTraceIfNeeded*(outputFolder: string, noPortable: bool = false): bool =
  ## If `outputFolder` contains an MCR trace (.ct file with CTFS magic), run
  ## `ct-mcr export --portable` to add binaries and debug symbols in-place.
  ##
  ## Returns true if enrichment was performed successfully.
  ##
  ## When `noPortable` is true, enrichment is skipped unconditionally
  ## (for users who want to upload a lightweight trace).
  ##
  ## If ct-mcr is not installed, the function prints a warning and returns
  ## false — the upload continues with the non-enriched trace.
  if noPortable:
    return false

  let ctFilePath = findCtFileInFolder(outputFolder)
  if ctFilePath.len == 0:
    # No CTFS .ct file found — not an MCR trace, nothing to enrich.
    return false

  let ctMcr = findCtMcrBinary()
  if ctMcr.len == 0:
    echo "WARNING: MCR trace detected but ct-mcr binary not found."
    echo "  The trace will be uploaded without portable binaries/symbols."
    echo "  Install ct-mcr or set CODETRACER_CT_MCR_CMD to enable enrichment."
    return false

  # Run ct-mcr export --portable in-place. The --portable flag causes ct-mcr
  # to read the .ct, resolve referenced binaries from the local system, and
  # write them back into the same .ct container.
  #
  # Usage: ct-mcr export --portable -o <output.ct> <input.ct>
  # We write to a temp file first, then replace the original to avoid
  # corrupting the trace on failure.
  let enrichedPath = ctFilePath & ".portable"
  let cmd = fmt"{ctMcr.quoteShell} export --portable -o {enrichedPath.quoteShell} {ctFilePath.quoteShell}"
  let (output, exitCode) = execCmdEx(cmd)

  if exitCode != 0:
    echo "WARNING: ct-mcr export --portable failed (exit code " & $exitCode & ")."
    echo "  Output: " & output.strip()
    echo "  The trace will be uploaded without portable binaries/symbols."
    # Clean up the partial output, if any.
    if fileExists(enrichedPath):
      try: removeFile(enrichedPath)
      except OSError: discard
    return false

  # Replace the original .ct with the enriched version.
  try:
    moveFile(enrichedPath, ctFilePath)
  except OSError as e:
    echo "WARNING: failed to replace trace with enriched version: " & e.msg
    if fileExists(enrichedPath):
      try: removeFile(enrichedPath)
      except OSError: discard
    return false

  return true
