##
## Capability-file conformance checker for the `codetracer-desktop` bundle.
##
## WHAT THIS TESTS
##   That the `capabilities` file inside a bundle produced by
##   `scripts/build-desktop-component.sh` is actually parseable and routable
##   by **the launcher's own parser** — not by a re-implementation of the
##   grammar living in this repo. It therefore compiles against
##   `codetracer-launcher/src/caps.nim` directly (the sibling checkout) and
##   drives the same three entry points the launcher's router uses:
##   `findBin`, `declaresHelpDelegate` and `matches`.
##
##   Concretely it asserts:
##     1. the file fits the launcher's fixed 4 KiB `CapBuffer` (larger files
##        are a hard parse error for the launcher, see caps.nim's header);
##     2. `findBin` yields exactly the expected binary name — the same name
##        the bundle's `bin/` entry is called;
##     3. `declaresHelpDelegate` is true, because the desktop component is
##        the launcher's mandatory help delegate (CodeTracer-Launcher.md §2.6);
##     4. every `<cmd> .ext ...` declaration in the file round-trips: for each
##        extension listed on each command line, `matches(cmd, ext)` returns
##        `mkExtension`; for each `<cmd>` line with no extension list,
##        `matches(cmd, "")` returns `mkUnqualified`;
##     5. an extension that is NOT declared for `record` does not match —
##        the router must not fall through to the desktop component for a
##        file type it never claimed.
##
## DESIGN DOC
##   codetracer-specs/Testing/Launcher-Recorder-Compatibility-Tests.md §5.1
##   (deliverable D1), milestone LRC-0 in
##   Launcher-Recorder-Compatibility-Tests.milestones.org.
##   Grammar reference: codetracer-specs/Planned-Features/CodeTracer-Launcher.md §2.3.
##
## MOCKING POLICY (per metacraft-dev-guidelines/policies/documentation-conventions.md)
##   This checker mocks NOTHING. It links the real launcher parser source and
##   reads the real capability file out of a real bundle produced by the real
##   producer script. There is no fixture capability string, no stubbed parser
##   and no fake filesystem. The independent line scanner below is not a
##   second implementation of the grammar under test — it exists purely to
##   enumerate what the file claims so that every claim can be pushed through
##   the launcher's parser; a disagreement between the two is reported as a
##   failure rather than being papered over.
##
## USAGE
##   nim c -r --path:<launcher-repo>/src ci/test/desktop_component_caps_check.nim \
##       <bundle>/capabilities <expected-bin-name>
##

import std/[os, strutils]

import caps # codetracer-launcher/src/caps.nim, via --path

type CheckError = object of CatchableError

var checks = 0

proc expect(cond: bool, what: string) =
  inc checks
  if not cond:
    raise newException(CheckError, what)
  echo "  ok: ", what

proc loadCapBuffer(path: string): CapBuffer =
  ## Fill the launcher's fixed-size buffer exactly the way the launcher does:
  ## a single bounded read, and a hard error when the file does not fit.
  let raw = readFile(path)
  if raw.len > CAP_BUFFER_BYTES:
    raise newException(CheckError,
      "capability file is " & $raw.len & " bytes, over the launcher's " &
      $CAP_BUFFER_BYTES & "-byte CapBuffer limit (caps.nim would report a parse error)")
  for i in 0 ..< raw.len:
    result.data[i] = raw[i]
  result.len = raw.len

proc binName(buf: CapBuffer): string =
  var name: array[CAP_NAME_BYTES, char]
  let n = findBin(buf, name)
  if n <= 0:
    return ""
  result = newString(n)
  for i in 0 ..< n:
    result[i] = name[i]

proc matchKind(buf: CapBuffer, cmd, ext: string): MatchKind =
  ## Thin wrapper keeping the `cstring` views alive across the call.
  let c = cmd
  let e = ext
  matches(buf, c.cstring, c.len, e.cstring, e.len)

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    stderr.writeLine "usage: desktop_component_caps_check <capabilities-file> <expected-bin-name>"
    quit 2

  let capsPath = args[0]
  let expectedBin = args[1]

  if not fileExists(capsPath):
    stderr.writeLine "error: no capability file at " & capsPath
    quit 1

  echo "capability-file conformance (launcher parser: codetracer-launcher/src/caps.nim)"
  echo "  file: ", capsPath

  try:
    let buf = loadCapBuffer(capsPath)
    expect(buf.len > 0, "capability file is non-empty and fits the launcher's CapBuffer")

    let bin = binName(buf)
    expect(bin.len > 0, "launcher's findBin() locates a `bin` declaration")
    expect(bin == expectedBin,
      "launcher's findBin() returns '" & expectedBin & "' (got '" & bin & "')")

    expect(declaresHelpDelegate(buf),
      "capability file declares `help-delegate` (desktop is the launcher's help delegate)")

    # Enumerate the declarations the file makes, then push every one of them
    # back through the launcher's own matcher.
    var commandLines = 0
    for rawLine in readFile(capsPath).splitLines():
      let line = rawLine.strip()
      if line.len == 0 or line.startsWith("#"):
        continue
      let tokens = line.splitWhitespace()
      let keyword = tokens[0]
      # Metadata keywords are not routable commands.
      if keyword in ["name", "bin", "description", "version", "help-delegate",
                     "project", "licensed", "requires"]:
        continue
      inc commandLines
      if tokens.len == 1:
        expect(matchKind(buf, keyword, "") == mkUnqualified,
          "`" & keyword & "` (no extensions) routes as an unqualified match")
      else:
        for ext in tokens[1 .. ^1]:
          expect(matchKind(buf, keyword, ext) == mkExtension,
            "`" & keyword & " " & ext & "` routes as an extension match")

    expect(commandLines > 0,
      "capability file declares at least one routable command")

    # Negative: a file type the component never claimed must not route here.
    # `.this-extension-is-not-declared` cannot appear in any real declaration.
    expect(matchKind(buf, "record", ".this-extension-is-not-declared") == mkNone,
      "an undeclared extension does not match `record`")

    echo "PASS: ", checks, " capability-parser assertions"
    quit 0
  except CheckError as e:
    stderr.writeLine ""
    stderr.writeLine "FAIL: " & e.msg
    quit 1
