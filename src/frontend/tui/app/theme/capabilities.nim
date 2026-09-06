## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/theme/capabilities.nim — CTUI-11. What the terminal can do, as ONE value
## and as a PURE FUNCTION of the environment and the command line.
##
## ## Why the resolution lives in `app/` and the reading lives in `host/`
##
## CTUI-11's deliverable is `host/capabilities.nim`, and that file exists: it is
## what calls `isatty` and reads the seven environment variables named below.
## But the milestone also names `app/tests/test_capability_resolution.nim` and
## describes it as "a table over environment combinations crossed with the
## flags, asserting the resolved tier — pure resolution logic, tested as such",
## and `app/tests/` may not import `host/` (the facade guard walks it). Those two
## sentences only fit together one way: the DECISION is a pure function of a
## value and lives here; the READING of the process's environment is a host act
## and lives there.
##
## That split is also what makes the milestone's first contract literally true
## rather than aspirational:
##
##   * **The resolved capability set is ONE value computed ONCE, not a set of
##     scattered `getEnv` calls.** `TerminalEnv` is the whole of what is read,
##     it is read in one place, and everything downstream — the driver, the
##     style tables, the border set — is a function of the `TerminalCapabilities`
##     that came out of `resolveCapabilities`. A view that wanted to know the
##     colour depth cannot reach for `getEnv` because it is handed the answer.
##   * **An explicit flag always beats a probe.** Every axis below states its
##     flag arm first and records `csFlag` in the matching `*From` field, so
##     "why is this monochrome?" is answerable from the value rather than by
##     re-deriving the decision.
##
## ## The probes are ENVIRONMENT-ONLY, and that is a measured decision
##
## §6.3 describes colour-depth detection as "checks `tput colors` >= 256".
## `tput` is a process spawn, and CTUI-11's risk note is explicit that "a
## blocking probe fails a published gate rather than merely feeling slow" — the
## gate being cold start under 50 ms with probing enabled. So the 256-colour arm
## is decided from `TERM` (the same string `tput` itself looks up in terminfo)
## and no child process is spawned at startup. The deviation is recorded here
## rather than in a commit message because it is a difference from a published
## section.
##
## Nothing here does I/O of any kind: no `getEnv`, no file, no fd. That is what
## lets the whole table below be swept in the Tier-1 lane, and it is why
## `resolveCapabilities` takes a `TerminalEnv` instead of reading one.

import std/strutils

type
  ColorDepth* = enum
    ## §6.3's ladder, from the bottom up so `<` orders it by richness — a
    ## caller that wants "at least 256" writes `caps.colors >= cdAnsi256`
    ## rather than listing members, and a member added later cannot silently
    ## reorder the comparison.
    cdMonochrome = "monochrome"
    cdAnsi16 = "ansi16"
    cdAnsi256 = "ansi256"
    cdTrueColor = "truecolor"

  BorderMode* = enum
    ## §6.3's box-drawing fallback. Two values rather than a `unicode: bool`
    ## because the border SET is what a view asks for, and a boolean at that
    ## call site reads as "is unicode" at every one of them.
    bmUnicode = "unicode"
    bmAscii = "ascii"

  UiTheme* = enum
    ## §6.2's `-t, --theme=<name>`: "dark (default), light, plain, monokai" —
    ## CTUI-14, and the four names are the published ones rather than a set this
    ## milestone chose.
    ##
    ## THE ZERO VALUE IS THE PUBLISHED DEFAULT, which is what lets a theme axis
    ## be added to `CapabilityFlags` and `TerminalCapabilities` without moving a
    ## single existing assertion: everything that did not ask for a theme
    ## resolves to `utDark`, and `utDark`'s tables are the ones CTUI-11 shipped.
    ##
    ## A THEME IS A PALETTE AND NEVER A DISTINCTION. `app/theme/degradation.nim`
    ## states the contract that survives it: within a group of roles that are
    ## states of one thing, any two the 16-colour rung tells apart are told apart
    ## at every rung. Re-picking hues must not merge two states, and
    ## `app/tests/test_degraded_style_tables.nim` asserts that over the whole
    ## cross product of roles, depths AND themes rather than over the default
    ## one.
    utDark = "dark"
    utLight = "light"
    utPlain = "plain"
      ## NOT A PALETTE AT ALL. `plain` is the request for a screen with no
      ## colour on it, so it resolves the colour ladder to `cdMonochrome`
      ## whatever the terminal can do — which is the same rung `--no-color`
      ## reaches, by a different door and for a different reason. Weight,
      ## underline, reverse and glyph carry every state, exactly as
      ## `monochromeStyle` already lays out.
    utMonokai = "monokai"

  CapabilitySource* = enum
    ## WHY an axis resolved the way it did. Carried on the resolved value, and
    ## not decoration: the status bar and `--help`'s companion diagnostics name
    ## it, and a test that asserted only the tier would pass on a resolver that
    ## reached the right answer for the wrong reason — `TERM=dumb` and
    ## `--no-color` both produce `cdMonochrome`, and a flag that had stopped
    ## being read would be invisible in a table that checked the tier alone.
    csFlag = "flag"
    csEnvironment = "environment"
    csDefault = "default"

  TerminalEnv* = object
    ## EVERY environment variable capability resolution reads, and nothing
    ## reads one anywhere else. `host/capabilities.readTerminalEnv` is the one
    ## function that fills this in a shipped binary.
    term*: string
      ## `$TERM`.
    colorterm*: string
      ## `$COLORTERM` — `truecolor` / `24bit` per §6.3.
    termProgram*: string
      ## `$TERM_PROGRAM`. iTerm2, WezTerm, Apple_Terminal, ghostty and vscode
      ## all set it, and it is the only way to tell iTerm2 from the generic
      ## `xterm-256color` it claims as `TERM`.
    lcAll*: string
    lcCtype*: string
    lang*: string
      ## The locale triple, in POSIX precedence order: `LC_ALL` overrides
      ## `LC_CTYPE` overrides `LANG`. §6.3 names only `LC_ALL` and `LANG`;
      ## `LC_CTYPE` is between them in the standard and is what a user who set
      ## only their character type would have set.
    noColor*: string
      ## `$NO_COLOR` — https://no-color.org. Not in §6.3, and honoured anyway:
      ## it is the cross-application convention for exactly this axis, and a
      ## terminal front-end that ignored it would be the only program on the
      ## user's machine that did. The standard's rule is "present AND
      ## non-empty", which is why this is the string rather than a bool.
    isTty*: bool
      ## Whether the process is actually drawing on a terminal. False for a
      ## pipe, a CI log or `nohup`, and it floors every axis: there is nothing
      ## to negotiate with.

  CapabilityFlags* = object
    ## §6.2's four capability flags, as a value. Parsed by `app/cli.nim`, which
    ## does no I/O either.
    forceTrueColor*: bool
      ## `--truecolor`
    noColor*: bool
      ## `--no-color`
    asciiBorders*: bool
      ## `--ascii-borders`
    noMouse*: bool
      ## `--no-mouse`
    theme*: UiTheme
      ## `-t, --theme=<name>` — CTUI-14. `utDark` when the flag is absent, which
      ## is also what §6.2 publishes as the default.

  TerminalCapabilities* = object
    ## The resolved set. ONE value, computed once, before the first paint.
    colors*: ColorDepth
    borders*: BorderMode
    mouse*: bool
      ## Whether to ask the terminal for SGR-1006 mouse reporting.
    synchronizedOutput*: bool
      ## Whether to bracket each frame in DEC 2026 (`CSI ? 2026 h` …
      ## `CSI ? 2026 l`).
    kittyKeyboard*: bool
      ## Whether the terminal ADVERTISES the Kitty keyboard protocol.
      ##
      ## DETECTED AND DELIBERATELY NOT ENABLED, which is a product decision
      ## rather than an omission and is asserted as one at Tier 2. Pushing a
      ## Kitty stack frame (`CSI = 1 u`) changes every key's encoding to
      ## `CSI <unicode> ; <mods> u`, and CTUI-9's `app/input/keymap.keyName`
      ## decodes xterm's classic encoding — SS3 for F1-F4, `CSI <n> ~` for
      ## F5-F12, `CSI 1 ; <mod> <final>` for modified arrows. A driver that
      ## enabled the protocol without a decoder for it would make every
      ## function key in §4.2 unreachable on precisely the terminals users pick
      ## for their key handling. The same argument applies to xterm's
      ## `modifyOtherKeys`, which the driver also never sets.
      ##
      ## The field is resolved anyway because the decision has to be
      ## observable: `tests/real_terminal/test_real_capability_negotiation.nim`
      ## asserts that a Kitty-advertising terminal is told nothing, which is a
      ## claim about a choice and not about an absence.
    theme*: UiTheme
      ## Which palette the role tables paint in — CTUI-14.
    colorsFrom*: CapabilitySource
    bordersFrom*: CapabilitySource
    mouseFrom*: CapabilitySource
    syncFrom*: CapabilitySource
    themeFrom*: CapabilitySource

const
  TrueColorPrograms* = ["iTerm.app", "WezTerm", "ghostty", "Hyper"]
    ## `$TERM_PROGRAM` values whose terminals emit 24-bit colour whatever
    ## `TERM` claims. Apple_Terminal is deliberately absent: it is a
    ## 256-colour terminal and reports `TERM=xterm-256color` honestly.

  SynchronizedOutputPrograms* = ["iTerm.app", "WezTerm", "ghostty"]
    ## §6.3's DEC 2026 list, by `$TERM_PROGRAM`.

  SynchronizedOutputTerms* = ["xterm-kitty", "foot", "foot-extra",
                              "alacritty", "alacritty-direct", "wezterm",
                              "contour"]
    ## §6.3's DEC 2026 list, by `$TERM`. Kitty, Foot and Alacritty identify
    ## themselves this way and set no `TERM_PROGRAM`.

  KittyKeyboardTerms* = ["xterm-kitty"]
  KittyKeyboardPrograms* = ["ghostty", "WezTerm"]
    ## Terminals that advertise the Kitty keyboard protocol. See
    ## `TerminalCapabilities.kittyKeyboard` for why detecting it is the whole
    ## of what is done with it.

  DumbTerm* = "dumb"
    ## §6.3's floor: "`TERM=dumb` … uses monochrome styling with bold and
    ## underline attributes".

proc initTerminalEnv*(term = ""; colorterm = ""; termProgram = "";
                      lcAll = ""; lcCtype = ""; lang = "";
                      noColor = ""; isTty = true): TerminalEnv =
  ## A `TerminalEnv` with every field named. Written as a constructor with
  ## defaults so a test that varies one variable says which one it varied
  ## instead of listing eight positional strings.
  TerminalEnv(term: term, colorterm: colorterm, termProgram: termProgram,
              lcAll: lcAll, lcCtype: lcCtype, lang: lang, noColor: noColor,
              isTty: isTty)

proc initCapabilityFlags*(forceTrueColor = false; noColor = false;
                          asciiBorders = false; noMouse = false;
                          theme = utDark): CapabilityFlags =
  CapabilityFlags(forceTrueColor: forceTrueColor, noColor: noColor,
                  asciiBorders: asciiBorders, noMouse: noMouse, theme: theme)

proc parseTheme*(name: string): (bool, UiTheme) =
  ## `-t, --theme=<name>`'s argument, matched against the enum's own published
  ## spellings. `(false, utDark)` for a name §6.2 does not list.
  ##
  ## READ OFF THE ENUM rather than written out again, so a theme added to
  ## `UiTheme` is parseable the moment it exists and a name cannot be accepted
  ## by the parser and then be unknown to the tables.
  let wanted = name.toLowerAscii()
  for theme in UiTheme:
    if $theme == wanted:
      return (true, theme)
  (false, utDark)

proc themeNames*(): string =
  ## The four names, for a usage message. Same source as `parseTheme`.
  var parts: seq[string] = @[]
  for theme in UiTheme:
    parts.add $theme
  parts.join(", ")

proc effectiveLocale*(env: TerminalEnv): string =
  ## The locale string that decides the character set, in POSIX precedence
  ## order. Exposed because "which of the three won" is the first question a
  ## user whose borders came out ASCII will ask.
  if env.lcAll.len > 0: env.lcAll
  elif env.lcCtype.len > 0: env.lcCtype
  else: env.lang

proc isUtf8Locale*(locale: string): bool =
  ## Whether a locale string names UTF-8.
  ##
  ## Case- and separator-insensitive on purpose: `en_US.UTF-8`, `C.utf8`,
  ## `en_GB.utf-8` and the bare `UTF-8` a container image sets are all the same
  ## answer, and a comparison that knew only one spelling would put a perfectly
  ## capable terminal on the ASCII fallback.
  let lowered = locale.toLowerAscii()
  lowered.contains("utf-8") or lowered.contains("utf8")

proc isDumbTerminal*(env: TerminalEnv): bool =
  ## §6.3's `TERM=dumb`, plus the two states that are indistinguishable from it
  ## in what they can render: no `TERM` at all, and no terminal at all.
  ##
  ## An empty `TERM` is folded in deliberately. `env -i` and most container
  ## entrypoints leave it unset, and a resolver that treated "" as an unknown
  ## capable terminal would emit 16-colour SGR into something that has never
  ## claimed to understand it.
  (not env.isTty) or env.term.len == 0 or env.term == DumbTerm

proc noColorRequested*(env: TerminalEnv): bool =
  ## https://no-color.org: honoured when the variable is present AND non-empty.
  ## An empty `NO_COLOR=` is explicitly NOT a request in that standard, and it
  ## is what a shell leaves behind when a user unsets it badly.
  env.noColor.len > 0

proc resolveColorDepth(env: TerminalEnv;
                       flags: CapabilityFlags): (ColorDepth, CapabilitySource) =
  ## §6.3's colour ladder. THE FLAG ARMS COME FIRST, which is the milestone's
  ## contract: an explicit flag always beats a probe.
  ##
  ## `--truecolor` and `--no-color` together are refused by `app/cli.nim` as a
  ## usage error rather than silently ordered here — the two flags say opposite
  ## things and any precedence rule would be this module inventing an intent
  ## the user did not express.
  if flags.noColor:
    return (cdMonochrome, csFlag)
  if flags.theme == utPlain:
    # `--theme=plain` IS A REQUEST FOR NO COLOUR, and §6.2 lists it beside
    # `dark`, `light` and `monokai` as if it were one more palette. It is not:
    # there is no plain palette anywhere in `degradation.nim`, and there must
    # not be, because the thing a user asks for by that name is a screen that
    # carries its distinctions in weight and underline. It therefore resolves
    # the LADDER rather than the tables. `--theme=plain --truecolor` is refused
    # by `app/cli.nim` as a usage error, for the reason `--truecolor --no-color`
    # is: any precedence here would be this module inventing an intent.
    return (cdMonochrome, csFlag)
  if flags.forceTrueColor:
    # DELIBERATELY ABOVE the `TERM=dumb` floor. §6.2 calls it "force 24-bit
    # TrueColor mode (override terminal probing)", and a flag that lost to a
    # probe would not be an override.
    return (cdTrueColor, csFlag)
  if noColorRequested(env):
    return (cdMonochrome, csEnvironment)
  if isDumbTerminal(env):
    return (cdMonochrome, csEnvironment)
  let colorterm = env.colorterm.toLowerAscii()
  if colorterm == "truecolor" or colorterm == "24bit":
    return (cdTrueColor, csEnvironment)
  if env.termProgram in TrueColorPrograms:
    return (cdTrueColor, csEnvironment)
  let term = env.term.toLowerAscii()
  if term.contains("direct"):
    # terminfo's `*-direct` entries are the 24-bit ones (`xterm-direct`,
    # `alacritty-direct`); their `colors` capability is 16777216.
    return (cdTrueColor, csEnvironment)
  if term.contains("256color") or term.contains("256"):
    return (cdAnsi256, csEnvironment)
  # A terminal that says it is a terminal and claims nothing else. Sixteen
  # colours is what `TERM=xterm`, `TERM=vt100` and `TERM=linux` all support,
  # and it is the last rung above monochrome.
  (cdAnsi16, csDefault)

proc resolveBorders(env: TerminalEnv;
                    flags: CapabilityFlags): (BorderMode, CapabilitySource) =
  if flags.asciiBorders:
    return (bmAscii, csFlag)
  if isDumbTerminal(env):
    # Not a locale question but a rendering one: a `TERM=dumb` stream is not
    # promised to survive a three-byte glyph, and there is no screen at all
    # when `isTty` is false.
    return (bmAscii, csEnvironment)
  if isUtf8Locale(effectiveLocale(env)):
    return (bmUnicode, csEnvironment)
  (bmAscii, csDefault)

proc resolveMouse(env: TerminalEnv;
                  flags: CapabilityFlags): (bool, CapabilitySource) =
  if flags.noMouse:
    return (false, csFlag)
  if isDumbTerminal(env):
    return (false, csEnvironment)
  (true, csDefault)

proc resolveSynchronizedOutput(env: TerminalEnv):
                              (bool, CapabilitySource) =
  ## §6.3 names five terminals. There is no flag for this axis in §6.2, so
  ## there is no flag arm — and the default is OFF rather than "emit it and
  ## hope", because an unrecognised DECSET is silently ignored by a compliant
  ## terminal and echoed as text by a non-compliant one.
  if isDumbTerminal(env):
    return (false, csEnvironment)
  if env.termProgram in SynchronizedOutputPrograms:
    return (true, csEnvironment)
  if env.term.toLowerAscii() in SynchronizedOutputTerms:
    return (true, csEnvironment)
  (false, csDefault)

proc resolveKittyKeyboard(env: TerminalEnv): bool =
  if isDumbTerminal(env):
    return false
  if env.term.toLowerAscii() in KittyKeyboardTerms:
    return true
  env.termProgram in KittyKeyboardPrograms

proc resolveCapabilities*(env: TerminalEnv;
                          flags: CapabilityFlags): TerminalCapabilities =
  ## THE whole decision, as one pure function.
  ##
  ## Every axis is independent by construction — there is no shared mutable
  ## state and no ordering between the four calls — which is what makes the
  ## Tier-1 sweep a cross product rather than a sequence.
  let (colors, colorsFrom) = resolveColorDepth(env, flags)
  let (borders, bordersFrom) = resolveBorders(env, flags)
  let (mouse, mouseFrom) = resolveMouse(env, flags)
  let (sync, syncFrom) = resolveSynchronizedOutput(env)
  TerminalCapabilities(
    colors: colors, borders: borders, mouse: mouse, synchronizedOutput: sync,
    kittyKeyboard: resolveKittyKeyboard(env),
    theme: flags.theme,
    colorsFrom: colorsFrom, bordersFrom: bordersFrom, mouseFrom: mouseFrom,
    syncFrom: syncFrom,
    themeFrom: (if flags.theme == utDark: csDefault else: csFlag))

proc describe*(caps: TerminalCapabilities): string =
  ## One line naming every axis AND the source that decided it. Printed by
  ## `main.nim` when a user asks what was negotiated, and quoted in every
  ## failure message that has a capability set in scope — a report that named
  ## the tier without naming the reason leaves the reader to re-derive the
  ## decision from an environment they cannot see.
  "colors=" & $caps.colors & "(" & $caps.colorsFrom & ")" &
  " borders=" & $caps.borders & "(" & $caps.bordersFrom & ")" &
  " mouse=" & (if caps.mouse: "on" else: "off") & "(" & $caps.mouseFrom & ")" &
  " sync2026=" & (if caps.synchronizedOutput: "on" else: "off") &
  "(" & $caps.syncFrom & ")" &
  " theme=" & $caps.theme & "(" & $caps.themeFrom & ")" &
  " kitty-keyboard=" & (if caps.kittyKeyboard: "advertised" else: "no") &
  "(never enabled)"
