## test_caps_file_shape.nim — CTUI-12, Tier 1.
##
## ## What this suite establishes
##
## CTUI-12: "the shipped `.caps` file is parsed by the launcher's own parser and
## yields the declared commands, extension and magic. A test that re-parses the
## file itself would pass while the launcher rejected it."
##
## So the subject is `packaging/codetracer-tui.caps` — the file
## `scripts/build-tui-component.sh` copies byte-for-byte into a component
## bundle — and the parser is `codetracer-launcher/src/caps.nim`, imported
## across the workspace and called directly. Nothing in this file interprets a
## capability line. The only thing it does with the bytes itself is COPY them
## into a `CapBuffer`, which is what `launcher.nim`'s `readCapFile` does before
## handing them to exactly these procedures; every question about what those
## bytes MEAN is asked of `caps.matches`, `caps.findBin` and
## `caps.classifySuffix`.
##
## ## THE THREE THINGS §6.1 GOT WRONG, PINNED RATHER THAN REMEMBERED
##
## `CodeTracer-TUI.md` §6.1 illustrates the declaration as
##
##     version 1 / name codetracer-tui / description … / bin bin/codetracer-tui
##     cmd tui / cmd ct-tui / extension .ct / match-magic CTFS / priority 100
##
## and `caps.nim` has no `cmd`, `extension`, `match-magic` or `priority`
## keyword at all: a command line IS `<command> [.ext ...]`, and an
## unrecognised first token is read as a COMMAND NAME rather than skipped
## (`matches` compares the first token against the command being routed and
## only `known-extensions` is excluded). The block is therefore not a
## capability file with cosmetic differences — it declares different commands
## from the ones it means to.
##
## This suite does not take that on trust and does not hand-copy the block
## either. `docs/tui-testing.md` rule 6: **an expected value must not be
## produced by the code under test, and where the subject is a published table,
## read the publication.** So the §6.1 block is lifted out of
## `codetracer-specs/Front-Ends/CodeTracer-TUI.md` AT RUN TIME, loaded into a
## second `CapBuffer`, and put through the SAME parser. The three findings are
## then assertions rather than prose:
##
##   * `bin bin/codetracer-tui` yields the name `bin/codetracer-tui`, which
##     `launcher.nim` joins onto `<component>/bin/` — so the binary it would
##     execv is `<component>/bin/bin/codetracer-tui`, and it does not exist.
##   * `cmd tui` declares a command called `cmd` whose extension list is
##     `{tui, ct-tui}`. Neither token can ever match an extracted extension
##     (`launcher.lastDot` guarantees every one begins with `.`), so `cmd` is
##     declared AND unroutable — and the block declares no `tui` at all.
##   * `extension .ct` declares a routable command called `extension`:
##     `ct extension foo.ct` matches it. That is the one line of the block that
##     routes, and it routes the wrong word.
##
## `match-magic CTFS` and `priority 100` are CUT, and the reason is in the same
## place: each would OCCUPY a command name, and content sniffing does not exist
## anywhere in the launcher (no `magic` in `caps.nim`, `launcher.nim` or
## `CodeTracer-Launcher.md`), while ranking is already directory-level (project
## > user > $CODETRACER_COMPONENTS_PATH > system > distro) crossed with match
## strength (extension > project marker > unqualified), in
## `launcher.scanLevelForCommand`. Adding either to a `--os:standalone
## --mm:none` binary that is already over its 50 KB cap, to serve a routing
## question `.ct` and `noext` already answer, is not a trade this milestone
## takes.
##
## ## HOW THE CUT IS PINNED, AND WHY THE ROUTING SWEEP CANNOT DO IT
##
## Stated exactly, because the obvious answer is wrong. The routing sweep
## ("§6.1's keywords declare NO command in the shipped file") does NOT catch
## somebody writing `match-magic CTFS` or `priority 100` into the shipped file:
## `caps.matches` reads them as command lines, but their token lists (`CTFS`,
## `100`) begin with no `.` and are not `noext`, so every arm still answers
## `mkNone` and the sweep stays green. That is measured in the case below by
## appending both lines to the shipped bytes in memory and re-running the
## parser on them.
##
## The cut is therefore pinned LEXICALLY — no line of the shipped file may
## begin with one of §6.1's keywords — because what the two lines cost is the
## command NAME, which is a property of the bytes rather than of a routing
## outcome. `firstTokens` is the only place this file looks at a capability
## line itself, and it looks as weakly as possible: which word starts the line,
## nothing about what the line means.
##
## ## THE POSITIVE HALF
##
## Every negative above has a twin through the same code path on the shipped
## file — `docs/tui-testing.md` rule 4 — and the twins are the routing contract
## itself: `tui` and `ct-tui` each match `.ct`, each match the `noext` arm a
## suffix-less trace folder needs, and each REFUSE a suffix another component
## declares. The mutation arm at the end deletes the `.ct` token from the
## shipped bytes in memory and shows the `.ct` match going away, so a green run
## cannot mean "the parser returns mkExtension for everything".
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.
##
## ## Layer
##
## This file lives under `app/`, so `tests/test_tui_facade_boundary.nim` walks
## it: it may not reach `host/`, `std/osproc` or `std/posix`, and it does not.
## `std/os` is read-only file access and is what every suite in this directory
## already uses to read a published table.

import std/[os, strutils, unittest]

# THE LAUNCHER'S OWN PARSER, across the workspace. Not a copy, not a
# re-implementation: a missing `codetracer-launcher` checkout must fail the
# COMPILE, by name, exactly as an absent oracle does under rule 1 — a suite
# that quietly fell back to its own parser is the defect CTUI-12 names in its
# own deliverable text.
#
# QUOTED, and it has to be: `codetracer-launcher` contains a hyphen, which Nim
# reads as the infix `-` in an unquoted module spec (`Error: cannot open file:
# ../../../../../../codetracer - launcher / src / caps`). A string-literal spec
# resolves through the same path machinery — `tests/test_tui_facade_boundary.
# nim` documents the form and `normalizeSpec` reads it, so this import is
# visible to the layer guard rather than hidden from it.
import "../../../../../../codetracer-launcher/src/caps"

import ../cli

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 86

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  ShippedCaps = "packaging/codetracer-tui.caps"
  SpecRelative = "codetracer-specs/Front-Ends/CodeTracer-TUI.md"
  SpecAnchor = "**Capability File Location:**"
    ## The line §6.1's illustrative block follows. Anchored on the sentence
    ## rather than on a line number so an edit above it does not silently move
    ## this suite onto a different block; `specCapabilityBlock` fails by name
    ## if the anchor or the fence that follows it is gone.

  ForeignSuffix = ".py"
    ## A suffix `resources/codetracer-desktop-capabilities` declares and this
    ## component must not answer for. Used with `noextFallback = false`, which
    ## is what `launcher.cmain`'s NTR-R1 pass 1 computes when some component
    ## declares the suffix.

  SpecOnlyKeywords: array[5, string] = [
    "cmd", "extension", "match-magic", "priority", "version"]
    ## Every first token §6.1 uses that `caps.nim` does not know as metadata.
    ## The shipped file must declare none of them as a command, in either
    ## `noextFallback` arm — the sweep asserts its own comparison count against
    ## this array's length.

  MetadataKeywords: array[3, string] = ["name", "bin", "description"]
    ## The three metadata lines the shipped file DOES carry. They must not be
    ## routable either, and they are a separate list because they are present
    ## rather than absent: a parser that returned `mkNone` for everything would
    ## satisfy `SpecOnlyKeywords` for free.

proc repoRoot(): string =
  ## The codetracer checkout, located from this file rather than from the
  ## working directory — a lane may run from anywhere.
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

proc specPath(): string =
  ## `codetracer-specs` as a workspace sibling. A missing checkout raises with
  ## the path it wanted: rule 1 applies to an absent oracle exactly as it does
  ## to an absent grammar archive.
  let candidate = repoRoot().parentDir / SpecRelative
  if not fileExists(candidate):
    raise newException(IOError,
      "the published specification is not checked out at " & candidate &
      " — `repro ws enable codetracer` brings the sibling in")
  candidate

proc loadBuffer(bytes: string): CapBuffer =
  ## Copy `bytes` into the launcher's fixed buffer. THE ONLY THING THIS FILE
  ## DOES WITH THE BYTES ITSELF, and it is a copy: `launcher.readCapFile` does
  ## the same and then calls the same procedures. Oversize is a caller error
  ## here because every call site asserts the length first.
  doAssert bytes.len <= CAP_BUFFER_BYTES,
    "capability text is " & $bytes.len & " bytes, over CAP_BUFFER_BYTES (" &
    $CAP_BUFFER_BYTES & "); the launcher would REFUSE the file, not truncate it"
  result.len = bytes.len
  for i in 0 ..< bytes.len:
    result.data[i] = bytes[i]

proc specCapabilityBlock(text: string): string =
  ## The fenced block §6.1 shows, lifted out of the published markdown.
  let anchor = text.find(SpecAnchor)
  if anchor < 0:
    raise newException(ValueError,
      "the anchor '" & SpecAnchor & "' is gone from " & SpecRelative &
      "; §6.1 has been restructured and this suite must be re-aimed")
  let fenceOpen = text.find("```text", anchor)
  if fenceOpen < 0:
    raise newException(ValueError,
      "no ```text fence follows '" & SpecAnchor & "' in " & SpecRelative)
  let bodyStart = text.find('\n', fenceOpen) + 1
  let fenceClose = text.find("```", bodyStart)
  if fenceClose < 0:
    raise newException(ValueError,
      "the ```text fence after '" & SpecAnchor & "' is not closed in " &
      SpecRelative)
  text[bodyStart ..< fenceClose]

proc firstTokens(text: string): seq[string] =
  ## The first whitespace-separated token of every non-blank, non-comment line.
  ##
  ## THE ONE PLACE THIS FILE LOOKS AT A CAPABILITY LINE ITSELF, and it is
  ## deliberately the weakest possible look: "which word starts this line",
  ## nothing about what the line MEANS. `caps.matches` answers every question
  ## about meaning. Why it is needed at all is argued in the case that uses it.
  result = @[]
  for raw in text.splitLines():
    let line = strutils.strip(raw)
    if line.len == 0 or line[0] == '#': continue
    let parts = line.splitWhitespace()
    if parts.len > 0:
      result.add parts[0]

proc binName(buf: CapBuffer): string =
  ## `caps.findBin`'s answer as a string. The parsing is the launcher's; this
  ## turns its `(array, len)` into something `check` can print.
  var raw: array[CAP_NAME_BYTES, char]
  let n = findBin(buf, raw)
  result = newString(n)
  for i in 0 ..< n:
    result[i] = raw[i]

template matchOf(buf: CapBuffer; cmd, ext: string; noextFallback: bool): MatchKind =
  ## `caps.matches` with Nim strings. A template rather than a proc only for
  ## symmetry with the `check`-reaching helpers below; it calls no `check`
  ## itself.
  matches(buf, cmd.cstring, cmd.len, ext.cstring, ext.len, noextFallback)

var shipped: CapBuffer
var shippedText = ""
var specText = ""
var specBlock: CapBuffer

suite "CTUI-12 Tier 1: the shipped capability file, through the launcher's parser":

  test "the shipped file exists and fits the launcher's parse buffer":
    # FIRST AND SEPARATELY. `launcher.readCapFile` REFUSES a file larger than
    # CAP_BUFFER_BYTES and drops the whole component — it does not truncate —
    # so a file that grew past 4096 bytes would make every routing assertion
    # below meaningless while `ct tui` reported the ordinary "no component
    # handles 'tui'". CAP_BUFFER_BYTES is imported, never spelled.
    let path = repoRoot() / ShippedCaps
    checkpoint("shipped capability file: " & path)
    ck fileExists(path)
    shippedText = readFile(path)
    checkpoint("size: " & $shippedText.len & " of " & $CAP_BUFFER_BYTES &
               " bytes (headroom " & $(CAP_BUFFER_BYTES - shippedText.len) & ")")
    ck shippedText.len > 0
    ck shippedText.len <= CAP_BUFFER_BYTES
    shipped = loadBuffer(shippedText)
    ck shipped.len == shippedText.len

  test "`bin` names the binary, as a BARE name the launcher can join":
    # `launcher.fillCandPaths` builds `<level>/<name@ver>` + "/bin/" + <token>.
    # A token containing a separator therefore resolves one directory too deep,
    # which is exactly what §6.1's `bin bin/codetracer-tui` does — asserted
    # from the specification itself further down.
    let name = binName(shipped)
    checkpoint("bin -> '" & name & "'")
    ck name == TuiProgramName
    ck not name.contains('/')
    ck not name.contains('\\')

  test "both declared commands route a `.ct` argument":
    # THE ROUTING CONTRACT, positive half. `noextFallback = false` is what
    # `launcher.cmain` passes once NTR-R1 pass 1 has seen `.ct` declared — by
    # this very file — so this is the arm a real `ct tui recording.ct` takes.
    var compared = 0
    for cmd in LauncherCommandNames:
      inc compared
      checkpoint(cmd & " .ct -> " & $matchOf(shipped, cmd, ".ct", false))
      ck matchOf(shipped, cmd, ".ct", false) == mkExtension
    # The sweep's own size, against its parameter — a loop that ran once would
    # otherwise satisfy every assertion in it.
    ck compared == LauncherCommandNames.len

  test "both declared commands route a SUFFIX-LESS trace folder":
    # THE ARM THAT ACTUALLY CARRIES REAL TRACES. A CodeTracer recording is a
    # directory (`host/native_host.traceFolderProblem`), and the fixtures this
    # repo records are directories with no suffix at all
    # (`test-logs/tui-fixtures/calc-<digest>`). `launcher.lastDot` yields no
    # extension for those, `cmain` sets `noextFallback` from rule NTR-R1 case
    # R1a, and the `noext` token on each command line is what answers.
    var compared = 0
    for cmd in LauncherCommandNames:
      inc compared
      checkpoint(cmd & " <noext> -> " & $matchOf(shipped, cmd, "", true))
      ck matchOf(shipped, cmd, "", true) == mkExtension
    ck compared == LauncherCommandNames.len

  test "neither declared command answers for a suffix another component owns":
    # THE NEGATIVE TWIN of the two cases above, through the same procedure.
    # Without it, `noext` would be indistinguishable from an unqualified
    # declaration, which WOULD swallow `ct tui foo.py` on an install that has
    # the desktop component beside this one.
    var compared = 0
    for cmd in LauncherCommandNames:
      inc compared
      checkpoint(cmd & " " & ForeignSuffix & " -> " &
                 $matchOf(shipped, cmd, ForeignSuffix, false))
      ck matchOf(shipped, cmd, ForeignSuffix, false) == mkNone
    ck compared == LauncherCommandNames.len

  test "`.ct` is DECLARED and not merely KNOWN":
    # `caps.classifySuffix` is NTR-R1 pass 1, and the two flags mean different
    # things: `declared` says a command line lists the suffix (case R1b, the
    # suffix routes), `known` says a `known-extensions` line does (case R1d,
    # the suffix is recognised and deliberately unroutable). Asserting both
    # separates "the TUI handles .ct" from "somebody has heard of .ct".
    var cls: SuffixClass
    classifySuffix(shipped, ".ct".cstring, 3, cls)
    checkpoint("`.ct` declared=" & $cls.declared & " known=" & $cls.known)
    ck cls.declared
    ck not cls.known
    # A suffix this component says nothing about, through the same call.
    var foreign: SuffixClass
    classifySuffix(shipped, ForeignSuffix.cstring, ForeignSuffix.len, foreign)
    ck not foreign.declared
    ck not foreign.known

  test "§6.1's keywords declare NO command in the shipped file":
    # THE CUT, MADE CHECKABLE. `match-magic` and `priority` are cut and
    # `cmd`/`extension`/`version` are spelling errors; all five would become
    # PHANTOM COMMANDS if written, because `caps.matches` reads an unknown
    # first token as a command name. Both `noextFallback` arms, because the
    # fallback is what decides whether a bare token can match.
    var compared = 0
    for keyword in SpecOnlyKeywords:
      inc compared
      ck matchOf(shipped, keyword, ".ct", false) == mkNone
      ck matchOf(shipped, keyword, "", true) == mkNone
    ck compared == SpecOnlyKeywords.len

  test "the CUT keywords are absent as FIRST TOKENS, which is what pins the cut":
    # THE CASE ABOVE DOES NOT PIN THE CUT, AND THIS ONE DOES. That was measured
    # here rather than assumed, and the measurement is the second half of this
    # case: append `match-magic CTFS` and `priority 100` to the shipped bytes
    # in memory and put them back through `caps.matches`, and every arm of the
    # sweep above still answers `mkNone`. It has to: those lines ARE read as
    # command lines, but their token lists (`CTFS`, `100`) begin with no '.'
    # and are not `noext`, so nothing can ever match them. A routing assertion
    # therefore cannot see them arrive.
    #
    # What they DO cost is the command NAME — `caps.matches` compares the first
    # token of every line against the command being routed, so once the line
    # exists the name is spoken for, and a real `ct priority …` could not be
    # added later without colliding with a component that declares it for
    # nothing. A name is a lexical property of the file, not a routing outcome,
    # so it is asserted lexically. This is the only place `firstTokens` is
    # used, and the positive half below is what keeps it honest: the same scan
    # must FIND the tokens the file really carries, or "absent" is free.
    let tokens = firstTokens(shippedText)
    checkpoint("first tokens: " & tokens.join(" "))
    ck tokens.len > 0
    var compared = 0
    for keyword in SpecOnlyKeywords:
      inc compared
      ck keyword notin tokens
    ck compared == SpecOnlyKeywords.len
    # THE POSITIVE HALF, through the same scan.
    var present = 0
    for keyword in MetadataKeywords:
      inc present
      ck keyword in tokens
    ck present == MetadataKeywords.len
    for cmd in LauncherCommandNames:
      ck cmd in tokens
    # MUTATION: the bytes the cut forbids, added in memory. The scan sees them…
    let withCut = shippedText & "\nmatch-magic CTFS\npriority 100\n"
    let cutTokens = firstTokens(withCut)
    ck "match-magic" in cutTokens
    ck "priority" in cutTokens
    # …and `caps.matches` does not, which is the whole reason this case exists.
    let mutated = loadBuffer(withCut)
    ck matchOf(mutated, "match-magic", ".ct", false) == mkNone
    ck matchOf(mutated, "match-magic", "", true) == mkNone
    ck matchOf(mutated, "priority", ".ct", false) == mkNone
    ck matchOf(mutated, "priority", "", true) == mkNone

  test "the metadata lines the file DOES carry are not routable either":
    # The positive-presence twin of the case above: `name`, `bin` and
    # `description` are real lines in the shipped bytes, so a parser that had
    # stopped reading the file would satisfy the previous case and fail this
    # one only if `matches` treated them as commands. It must not — for `.ct`
    # they carry no matching token, and for the `noext` arm they carry tokens
    # that are not `noext`.
    var compared = 0
    for keyword in MetadataKeywords:
      inc compared
      ck matchOf(shipped, keyword, ".ct", false) == mkNone
      ck matchOf(shipped, keyword, "", true) == mkNone
    ck compared == MetadataKeywords.len

  test "MUTATION: deleting `.ct` from the shipped bytes stops `.ct` matching":
    # A comparison that cannot be made to fail is indistinguishable from one
    # that is not reading the file (`docs/tui-testing.md` rule 5). The
    # mutation is in memory only — the file on disk is never written.
    ck shippedText.contains("tui .ct noext")
    let mutated = loadBuffer(shippedText.replace("tui .ct noext", "tui noext"))
    checkpoint("mutated: tui .ct -> " & $matchOf(mutated, "tui", ".ct", false))
    # Both declared lines carry the token, so the replacement hits `ct-tui`
    # too; assert on `tui`, which is the one the milestone's gate uses.
    ck matchOf(mutated, "tui", ".ct", false) == mkNone
    # …and the `noext` arm SURVIVES, so the mutation removed one token rather
    # than breaking the parse.
    ck matchOf(mutated, "tui", "", true) == mkExtension
    # The unmutated buffer is unchanged by all of this.
    ck matchOf(shipped, "tui", ".ct", false) == mkExtension

suite "CTUI-12 Tier 1: what §6.1's own block does when the launcher parses it":

  test "the published block is readable and is a capability file at all":
    # THE POSITIVE CONTROL for every assertion in this suite: if the block
    # could not be located or the parser found nothing in it, `mkNone`
    # everywhere below would be free.
    let path = specPath()
    checkpoint("specification: " & path)
    specText = readFile(path)
    ck specText.len > 0
    let block61 = specCapabilityBlock(specText)
    checkpoint("§6.1 block (" & $block61.len & " bytes):\n" & block61)
    ck block61.len > 0
    ck block61.contains("match-magic")
    ck block61.contains("priority")
    specBlock = loadBuffer(block61)
    # The parser DOES read it — it finds a `bin` line. That is the control.
    ck binName(specBlock).len > 0

  test "§6.1's `bin` line resolves one directory too deep":
    let name = binName(specBlock)
    checkpoint("§6.1 bin -> '" & name & "'")
    ck name == "bin/codetracer-tui"
    ck name.contains('/')
    # `launcher.fillCandPaths` joins `<component>` + "/bin/" + this token, so
    # the path it would execv is spelled out here rather than described.
    let wouldExec = "<component>/bin/" & name
    checkpoint("launcher would execv: " & wouldExec)
    ck wouldExec == "<component>/bin/bin/codetracer-tui"
    # And the shipped file does NOT have this shape.
    ck binName(shipped) != name

  test "§6.1 declares NEITHER `tui` NOR `ct-tui`":
    # The whole point of the file, absent from the illustration of it.
    var compared = 0
    for cmd in LauncherCommandNames:
      inc compared
      checkpoint("§6.1: " & cmd & " .ct -> " & $matchOf(specBlock, cmd, ".ct", false) &
                 ", <noext> -> " & $matchOf(specBlock, cmd, "", true))
      ck matchOf(specBlock, cmd, ".ct", false) == mkNone
      ck matchOf(specBlock, cmd, "", true) == mkNone
    ck compared == LauncherCommandNames.len

  test "§6.1 declares `cmd` — a command that can never route":
    # `cmd tui` / `cmd ct-tui` give the command `cmd` the extension list
    # {tui, ct-tui}. Every extension `launcher.lastDot` extracts begins with
    # '.', and neither token does, so nothing can match it; `noext` is not in
    # the list either. Declared, and unroutable.
    ck matchOf(specBlock, "cmd", ".ct", false) == mkNone
    ck matchOf(specBlock, "cmd", ".tui", false) == mkNone
    ck matchOf(specBlock, "cmd", "", true) == mkNone

  test "§6.1's `extension .ct` declares a routable command called `extension`":
    # THE ONE LINE OF THE BLOCK THAT ROUTES, and it routes the wrong word:
    # `ct extension foo.ct` would exec the component.
    checkpoint("§6.1: extension .ct -> " &
               $matchOf(specBlock, "extension", ".ct", false))
    ck matchOf(specBlock, "extension", ".ct", false) == mkExtension
    # The shipped file, through the same call, does not.
    ck matchOf(shipped, "extension", ".ct", false) == mkNone

  test "§6.1's `match-magic` and `priority` are commands, not directives":
    # Written into a real capability file they are read as COMMAND NAMES
    # rather than skipped, which is why both are CUT rather than carried
    # through as harmless decoration. What that costs is measured here rather
    # than asserted louder than the evidence: their token lists (`CTFS`,
    # `100`) carry no leading '.' and no `noext`, so like `cmd` they are
    # declared and UNROUTABLE — nothing can reach them, and the damage is a
    # command name occupied for nothing. `extension .ct` above is the one line
    # of the block that does route, and it is the one that would misdirect an
    # argument.
    ck matchOf(specBlock, "match-magic", ".ct", false) == mkNone
    ck matchOf(specBlock, "match-magic", "", true) == mkNone
    ck matchOf(specBlock, "priority", ".ct", false) == mkNone
    ck matchOf(specBlock, "priority", "", true) == mkNone
    # Nothing anywhere in the launcher reads file CONTENT, so `match-magic`
    # has no implementation to bind to even in principle. Asserted where the
    # evidence is: the parser has no such keyword and `classifySuffix` refuses
    # a token that does not begin with '.'.
    var cls: SuffixClass
    classifySuffix(specBlock, "CTFS".cstring, 4, cls)
    ck not cls.declared
    ck not cls.known

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
