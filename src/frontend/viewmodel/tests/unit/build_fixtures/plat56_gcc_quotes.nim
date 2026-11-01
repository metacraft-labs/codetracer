## build_fixtures/plat56_gcc_quotes.nim — PLAT-56: the quotation marks this
## host's real `gcc` writes.
##
## A library the native suites import, not a suite, and apart from
## `plat56_c_build` because it starts a process: the JavaScript lane imports
## that module.
##
## GCC writes `‘name’` only where it was built with NLS and runs under a UTF-8
## locale; otherwise it writes `'name'`. Every other byte of its diagnostics
## on the PLAT-56 project is the same. The desktop's answers and the
## transcripts in `plat56_c_build` were recorded on Linux, with curly quotes.
## nixpkgs' darwin `gcc` 14.3.0 is real GCC built without NLS, so it writes
## straight quotes even under `LC_ALL=en_US.UTF-8` (measured on Darwin arm64,
## codetracer `40f689a59`, inside `repro exec .`).
##
## So a suite comparing the real compiler's words with a recorded answer reads
## the answer through `plat56LocalGccText`. It asks the compiler rather than
## `defined(macosx)`, because a Linux host under a non-UTF-8 locale writes
## straight quotes as well, and a macOS host whose `gcc` has NLS would not. A
## third answer from the compiler is a failure, never a guess: that is a
## compiler these suites have not been measured against.
##
## NO MOCK: the real `gcc` on the real PLAT-56 project.

import std/[os, osproc, strutils]

import ./plat56_c_build

const QuoteProbeCommand =
  "gcc -fdiagnostics-color=never -c src/main.c -o /dev/null"
  ## `Plat56FailCommand` without its colour, which would put escapes between
  ## the quotes and the name, and without `-Wall`, which adds nothing here.

proc gccWritesCurlyQuotes(): bool =
  ## Whether the real `gcc` of this environment writes `‘name’`.
  let project = writePlat56Project("ct-plat56-gcc-quotes-")
  defer: removeDir(project)
  let (output, _) = execCmdEx(QuoteProbeCommand, workingDir = project)
  if output.contains("‘undefined_name’"):
    true
  elif output.contains("'undefined_name'"):
    false
  else:
    raise newException(IOError,
      "gcc quoted `undefined_name` in neither way these suites know (" &
      QuoteProbeCommand & "): " & output)

var quoteProbe = ""
  ## The probe's memo: "", "curly" or "straight".

proc plat56LocalGccText*(text: string): string =
  ## `text`, recorded with GCC's curly quotes, as this host's `gcc` writes it.
  if quoteProbe.len == 0:
    quoteProbe = if gccWritesCurlyQuotes(): "curly" else: "straight"
  if quoteProbe == "curly": text
  else: text.replace("‘", "'").replace("’", "'")
