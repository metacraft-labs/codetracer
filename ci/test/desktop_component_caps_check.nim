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

proc matchKind(buf: CapBuffer, cmd, ext: string,
               noextFallback = false): MatchKind =
  ## Thin wrapper keeping the `cstring` views alive across the call.
  ##
  ## `noextFallback` is pass 2 of routing rule NTR-R1: the launcher
  ## decides it from a level-global pre-pass (`classifySuffix`), so a
  ## caller that wants the R1a/R1c behaviour has to say so explicitly.
  let c = cmd
  let e = ext
  matches(buf, c.cstring, c.len, e.cstring, e.len, noextFallback)

proc suffixClass(buf: CapBuffer, ext: string): SuffixClass =
  let e = ext
  classifySuffix(buf, e.cstring, e.len, result)

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
                     "project", "licensed", "requires", "known-extensions"]:
        continue
      inc commandLines
      if tokens.len == 1:
        expect(matchKind(buf, keyword, "") == mkUnqualified,
          "`" & keyword & "` (no extensions) routes as an unqualified match")
      else:
        for ext in tokens[1 .. ^1]:
          if ext == "noext":
            # NTR-R1's reserved routing token, not an extension. Assert
            # its REAL semantics rather than the byte equality a literal
            # `matches(cmd, "noext")` would satisfy by accident:
            #   R1a  no suffix at all + the fallback -> mkExtension
            #   R1c  an unknown suffix + the fallback -> mkExtension
            #   without the fallback both stay mkNone.
            expect(matchKind(buf, keyword, "", noextFallback = true) ==
                     mkExtension,
              "`" & keyword & " noext` routes an argument with NO suffix " &
              "(rule NTR-R1 case R1a)")
            expect(matchKind(buf, keyword, ".unheard-of-suffix",
                             noextFallback = true) == mkExtension,
              "`" & keyword & " noext` routes an argument whose suffix is " &
              "declared by nobody and known by nobody (rule NTR-R1 case R1c)")
            expect(matchKind(buf, keyword, "", noextFallback = false) ==
                     mkNone,
              "`" & keyword & " noext` does NOT route when the level scan " &
              "did not license the fallback — the token is inert on its own")
          else:
            expect(matchKind(buf, keyword, ext) == mkExtension,
              "`" & keyword & " " & ext & "` routes as an extension match")

    expect(commandLines > 0,
      "capability file declares at least one routable command")

    # Negative: a file type the component never claimed must not route here.
    # `.this-extension-is-not-declared` cannot appear in any real declaration.
    expect(matchKind(buf, "record", ".this-extension-is-not-declared") == mkNone,
      "an undeclared extension does not match `record`")

    # --- NTR-R1: `known-extensions` is a classifier, never a router --------
    let knownLine = block:
      var found: seq[string] = @[]
      for rawLine in readFile(capsPath).splitLines():
        let tokens = rawLine.strip().splitWhitespace()
        if tokens.len >= 2 and tokens[0] == "known-extensions":
          found = tokens[1 .. ^1]
      found
    expect(knownLine.len > 0,
      "capability file declares a non-empty `known-extensions` line " &
      "(rule NTR-R1 case R1d)")
    for ext in knownLine:
      let cls = suffixClass(buf, ext)
      expect(cls.known and not cls.declared,
        "`" & ext & "` classifies as KNOWN-but-not-declared, so the level " &
        "scan withholds the `noext` fallback and it keeps reaching the " &
        "registry-suggestion path (rule NTR-R1 case R1d)")
      expect(matchKind(buf, "record", ext, noextFallback = false) == mkNone,
        "`record " & ext & "` does not route (case R1d) — this is the " &
        "property that rules out a bare `record` line")
    expect(matchKind(buf, "known-extensions", knownLine[0]) == mkNone,
      "`known-extensions` is not itself a routable command: " &
      "`ct known-extensions " & knownLine[0] & "` matches nothing")

    # A declared extension classifies the other way round.
    let declaredCls = suffixClass(buf, ".py")
    expect(declaredCls.declared and not declaredCls.known,
      "`.py` classifies as DECLARED-but-not-known (rule NTR-R1 case R1b)")
    let unknownCls = suffixClass(buf, ".unheard-of-suffix")
    expect(not unknownCls.declared and not unknownCls.known,
      "an unheard-of suffix classifies as neither — which is exactly the " &
      "licence rule NTR-R1 case R1c needs")

    echo "PASS: ", checks, " capability-parser assertions"
    quit 0
  except CheckError as e:
    stderr.writeLine ""
    stderr.writeLine "FAIL: " & e.msg
    quit 1
