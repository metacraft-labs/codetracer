## ``ct trace`` post-processing subcommands.
##
## P7.1 adds user-facing ``ct trace extract-gfx`` and
## ``ct trace export --portable`` subcommands that forward to the
## internal recorder binary (``ct-mcr``).  The book sweep referenced
## in P7.1 replaces every direct ``ct-mcr`` invocation with the
## corresponding ``ct trace ...`` call, so the user surface stays
## minimal and the recorder binary stays an implementation detail.
##
## The discovery logic is the same one used by ``mcr_enrichment.nim``
## for upload-time enrichment: env var → sibling-of-ct → PATH.

import std/[ osproc ]

import ../online_sharing/mcr_enrichment

proc ctMcrOrError(): string =
  ## Locate ``ct-mcr`` or return "" — callers print a guidance line.
  findCtMcrBinary()

proc traceExtractGfxCommand*(tracePath: string, outputDir: string): int =
  ## ``ct trace extract-gfx -o <out-dir> <trace>``.  Forwards to
  ## ``ct-mcr extract-gfx``.  Returns the child's exit code so the
  ## caller can ``quit()`` with it directly.
  if tracePath.len == 0:
    echo "error: ct trace extract-gfx requires a trace path"
    return 1
  if outputDir.len == 0:
    echo "error: ct trace extract-gfx requires -o <output-dir>"
    return 1

  let ctMcr = ctMcrOrError()
  if ctMcr.len == 0:
    echo "error: ct-mcr binary not found."
    echo "  Set CODETRACER_CT_MCR_CMD to its absolute path, "
    echo "  drop it next to ct, or install it on PATH."
    return 1

  let args = @["extract-gfx", "-o", outputDir, tracePath]
  let process = startProcess(
    ctMcr,
    args = args,
    options = {poParentStreams, poUsePath})
  return waitForExit(process)

proc traceExportCommand*(
    tracePath: string,
    output: string,
    portable: bool): int =
  ## ``ct trace export --portable -o <out.ct> <trace>``.  Today the
  ## only supported export shape is ``--portable``; the dispatcher
  ## rejects an export call without it so the user is not silently
  ## handed a no-op.  Forwards to ``ct-mcr export``.
  if tracePath.len == 0:
    echo "error: ct trace export requires a trace path"
    return 1
  if output.len == 0:
    echo "error: ct trace export requires -o <output>"
    return 1
  if not portable:
    echo "error: ct trace export currently requires --portable."
    echo "  Non-portable export shapes will be added in a future change."
    return 1

  let ctMcr = ctMcrOrError()
  if ctMcr.len == 0:
    echo "error: ct-mcr binary not found."
    echo "  Set CODETRACER_CT_MCR_CMD to its absolute path, "
    echo "  drop it next to ct, or install it on PATH."
    return 1

  let args = @["export", "--portable", "-o", output, tracePath]
  let process = startProcess(
    ctMcr,
    args = args,
    options = {poParentStreams, poUsePath})
  return waitForExit(process)
