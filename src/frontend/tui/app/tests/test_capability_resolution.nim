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
const ExpectedAssertions = 244

const
  LandedThroughMilestone = 12
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
    # milestone that owns them, not as "unknown option".
    var namedCount = 0
    for (option, owner) in PlannedOptions:
      let refused = parseTuiCommand([option, "/tmp"])
      ck refused.kind == tckUsageError
      ck refused.message.contains(option)
      ck refused.message.contains(owner)
      inc namedCount
    checkpoint("published-but-unbuilt options refused by name: " & $namedCount)
    ck namedCount == PlannedOptions.len
    # FOUR, NOT SIX. Two options left the list for DIFFERENT reasons, and the
    # literal here is what makes each a decision rather than a drift:
    # `--headless` is built, and `--serve` was CUT — `ct host` already serves a
    # trace together with the replay front end, so a browser-hosted terminal
    # emulator duplicated it with a worse UI.
    ck namedCount == 4
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

  test "no PlannedOptions owner credits a milestone that cannot deliver it":
    # THE STALE-LABEL RULE. `PlannedOptions` is a promise about work somebody
    # still owes; an owner naming a milestone that has already LANDED — or one
    # that was CUT — is a promise nobody is going to keep, and it reads to a
    # user as "this was supposed to be done".
    #
    # Two entries carried exactly that defect and both are fixed: `--headless`
    # said "CTUI-12, the launcher and packaging milestone" long after CTUI-12
    # shipped (and CTUI-12's Deliverables never named it), and `--goto` said
    # "the flag is CTUI-12's entrypoint work". The rule is what keeps them
    # fixed.
    #
    # Mechanical rather than a list of forbidden strings: every `CTUI-<n>`
    # token in an owner must name a milestone that has NOT landed and was NOT
    # cut. An owner may name none at all, which is how `--theme` records a
    # finding without claiming somebody owes the work.
    var milestoneTokens = 0
    for (option, owner) in PlannedOptions:
      checkpoint(option & " is owed by: " & owner)
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
        inc milestoneTokens
        let n = parseInt(digits)
        checkpoint("  names CTUI-" & $n & "; landed through CTUI-" &
                   $LandedThroughMilestone & "; cut: " & $CutMilestones)
        ck n > LandedThroughMilestone
        ck n notin CutMilestones
    # THE FLOOR: at least one entry really does name a milestone, so the sweep
    # above is not vacuously true of a list whose owners lost their labels.
    checkpoint("milestone tokens found: " & $milestoneTokens)
    ck milestoneTokens >= 3

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
