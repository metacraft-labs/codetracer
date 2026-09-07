## test_capability_resolution.nim — CTUI-11, Tier 1.
##
## ## What this suite establishes
##
## CTUI-11: "a table over environment combinations (`COLORTERM=truecolor`,
## `TERM=xterm-256color`, `TERM=dumb`, non-UTF-8 `LANG`) crossed with the flags,
## asserting the resolved tier. Pure resolution logic, tested as such." And its
## verification gate: "every environment/flag combination resolves to the
## documented tier."
##
## Both, plus the two things that make them mean something:
##
##   * **The flag arm is asserted SEPARATELY from the tier.** `TERM=dumb` and
##     `--no-color` both resolve to `cdMonochrome`, so a table that checked only
##     the tier would pass on a resolver that had stopped reading the flags
##     entirely. Every row therefore asserts `colorsFrom` as well, and the
##     `csFlag` rows are the ones that would go red.
##   * **§6.3 IS READ, not paraphrased.** The DEC 2026 terminal list and both
##     box-drawing glyph sets are lifted out of
##     `codetracer-specs/Front-Ends/CodeTracer-TUI.md` at run time and compared
##     with what `app/theme/capabilities.nim` and `app/views/borders.nim`
##     publish. A hand-copied list here would have been written from the same
##     reading that produced the implementation, and the two would agree about a
##     misreading — `docs/tui-testing.md` rule 6.
##
## ## Why the environment is a VALUE and not the process's
##
## `resolveCapabilities` takes a `TerminalEnv`. Nothing in this file calls
## `getEnv`, `putEnv` or `isatty`, and nothing has to: the whole cross product
## below is 26 constructed values. That is the split CTUI-11 asks for —
## `host/capabilities.nim` reads the environment once and this decides what it
## means — and it is what lets the sweep be exhaustive instead of being however
## many environments a test process can safely mutate.
##
## The other half, "what a REAL terminal was told", is
## `tests/real_terminal/test_real_capability_negotiation.nim`. In-process tests
## can only ask the app what it believes it decided.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[os, strutils, tables, unittest]

import ../cli
import ../theme/capabilities
import ../views/borders

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 362

const
  LandedThroughMilestone = 14
    ## The highest CTUI milestone that has LANDED. Bump it when the next one
    ## does — the stale-label check below is what makes a rotten
    ## `PlannedOptions` owner visible, and it can only do that if this number is
    ## current.

  CutMilestones = [13]
    ## Milestones that were WITHDRAWN rather than delivered. CTUI-13 would have
    ## served the TUI session to a browser over `isonim-tui-serve`; it was cut
    ## because `ct host` already serves a trace together with the replay front
    ## end. A cut milestone owes a flag exactly as little as a landed one does,
    ## so it is barred from an owner string for the same reason — and it needs
    ## its own list because `n > LandedThroughMilestone` would happily accept
    ## it.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

# ---------------------------------------------------------------------------
# The published document
# ---------------------------------------------------------------------------

proc specPath(): string =
  ## `codetracer-specs/Front-Ends/CodeTracer-TUI.md`, located from THIS FILE
  ## rather than from the working directory — the lane runner's cwd is the repo
  ## root today and a resolver that depended on that would break the first time
  ## someone ran the binary by hand.
  var dir = currentSourcePath().parentDir
  while true:
    let candidate = dir.parentDir / "codetracer-specs" / "Front-Ends" /
                    "CodeTracer-TUI.md"
    if fileExists(candidate):
      return candidate
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  ""

proc sectionText(document, heading: string): string =
  ## The text of one `### N.M` section, from its heading to the next one.
  var collecting = false
  for line in document.splitLines():
    if line.startsWith("### "):
      if collecting:
        break
      collecting = line.contains(heading)
      continue
    if collecting:
      result.add line & "\n"

proc publishedOptions(section: string): seq[string] =
  ## Every option NAME §6.2's `Options:` block publishes, in order.
  ##
  ## The block is fixed-width text, one option per line, and an option line is
  ## the only kind that begins with whitespace and then a `-`. A line may carry
  ## two spellings (`-h, --help`), and a name may carry its argument
  ## (`--theme=<name>`); both are split here so what comes out is exactly what a
  ## user would type as `argv[i]` up to the `=`.
  ##
  ## STOPS AT THE FIRST NON-OPTION LINE after the block, so §6.2's prose and
  ## `Usage:`/`Arguments:` headers cannot contribute a token.
  result = @[]
  var inOptions = false
  for rawLine in section.splitLines():
    let line = strutils.strip(rawLine, leading = false)
    if strutils.strip(line) == "Options:":
      inOptions = true
      continue
    if not inOptions:
      continue
    if strutils.strip(line).len == 0:
      continue
    if not (line.len > 0 and line[0] == ' '):
      # The fenced block ended, or the prose after it began.
      break
    let body = strutils.strip(line)
    if body.len == 0 or body[0] != '-':
      continue
    # `-h, --help        show …` -> the leading run of comma-separated tokens.
    let head = body.split({' ', '\t'})[0 .. min(2, body.split({' ', '\t'}).high)]
    for piece in head:
      for token in piece.split(','):
        let name = strutils.strip(token)
        if name.len < 2 or name[0] != '-':
          continue
        let cut = name.find('=')
        result.add(if cut > 0: name[0 ..< cut] else: name)

proc milestoneTokensIn(owner: string): seq[int] =
  ## Every `CTUI-<n>` a `PlannedOptions` owner string names, in order.
  ##
  ## EXTRACTED FROM THE CASE THAT USED TO INLINE IT, because CTUI-14 emptied
  ## `PlannedOptions` and a rule that can only be exercised over a non-empty
  ## list is a rule that stops being checked the moment the list is empty. As a
  ## function it can be run over fabricated owners, which is what gives the
  ## stale-label rule arms that actually redden.
  result = @[]
  var i = 0
  while true:
    let at = owner.find("CTUI-", i)
    if at < 0:
      break
    var digits = ""
    var j = at + len("CTUI-")
    while j < owner.len and owner[j].isDigit:
      digits.add owner[j]
      inc j
    i = j
    if digits.len == 0:
      continue
    result.add parseInt(digits)

proc backtickedRunes(text: string): seq[string] =
  ## Every single-glyph `` `x` `` in `text`, in order and without repeats.
  ##
  ## §6.3 writes both glyph sets as inline code spans, so this is what turns the
  ## published sentence into a set a test can compare against.
  result = @[]
  var i = 0
  while i < text.len:
    if text[i] == '`':
      let close = text.find('`', i + 1)
      if close < 0:
        break
      let inner = text[i + 1 ..< close]
      # ONE GLYPH ONLY. §6.3's spans also hold `--ascii-borders`, `LC_ALL` and
      # `\e[?2026h`; a rune is at most four bytes in UTF-8 and never contains a
      # space or a backslash.
      #
      # A BARE `-` IS A GLYPH AND `--ascii-borders` IS NOT, which is why the
      # hyphen test is on the LENGTH rather than on the character: the first
      # spelling of this filter excluded anything containing a hyphen and
      # silently dropped one of §6.3's own five ASCII characters, leaving the
      # comparison below asserting four of five and passing.
      if inner.len in 1 .. 4 and not inner.contains(' ') and
         not inner.contains('\\') and
         (inner.len == 1 or not inner.contains('-')):
        if inner notin result:
          result.add inner
      i = close + 1
    else:
      inc i

const
  SpecUnicodeGlyphs = ["┌", "─", "│", "└", "▼", "●"]
    ## §6.3's own Unicode list, spelled here ONLY so a missing section is
    ## reported as "the document did not contain these" rather than as an empty
    ## comparison. The assertion below is that the document contains each of
    ## them AND that `borders.nim` can spell each of them — the document is
    ## still the oracle.
  SpecAsciiGlyphs = ["+", "-", "|", "*", ">"]
  SpecSyncTerminals = ["Kitty", "iTerm2", "WezTerm", "Alacritty", "Foot"]

proc unicodeSetOf(bs: BorderSet): seq[string] =
  @[bs.topLeft, bs.topRight, bs.bottomLeft, bs.bottomRight, bs.horizontal,
    bs.vertical, bs.teeLeft, bs.teeRight, bs.teeTop, bs.teeBottom, bs.cross,
    bs.breakpoint, bs.breakpointDisabled, bs.tracepoint, bs.collapsed,
    bs.expanded, bs.needle, bs.span, bs.ellipsis, bs.dotFill, bs.dashFill]

proc syncTerminalKnown(name: string): bool =
  ## Whether the capability resolver recognises a terminal §6.3 names, by ANY
  ## of the two identities a terminal has. `TERM_PROGRAM` for the ones that set
  ## it and `TERM` for the ones that do not, which is exactly the split §6.3's
  ## five names fall into.
  let lowered = name.toLowerAscii()
  for program in SynchronizedOutputPrograms:
    if program.toLowerAscii().contains(lowered) or
       lowered.contains(program.toLowerAscii().replace(".app", "")):
      return true
  for term in SynchronizedOutputTerms:
    if term.contains(lowered) or lowered.contains(term):
      return true
  false

# ---------------------------------------------------------------------------
# The cross product
# ---------------------------------------------------------------------------

type
  ResolutionCase = object
    ## One row of CTUI-11's table.
    name: string
    clause: string
      ## The §6.3 sentence this row comes from, quoted in the checkpoint so a
      ## failure names the rule rather than the row number.
    env: TerminalEnv
    flags: CapabilityFlags
    colors: ColorDepth
    colorsFrom: CapabilitySource
    borders: BorderMode
    mouse: bool
    sync: bool

proc rowsOf(): seq[ResolutionCase] =
  ## Every environment/flag combination the gate names, plus the ones that make
  ## the flag arms falsifiable.
  ##
  ## The UTF-8 rows are deliberately in three spellings — `en_US.UTF-8`,
  ## `C.utf8`, and a bare `UTF-8` — because a container image sets the third and
  ## a comparison that knew only the first would put a perfectly capable
  ## terminal on the ASCII fallback.
  let noFlags = initCapabilityFlags()
  result = @[
    ResolutionCase(
      name: "COLORTERM=truecolor on xterm",
      clause: "§6.3.1 probes for COLORTERM=truecolor -> 24-bit RGB",
      env: initTerminalEnv(term = "xterm", colorterm = "truecolor",
                           lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdTrueColor, colorsFrom: csEnvironment,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "COLORTERM=24bit on xterm-256color",
      clause: "§6.3.1 probes for COLORTERM=24bit -> 24-bit RGB",
      env: initTerminalEnv(term = "xterm-256color", colorterm = "24bit",
                           lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdTrueColor, colorsFrom: csEnvironment,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "TERM=xterm-256color alone",
      clause: "§6.3.1 tput colors >= 256 -> the 256-colour palette",
      env: initTerminalEnv(term = "xterm-256color", lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdAnsi256, colorsFrom: csEnvironment,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "TERM=screen-256color alone",
      clause: "§6.3.1 tput colors >= 256 -> the 256-colour palette",
      env: initTerminalEnv(term = "screen-256color", lang = "C.utf8"),
      flags: noFlags, colors: cdAnsi256, colorsFrom: csEnvironment,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "TERM=xterm-direct is 24-bit",
      clause: "§6.3.1 24-bit RGB; terminfo's *-direct entries are the 24-bit ones",
      env: initTerminalEnv(term = "xterm-direct", lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdTrueColor, colorsFrom: csEnvironment,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "TERM=xterm alone falls back to 16",
      clause: "§6.3.1 fallback to 16 ANSI colors -> basic ANSI styling",
      env: initTerminalEnv(term = "xterm", lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdAnsi16, colorsFrom: csDefault,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "TERM=vt100 falls back to 16",
      clause: "§6.3.1 fallback to 16 ANSI colors -> basic ANSI styling",
      env: initTerminalEnv(term = "vt100", lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdAnsi16, colorsFrom: csDefault,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "TERM=dumb is monochrome, ASCII and mouseless",
      clause: "§6.3.1 TERM=dumb -> monochrome styling with bold and underline",
      env: initTerminalEnv(term = "dumb", lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdMonochrome, colorsFrom: csEnvironment,
      borders: bmAscii, mouse: false, sync: false),
    ResolutionCase(
      name: "no TERM at all reads as dumb",
      clause: "§6.3.1 TERM=dumb; an unset TERM claims no capability either",
      env: initTerminalEnv(term = "", lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdMonochrome, colorsFrom: csEnvironment,
      borders: bmAscii, mouse: false, sync: false),
    ResolutionCase(
      name: "not a tty at all",
      clause: "§6.3 probes a terminal; a pipe is not one",
      env: initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                           lang = "en_US.UTF-8", isTty = false),
      flags: noFlags, colors: cdMonochrome, colorsFrom: csEnvironment,
      borders: bmAscii, mouse: false, sync: false),
    ResolutionCase(
      name: "non-UTF-8 LANG gives ASCII borders",
      clause: "§6.3.2 detects a UTF-8 locale; fallback renders ASCII borders",
      env: initTerminalEnv(term = "xterm-256color", lang = "en_US.ISO-8859-1"),
      flags: noFlags, colors: cdAnsi256, colorsFrom: csEnvironment,
      borders: bmAscii, mouse: true, sync: false),
    ResolutionCase(
      name: "LANG=C gives ASCII borders",
      clause: "§6.3.2 fallback (non-UTF-8): renders clean ASCII borders",
      env: initTerminalEnv(term = "xterm-256color", lang = "C"),
      flags: noFlags, colors: cdAnsi256, colorsFrom: csEnvironment,
      borders: bmAscii, mouse: true, sync: false),
    ResolutionCase(
      name: "LC_ALL beats a non-UTF-8 LANG",
      clause: "§6.3.2 detects LC_ALL / LANG containing UTF-8; POSIX orders them",
      env: initTerminalEnv(term = "xterm-256color", lcAll = "en_GB.UTF-8",
                           lang = "C"),
      flags: noFlags, colors: cdAnsi256, colorsFrom: csEnvironment,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "LC_CTYPE sits between LC_ALL and LANG",
      clause: "§6.3.2 detects a UTF-8 locale; LC_CTYPE is the character-type one",
      env: initTerminalEnv(term = "xterm-256color", lcCtype = "UTF-8",
                           lang = "C"),
      flags: noFlags, colors: cdAnsi256, colorsFrom: csEnvironment,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "an empty LC_ALL does not shadow LANG",
      clause: "§6.3.2 detects a UTF-8 locale; an unset variable is not a veto",
      env: initTerminalEnv(term = "xterm-256color", lcAll = "",
                           lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdAnsi256, colorsFrom: csEnvironment,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "NO_COLOR is honoured",
      clause: "https://no-color.org — present and non-empty disables colour",
      env: initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                           lang = "en_US.UTF-8", noColor = "1"),
      flags: noFlags, colors: cdMonochrome, colorsFrom: csEnvironment,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "an EMPTY NO_COLOR is not a request",
      clause: "https://no-color.org — the variable must be non-empty",
      env: initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                           lang = "en_US.UTF-8", noColor = ""),
      flags: noFlags, colors: cdTrueColor, colorsFrom: csEnvironment,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "TERM_PROGRAM=WezTerm advertises DEC 2026",
      clause: "§6.3.3 emits DEC 2026 on Kitty, iTerm2, WezTerm, Alacritty, Foot",
      env: initTerminalEnv(term = "xterm-256color", termProgram = "WezTerm",
                           lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdTrueColor, colorsFrom: csEnvironment,
      borders: bmUnicode, mouse: true, sync: true),
    ResolutionCase(
      name: "TERM=xterm-kitty advertises DEC 2026",
      clause: "§6.3.3 emits DEC 2026 on Kitty",
      env: initTerminalEnv(term = "xterm-kitty", lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdAnsi16, colorsFrom: csDefault,
      borders: bmUnicode, mouse: true, sync: true),
    ResolutionCase(
      name: "TERM=foot advertises DEC 2026",
      clause: "§6.3.3 emits DEC 2026 on Foot",
      env: initTerminalEnv(term = "foot", lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdAnsi16, colorsFrom: csDefault,
      borders: bmUnicode, mouse: true, sync: true),
    ResolutionCase(
      name: "TERM=alacritty advertises DEC 2026",
      clause: "§6.3.3 emits DEC 2026 on Alacritty",
      env: initTerminalEnv(term = "alacritty", lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdAnsi16, colorsFrom: csDefault,
      borders: bmUnicode, mouse: true, sync: true),
    ResolutionCase(
      name: "TERM=xterm does NOT advertise DEC 2026",
      clause: "§6.3.3 names five terminals; xterm is not one of them",
      env: initTerminalEnv(term = "xterm", lang = "en_US.UTF-8"),
      flags: noFlags, colors: cdAnsi16, colorsFrom: csDefault,
      borders: bmUnicode, mouse: true, sync: false),

    # ---- THE FLAGS. Each one against an environment that says the opposite,
    # which is the only arrangement under which "an explicit flag beats a
    # probe" is a claim and not a coincidence.
    ResolutionCase(
      name: "--no-color beats COLORTERM=truecolor",
      clause: "§6.2 --no-color: disable ANSI color styling (monochrome mode)",
      env: initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                           lang = "en_US.UTF-8"),
      flags: initCapabilityFlags(noColor = true),
      colors: cdMonochrome, colorsFrom: csFlag,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "--truecolor beats TERM=dumb",
      clause: "§6.2 --truecolor: force 24-bit TrueColor (override probing)",
      env: initTerminalEnv(term = "dumb", lang = "en_US.UTF-8"),
      flags: initCapabilityFlags(forceTrueColor = true),
      colors: cdTrueColor, colorsFrom: csFlag,
      borders: bmAscii, mouse: false, sync: false),
    ResolutionCase(
      name: "--truecolor beats NO_COLOR",
      clause: "§6.2 --truecolor overrides terminal probing",
      env: initTerminalEnv(term = "xterm", lang = "en_US.UTF-8", noColor = "1"),
      flags: initCapabilityFlags(forceTrueColor = true),
      colors: cdTrueColor, colorsFrom: csFlag,
      borders: bmUnicode, mouse: true, sync: false),
    ResolutionCase(
      name: "--ascii-borders beats a UTF-8 locale",
      clause: "§6.2 --ascii-borders: use plain ASCII characters",
      env: initTerminalEnv(term = "xterm-256color", lang = "en_US.UTF-8"),
      flags: initCapabilityFlags(asciiBorders = true),
      colors: cdAnsi256, colorsFrom: csEnvironment,
      borders: bmAscii, mouse: true, sync: false),
    ResolutionCase(
      name: "--no-mouse on a capable terminal",
      clause: "§6.2 --no-mouse: disable mouse tracking",
      env: initTerminalEnv(term = "xterm-256color", lang = "en_US.UTF-8"),
      flags: initCapabilityFlags(noMouse = true),
      colors: cdAnsi256, colorsFrom: csEnvironment,
      borders: bmUnicode, mouse: false, sync: false),
    ResolutionCase(
      name: "--ascii-borders --no-color together, the Tier-2 gate's pair",
      clause: "CTUI-11 gate: the ASCII/monochrome screen carries no colour",
      env: initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                           lang = "en_US.UTF-8"),
      flags: initCapabilityFlags(noColor = true, asciiBorders = true),
      colors: cdMonochrome, colorsFrom: csFlag,
      borders: bmAscii, mouse: true, sync: false)]

const
  ExpectedCaseCount = 28
    ## Asserted against `rowsOf().len` below. A sweep whose size nobody checks
    ## is a sweep that can lose a row in a merge and stay green — the
    ## "comparison counts against their parameters" rule.
  ChecksPerCase = 4
    ## `colors`, `colorsFrom`, `borders` and `mouse` per row. `sync` is counted
    ## separately because it has its own case.

# ---------------------------------------------------------------------------

suite "CTUI-11 Tier 1: capability resolution":

  test "every environment/flag combination resolves to the documented tier":
    let rows = rowsOf()
    checkpoint("cases: " & $rows.len)
    ck rows.len == ExpectedCaseCount
    var compared = 0
    for row in rows:
      let caps = resolveCapabilities(row.env, row.flags)
      checkpoint(row.name & " [" & row.clause & "] -> " & describe(caps))
      ck caps.colors == row.colors
      ck caps.colorsFrom == row.colorsFrom
      ck caps.borders == row.borders
      ck caps.mouse == row.mouse
      compared += ChecksPerCase
    # THE COMPARISON COUNT AGAINST ITS PARAMETER. A loop that skipped a row —
    # or a `rowsOf` that returned early — leaves this number short, and the
    # assertion above about `rows.len` cannot see that.
    checkpoint("comparisons: " & $compared)
    ck compared == ExpectedCaseCount * ChecksPerCase

  test "synchronized output resolves per §6.3.3's five terminals":
    let rows = rowsOf()
    var compared = 0
    var advertised = 0
    for row in rows:
      let caps = resolveCapabilities(row.env, row.flags)
      ck caps.synchronizedOutput == row.sync
      inc compared
      if row.sync:
        inc advertised
    # THE POSITIVE FLOOR. `synchronizedOutput == false` for every row is what a
    # resolver that had lost the whole feature would produce, and it would
    # satisfy a table whose rows all expected `false`.
    checkpoint("rows advertising DEC 2026: " & $advertised)
    ck advertised == 4
    ck compared == ExpectedCaseCount

  test "the Kitty keyboard protocol is DETECTED and never negotiated":
    # CTUI-11's own decision, asserted as one. Enabling the protocol would
    # change every key's encoding to `CSI <unicode> ; <mods> u` and
    # `app/input/keymap.keyName` decodes xterm's classic encoding — so the
    # capability is resolved, and `host/terminal_driver.start` sends nothing for
    # it. The second half is asserted from the terminal's side in
    # `tests/real_terminal/test_real_capability_negotiation.nim`; this is the
    # first half.
    let kitty = resolveCapabilities(
      initTerminalEnv(term = "xterm-kitty", lang = "en_US.UTF-8"),
      initCapabilityFlags())
    ck kitty.kittyKeyboard
    let ghostty = resolveCapabilities(
      initTerminalEnv(term = "xterm-256color", termProgram = "ghostty",
                      lang = "en_US.UTF-8"),
      initCapabilityFlags())
    ck ghostty.kittyKeyboard
    let plain = resolveCapabilities(
      initTerminalEnv(term = "xterm-256color", lang = "en_US.UTF-8"),
      initCapabilityFlags())
    ck not plain.kittyKeyboard
    let dumb = resolveCapabilities(
      initTerminalEnv(term = "dumb", lang = "en_US.UTF-8"),
      initCapabilityFlags())
    ck not dumb.kittyKeyboard

  test "the resolved set is ONE value, and it names why each axis resolved":
    # CTUI-11's first contract. `describe` is what a user and a failure message
    # both read, so it must carry the SOURCE and not only the tier — otherwise
    # "why is my screen monochrome?" is answerable only by re-deriving the
    # decision from an environment the reader cannot see.
    let flagged = resolveCapabilities(
      initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                      lang = "en_US.UTF-8"),
      initCapabilityFlags(noColor = true, asciiBorders = true))
    let text = describe(flagged)
    checkpoint(text)
    ck text.contains("colors=monochrome(flag)")
    ck text.contains("borders=ascii(flag)")
    ck text.contains("mouse=on(default)")
    ck text.contains("sync2026=off(default)")
    ck text.contains("kitty-keyboard=no(never enabled)")
    # …and the environment-driven spelling differs, so the two sources are
    # genuinely distinguishable in the text rather than both reading "flag".
    let probed = resolveCapabilities(
      initTerminalEnv(term = "dumb", lang = "C"), initCapabilityFlags())
    let probedText = describe(probed)
    checkpoint(probedText)
    ck probedText.contains("colors=monochrome(environment)")
    ck probedText.contains("borders=ascii(environment)")

  test "the CLI parses §6.2's four capability flags, and refuses the rest":
    # THE OTHER END OF THE SAME CONTRACT: a flag that beats a probe has to
    # arrive first. `app/cli.nim` does no I/O, so this is the whole of it.
    ck parseTuiCommand(["/tmp"]).flags == initCapabilityFlags()
    ck parseTuiCommand(["--truecolor", "/tmp"]).flags.forceTrueColor
    ck parseTuiCommand(["/tmp", "--no-color"]).flags.noColor
    ck parseTuiCommand(["--ascii-borders", "/tmp"]).flags.asciiBorders
    ck parseTuiCommand(["--no-mouse", "/tmp"]).flags.noMouse
    let both = parseTuiCommand(["--ascii-borders", "--no-mouse", "/tmp"])
    ck both.kind == tckOpenTrace
    ck both.flags.asciiBorders
    ck both.flags.noMouse
    ck not both.flags.noColor
    # CONTRADICTORY FLAGS ARE A USAGE ERROR rather than a precedence rule.
    let clash = parseTuiCommand(["--truecolor", "--no-color", "/tmp"])
    checkpoint("--truecolor --no-color -> " & $clash.kind & ": " &
               (if clash.kind == tckUsageError: clash.message else: ""))
    ck clash.kind == tckUsageError
    ck clash.message.contains("--truecolor")
    ck clash.message.contains("--no-color")
    # §6.2's published-but-unbuilt options are refused BY NAME with the
    # milestone that owns them, not as "unknown option". The list is EMPTY as
    # of CTUI-14 — see the next two cases, which is where the interesting claim
    # now lives — so this sweep is kept for the mechanism and its count is
    # asserted against the list rather than against a literal.
    var namedCount = 0
    for (option, owner) in PlannedOptions:
      let refused = parseTuiCommand([option, "/tmp"])
      ck refused.kind == tckUsageError
      ck refused.message.contains(option)
      ck refused.message.contains(owner)
      inc namedCount
    checkpoint("published-but-unbuilt options refused by name: " & $namedCount)
    ck namedCount == PlannedOptions.len
    # ZERO, AND THE NEXT CASE IS WHY THAT IS A CLAIM AND NOT AN ABSENCE. A
    # literal here used to say FOUR; it says nothing on its own now, so the
    # positive statement — every option §6.2 publishes is accepted — is made
    # against the published document instead.
    ck namedCount == 0
    # `--headless` PARSES, because it is built.
    let headless = parseTuiCommand(["--headless", "/tmp"])
    checkpoint("--headless -> " & $headless.kind)
    ck headless.kind == tckHeadless
    # `--serve` IS AN UNKNOWN OPTION, because the feature does not exist. Not a
    # `PlannedOptions` entry: parking it there would promise a user that
    # somebody still owes them the flag.
    let serve = parseTuiCommand(["--serve", "/tmp"])
    checkpoint("--serve -> " & $serve.kind & ": " &
               (if serve.kind == tckUsageError: serve.message else: ""))
    ck serve.kind == tckUsageError
    ck serve.message.contains("unknown option")
    var serveAdvertised = false
    for (option, _) in PlannedOptions:
      if option == "--serve":
        serveAdvertised = true
    ck not serveAdvertised
    ck not TuiHelpText.contains("--serve")
    # …and a genuinely unknown option still reads as one, so the arm above is a
    # classification and not a catch-all.
    let unknown = parseTuiCommand(["--wat", "/tmp"])
    ck unknown.kind == tckUsageError
    ck unknown.message.contains("unknown option")

  test "CTUI-14 parses the four options §6.2 published and this binary owed":
    # THE FLAGS THIS MILESTONE ADDS, asserted on the VALUE the parser produces
    # rather than on the absence of an error — "it did not refuse it" is
    # satisfied by a parser that accepted the spelling and threw the argument
    # away, which is precisely the shape `app/cli.nim`'s header refuses.
    let dark = parseTuiCommand(["/tmp"])
    ck dark.flags.theme == utDark
    ck dark.gotoTick == NoGotoTick
    ck dark.recordKeys.len == 0
    ck dark.replayKeys.len == 0

    var themesSeen = 0
    for theme in UiTheme:
      let long = parseTuiCommand(["--theme=" & $theme, "/tmp"])
      ck long.kind == tckOpenTrace
      ck long.flags.theme == theme
      # THE SHORT SPELLING REACHES THE SAME VALUE. §6.2 writes it
      # `-t, --theme=<name>`, so a `-t` that resolved differently would be two
      # options wearing one line of documentation.
      let short = parseTuiCommand(["-t", $theme, "/tmp"])
      ck short.kind == tckOpenTrace
      ck short.flags.theme == theme
      inc themesSeen
    checkpoint("themes parsed in both spellings: " & $themesSeen)
    ck themesSeen == ord(high(UiTheme)) + 1

    # …and a name §6.2 does not list is refused, naming the four that are.
    let badTheme = parseTuiCommand(["--theme=solarized", "/tmp"])
    checkpoint("--theme=solarized -> " & badTheme.message)
    ck badTheme.kind == tckUsageError
    ck badTheme.message.contains("solarized")
    ck badTheme.message.contains("monokai")

    # `--goto` CARRIES A TICK, and 0 is a tick.
    let goto = parseTuiCommand(["--goto=4500", "/tmp"])
    ck goto.kind == tckOpenTrace
    ck goto.gotoTick == 4500'i64
    let gotoZero = parseTuiCommand(["--goto=0", "/tmp"])
    ck gotoZero.gotoTick == 0'i64
    # …and `0` is distinguishable from "not given", which is the whole reason
    # `NoGotoTick` is -1 rather than 0.
    ck gotoZero.gotoTick != NoGotoTick
    let badGoto = parseTuiCommand(["--goto=soon", "/tmp"])
    ck badGoto.kind == tckUsageError
    ck badGoto.message.contains("soon")
    let negativeGoto = parseTuiCommand(["--goto=-1", "/tmp"])
    ck negativeGoto.kind == tckUsageError
    ck negativeGoto.message.contains("at or after 0")

    # THE JOURNAL PAIR, and the contradiction between them.
    let record = parseTuiCommand(["--record-keys=/tmp/j", "/tmp"])
    ck record.recordKeys == "/tmp/j"
    ck record.replayKeys.len == 0
    let replay = parseTuiCommand(["--replay-keys=/tmp/j", "/tmp"])
    ck replay.replayKeys == "/tmp/j"
    ck replay.recordKeys.len == 0
    let bothJournals = parseTuiCommand(
      ["--record-keys=/tmp/a", "--replay-keys=/tmp/b", "/tmp"])
    checkpoint("--record-keys + --replay-keys -> " & bothJournals.message)
    ck bothJournals.kind == tckUsageError
    ck bothJournals.message.contains("--record-keys")
    ck bothJournals.message.contains("--replay-keys")

    # `--theme=plain` IS A COLOUR DECISION and contradicts `--truecolor`, the
    # same way `--no-color` does — and it resolves to the same rung, which is
    # the fact that makes it one.
    let plainClash = parseTuiCommand(["--theme=plain", "--truecolor", "/tmp"])
    checkpoint("--theme=plain --truecolor -> " & plainClash.message)
    ck plainClash.kind == tckUsageError
    ck plainClash.message.contains("plain")
    let plainCaps = resolveCapabilities(
      initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                      lang = "en_US.UTF-8"),
      initCapabilityFlags(theme = utPlain))
    checkpoint("--theme=plain on a truecolor terminal: " & describe(plainCaps))
    ck plainCaps.colors == cdMonochrome
    ck plainCaps.colorsFrom == csFlag
    # …and the SAME terminal without it is not monochrome, so the line above is
    # a statement about the theme rather than about the environment.
    let richCaps = resolveCapabilities(
      initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                      lang = "en_US.UTF-8"), initCapabilityFlags())
    ck richCaps.colors == cdTrueColor
    ck describe(richCaps).contains("theme=dark(default)")
    ck describe(plainCaps).contains("theme=plain(flag)")

    # EVERY ONE OF THEM NEEDS A TRACE. `--goto` with nothing to seek in is a
    # command line that cannot do what it says, and it is named individually so
    # the message says which option was the problem.
    var orphanCount = 0
    for option in ["--goto=1", "--record-keys=/tmp/j", "--replay-keys=/tmp/j",
                   "--layout-binding"]:
      let orphan = parseTuiCommand([option])
      ck orphan.kind == tckUsageError
      ck orphan.message.contains("trace folder")
      inc orphanCount
    checkpoint("session options refused without a trace: " & $orphanCount)
    ck orphanCount == 4

  test "--headless refuses the two flags it cannot honour and honours the one it can":
    # THE DEFECT THIS CASE PINS. `--headless` accepted `--goto`,
    # `--record-keys` and `--replay-keys` and acted on none of them:
    # `host/headless.runHeadless` took the path, the flags and the geometry and
    # never saw the other three fields. That is "a flag that parses and then
    # does nothing" — the failure mode `app/cli.PlannedOptions`'s own header
    # names, arriving through a mode rather than through the list.
    #
    # The three are not one problem. Two of them CANNOT be honoured in a mode
    # with no input loop, and are refused by name; one of them is exactly what
    # this mode's single frame is, and is honoured.
    var refusedCount = 0
    for option in ["--record-keys=/tmp/j", "--replay-keys=/tmp/j"]:
      let clash = parseTuiCommand(["--headless", option, "/tmp"])
      checkpoint("--headless " & option & " -> " &
                 (if clash.kind == tckUsageError: clash.message else: $clash.kind))
      ck clash.kind == tckUsageError
      # THE MESSAGE NAMES BOTH SIDES of the conflict, because a user who typed
      # two flags needs to know which pair is the problem.
      ck clash.message.contains(option[0 ..< option.find('=')])
      ck clash.message.contains("--headless")
      inc refusedCount
      # …AND THE SAME FLAG WITHOUT `--headless` IS STILL ACCEPTED, so what is
      # being asserted is the COMBINATION rather than the flag.
      let alone = parseTuiCommand([option, "/tmp"])
      ck alone.kind == tckOpenTrace
    checkpoint("flags refused under --headless: " & $refusedCount)
    ck refusedCount == 2

    # …and the order does not matter: `--headless` may be written after.
    let reversed = parseTuiCommand(["--replay-keys=/tmp/j", "--headless", "/tmp"])
    ck reversed.kind == tckUsageError
    ck reversed.message.contains("--replay-keys")

    # `--goto` SURVIVES INTO THE HEADLESS COMMAND, which is the positive arm.
    # Without it, this case would pass on a parser that refused all three — and
    # refusing `--goto` would be the same defect wearing an error message.
    let headlessGoto = parseTuiCommand(["--headless", "--goto=200", "/tmp"])
    checkpoint("--headless --goto=200 -> " & $headlessGoto.kind &
               " tick " & $headlessGoto.gotoTick)
    ck headlessGoto.kind == tckHeadless
    ck headlessGoto.gotoTick == 200'i64
    # …and a plain `--headless` still carries "not given", so the field above
    # is the flag's value rather than a default that happens to match.
    let headlessPlain = parseTuiCommand(["--headless", "/tmp"])
    ck headlessPlain.kind == tckHeadless
    ck headlessPlain.gotoTick == NoGotoTick
    # A BAD TICK IS STILL A BAD TICK under `--headless`, so the validation the
    # tty path gets is not skipped for the mode.
    let headlessBadGoto = parseTuiCommand(["--headless", "--goto=soon", "/tmp"])
    ck headlessBadGoto.kind == tckUsageError
    ck headlessBadGoto.message.contains("soon")

  test "PLAT-6's --layout-binding parses, is off by default, and is refused where it cannot act":
    # THE OPT-IN, AS A VALUE. The flag is what turns PLAT-6's layout binding on
    # in a shipped binary (`main.nim` calls `runtime.enableLayoutBinding` behind
    # it), so what has to be asserted here is that it reaches the parsed command
    # rather than that it "did not produce an error" — the failure mode
    # `app/cli.nim`'s header names is a flag that parses and is thrown away.
    let off = parseTuiCommand(["/tmp"])
    ck off.kind == tckOpenTrace
    ck not off.layoutBinding
    let on = parseTuiCommand(["--layout-binding", "/tmp"])
    checkpoint("--layout-binding -> " & $on.kind & " layoutBinding=" &
               $on.layoutBinding)
    ck on.kind == tckOpenTrace
    ck on.layoutBinding
    # Order does not matter, and it is idempotent.
    ck parseTuiCommand(["/tmp", "--layout-binding"]).layoutBinding
    ck parseTuiCommand(["--layout-binding", "--layout-binding",
                        "/tmp"]).layoutBinding
    # IT IS PUBLISHED, so the §6.2 oracle below is reading a document that
    # describes this parser rather than an older one.
    ck TuiHelpText.contains("--layout-binding")
    # AND IT IS REFUSED WHERE IT CANNOT ACT. `--headless` renders one settled
    # screen and exits, so there is no `:` prompt to rearrange anything from —
    # the same rule the two journal flags are refused under, and named the same
    # way, on both sides of the conflict.
    let headlessClash = parseTuiCommand(["--headless", "--layout-binding",
                                         "/tmp"])
    checkpoint("--headless --layout-binding -> " & headlessClash.message)
    ck headlessClash.kind == tckUsageError
    ck headlessClash.message.contains("--layout-binding")
    ck headlessClash.message.contains("--headless")
    ck parseTuiCommand(["--layout-binding", "--headless",
                        "/tmp"]).kind == tckUsageError
    # THE POSITIVE TWIN, through the same parser: `--headless` alone is still a
    # headless command, so the refusal above is about the COMBINATION.
    ck parseTuiCommand(["--headless", "/tmp"]).kind == tckHeadless

  test "every option §6.2 publishes is accepted, read from the document":
    # THE ORACLE, and the reason `PlannedOptions` being empty is a claim rather
    # than an absence. §6.2 is a published table of twelve option lines; this
    # reads the option NAMES out of the document and asserts that the shipped
    # parser refuses none of them — neither as "unknown option" nor as "not
    # built yet".
    #
    # Rule 6 of `docs/tui-testing.md`: where the subject is a published table,
    # read the publication. A hand-copied list here would have been written
    # from the same reading that produced the parser.
    let path = specPath()
    if path.len == 0:
      checkpoint("codetracer-specs/Front-Ends/CodeTracer-TUI.md was not found" &
                 " from " & currentSourcePath() &
                 " — check out the codetracer-specs sibling")
    ck path.len > 0
    let section = sectionText(readFile(path), "6.2 CLI Arguments and Options")
    checkpoint("§6.2 is " & $section.splitLines().len & " lines")
    ck section.len > 0
    ck section.contains("Options:")

    let options = publishedOptions(section)
    checkpoint("options published in §6.2: " & options.join(" "))
    # THE NON-VACUITY FLOOR. An extractor that matched nothing would satisfy
    # every acceptance check below for free. Fifteen tokens over twelve lines:
    # `-h/--help`, `-v/--version` and `-t/--theme` are each written as a pair,
    # and PLAT-6 added `--layout-binding`.
    ck options.len == 15
    ck "--layout-binding" in options

    var accepted = 0
    for option in options:
      let parsed = parseTuiCommand([option, "/tmp"])
      let message = if parsed.kind == tckUsageError: parsed.message else: ""
      if message.contains("unknown option") or message.contains("not built"):
        checkpoint("§6.2 PUBLISHES AN OPTION THIS BINARY REFUSES: " & option &
                   " -> " & message)
      ck not message.contains("unknown option")
      ck not message.contains("not built")
      inc accepted
    checkpoint("published options the parser accepts: " & $accepted)
    ck accepted == options.len

    # THE POSITIVE TWIN, through the same predicate: an option §6.2 does NOT
    # publish really is reported as unknown, so the sweep above is a
    # measurement rather than a `not contains` over a haystack that never
    # contains anything.
    let absent = parseTuiCommand(["--not-in-the-spec", "/tmp"])
    ck absent.kind == tckUsageError
    ck absent.message.contains("unknown option")
    ck "--not-in-the-spec" notin options

  test "the stale-label rule still reddens, on a list that is now empty":
    # THE STALE-LABEL RULE. `PlannedOptions` is a promise about work somebody
    # still owes; an owner naming a milestone that has already LANDED — or one
    # that was CUT — is a promise nobody is going to keep, and it reads to a
    # user as "this was supposed to be done".
    #
    # CTUI-14 EMPTIED THE LIST, which would have made the old shape of this
    # case vacuously green: a sweep over no entries finds no bad owner. So the
    # rule is now applied to FABRICATED lists as well, and the arms that must
    # redden are the point of the case rather than a demonstration beside it.
    #
    # Mechanical rather than a list of forbidden strings: every `CTUI-<n>`
    # token in an owner must name a milestone that has NOT landed and was NOT
    # cut. An owner may name none at all, which is how an entry can record a
    # finding without claiming somebody owes the work.
    var realTokens = 0
    for (option, owner) in PlannedOptions:
      checkpoint(option & " is owed by: " & owner)
      for n in milestoneTokensIn(owner):
        inc realTokens
        checkpoint("  names CTUI-" & $n & "; landed through CTUI-" &
                   $LandedThroughMilestone & "; cut: " & $CutMilestones)
        ck n > LandedThroughMilestone
        ck n notin CutMilestones
    checkpoint("milestone tokens in the live list: " & $realTokens)
    ck realTokens == 0

    # THE ARMS THAT MUST REDDEN, through the same extractor and the same two
    # predicates the sweep above runs.
    let landedOwner = "CTUI-12, the launcher and packaging milestone"
    let landedTokens = milestoneTokensIn(landedOwner)
    ck landedTokens.len == 1
    ck landedTokens[0] == 12
    ck not (landedTokens[0] > LandedThroughMilestone)

    let cutOwner = "CTUI-13, the web bridge"
    let cutTokens = milestoneTokensIn(cutOwner)
    ck cutTokens.len == 1
    ck cutTokens[0] == 13
    ck cutTokens[0] in CutMilestones

    # …and an owner that names a milestone still to come passes BOTH, so the
    # two arms above fail for the reason they claim rather than because
    # nothing can pass.
    let futureTokens = milestoneTokensIn("CTUI-20, something later")
    ck futureTokens.len == 1
    ck futureTokens[0] > LandedThroughMilestone
    ck futureTokens[0] notin CutMilestones

    # …and an owner with no milestone at all yields no tokens rather than a
    # zero, which is what lets an entry state a finding and name nobody.
    ck milestoneTokensIn("unbuilt here; nobody owes it").len == 0
    # THE EXTRACTOR'S OWN FLOOR: two tokens in one owner are both found.
    let pair = milestoneTokensIn("CTUI-15 and CTUI-16 share it")
    ck pair.len == 2
    ck pair[0] == 15
    ck pair[1] == 16

  test "§6.3's own glyph sets and terminal list, read from the document":
    # THE ORACLE. Rule 6 of `docs/tui-testing.md`: where the subject is a
    # published table, read the publication. §6.3 writes both border sets as
    # inline code spans and names five terminals for DEC 2026.
    let path = specPath()
    if path.len == 0:
      checkpoint("codetracer-specs/Front-Ends/CodeTracer-TUI.md was not found" &
                 " from " & currentSourcePath() &
                 " — check out the codetracer-specs sibling")
    ck path.len > 0
    let section = sectionText(readFile(path), "6.3 Terminal Capabilities")
    checkpoint("§6.3 is " & $section.splitLines().len & " lines")
    ck section.len > 0
    ck section.contains("Box-Drawing Unicode Support")
    ck section.contains("Synchronized Output")

    let published = backtickedRunes(section)
    checkpoint("single-glyph code spans in §6.3: " & published.join(" "))
    # THE NON-VACUITY FLOOR. An extractor that matched nothing would satisfy
    # every "is in the published set" check below for free.
    ck published.len >= SpecUnicodeGlyphs.len + SpecAsciiGlyphs.len

    let unicodeSet = unicodeSetOf(UnicodeBorders)
    var unicodeMatched = 0
    for glyph in SpecUnicodeGlyphs:
      ck glyph in published
      ck glyph in unicodeSet
      inc unicodeMatched
    checkpoint("§6.3 Unicode glyphs covered by UnicodeBorders: " &
               $unicodeMatched)
    ck unicodeMatched == SpecUnicodeGlyphs.len

    var asciiMatched = 0
    for glyph in SpecAsciiGlyphs:
      ck glyph in published
      # EVERY ONE OF §6.3's FIVE IS REACHABLE from the Unicode set through the
      # fallback table — which is the claim that matters, because the ASCII set
      # is what a non-UTF-8 terminal is shown.
      var reachable = false
      for source, target in AsciiFallbackTable:
        if target == glyph:
          reachable = true
      ck reachable
      inc asciiMatched
    checkpoint("§6.3 ASCII glyphs reachable through AsciiFallbackTable: " &
               $asciiMatched)
    ck asciiMatched == SpecAsciiGlyphs.len

    var syncMatched = 0
    for terminal in SpecSyncTerminals:
      ck section.contains(terminal)
      ck syncTerminalKnown(terminal)
      inc syncMatched
    checkpoint("§6.3 DEC 2026 terminals recognised: " & $syncMatched)
    ck syncMatched == SpecSyncTerminals.len

  test "MUTATION ARM: a §6.3 that lost a glyph reddens the oracle":
    # A comparison that cannot be made to fail is indistinguishable from one
    # that is not reading the document. THE PUBLISHED DOCUMENT ALONE IS
    # MUTATED — in memory, so nothing on disk moves — and the extractor and the
    # comparison below are the SAME ones the case above runs.
    let path = specPath()
    ck path.len > 0
    let section = sectionText(readFile(path), "6.3 Terminal Capabilities")
    ck section.len > 0

    # 1. A glyph removed from the publication must be reported as absent.
    let withoutNeedle = section.replace("`▼`", "`v`")
    let mutatedRunes = backtickedRunes(withoutNeedle)
    checkpoint("after removing `▼` from §6.3, published set is " &
               mutatedRunes.join(" "))
    ck "▼" notin mutatedRunes
    # …and the unmutated one still has it, so the mutation is what moved.
    ck "▼" in backtickedRunes(section)

    # 2. A terminal removed from §6.3's DEC 2026 list must be reported as
    #    absent by the same `contains` the case above uses.
    let withoutFoot = section.replace("Foot", "Fooot")
    ck not withoutFoot.contains("Foot)")
    ck section.contains("Foot")

    # 3. THE ARM THAT WOULD HAVE CAUGHT A NON-READING TEST: an EMPTY document
    #    must fail the non-vacuity floor rather than pass every membership
    #    check for free.
    let empty = sectionText("# nothing here\n", "6.3 Terminal Capabilities")
    ck empty.len == 0
    ck backtickedRunes(empty).len == 0
    ck backtickedRunes(empty).len < SpecUnicodeGlyphs.len

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
