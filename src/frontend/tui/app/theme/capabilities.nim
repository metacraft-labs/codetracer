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

import ../../../../common/key_names
import ../../../../common/terminal_graphics/tiers
import ./colour_math
import ./roles
import ./terminal_profile

export terminal_profile

export key_names.KeyProtocol

export tiers.ImageTier, tiers.tierName, tiers.parseTierName, tiers.tierNames
export roles.DesignMode
export colour_math.Rgb8, colour_math.hexOf

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
    ## §6.2's `-t, --theme=<name>`. PLAT-46: a theme is a design-system COLOUR
    ## MODE, not a palette of its own — `dark` and `light` select the Dark and
    ## Light values `codetracer-design-system` publishes for every token
    ## (`$extensions.modes`), and `plain` is the request for no colour at all.
    ##
    ## `monokai` IS RETIRED (2026-09-26). The design system carries a complete
    ## syntax palette in both modes (`colors/editor/syntax/*`, Dracula /
    ## Alucard), so a second syntax theme had nothing left to provide; every
    ## token class Monokai distinguished maps to a `colors/editor/syntax/*` role
    ## or is filed as a design-system gap (see `app/theme/roles.nim`).
    ## `--theme=monokai` fails with a message naming the replacement —
    ## `RetiredThemes` below — rather than being silently ignored.
    ##
    ## THE ZERO VALUE IS THE DEFAULT, `dark`, and when no `--theme` is given the
    ## mode is DETECTED from the terminal's actual background (OSC 11, then
    ## `COLORFGBG`) — `CapabilityFlags.themePinned` says which.
    utDark = "dark"
    utLight = "light"
    utPlain = "plain"
      ## NOT A PALETTE AT ALL. `plain` is the request for a screen with no
      ## colour on it, so it resolves the colour ladder to `cdMonochrome`
      ## whatever the terminal can do — which is the same rung `--no-color`
      ## reaches, by a different door and for a different reason. Weight,
      ## underline, reverse and glyph carry every state, exactly as
      ## `app/theme/roles.RoleSpecs[...].mono` lays out.

  PaletteKind* = enum
    ## `--palette=<name>` — PLAT-46 deliverable 9.
    pkDesign = "design"
      ## The default: paint the design system's colours — 24-bit where the
      ## terminal has it, else the 256- and 16-colour rungs DERIVED from the same
      ## token hexes — and own every cell's background.
    pkTerminal = "terminal"
      ## Paint ONLY with the sixteen symbolic ANSI indices and the terminal's
      ## DEFAULT foreground/background (SGR 39/49), so the user's own terminal
      ## palette decides the actual colours — vim without `termguicolors`.

  BackgroundSource* = enum
    ## Where the Dark/Light decision came from. Named on the status line
    ## (`bg: osc11 #1e1e2e -> dark`), because "why is this light?" must be
    ## answerable from the screen.
    bsFlag = "flag"
      ## `--theme=dark|light|plain`.
    bsOsc11 = "osc11"
      ## The terminal answered `OSC 11 ; ?` with its background colour.
    bsColorFgBg = "colorfgbg"
      ## `$COLORFGBG` (rxvt, Konsole).
    bsDefault = "default"
      ## Nothing answered: Dark, vim's default.

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
    csProbe = "probe"
      ## PLAT-46: the terminal ANSWERED a start-up query (DECRQSS / XTGETTCAP
      ## for 24-bit colour, or tmux reported its client's `RGB` feature). A
      ## positive answer is trusted over a conservative `TERM`.
    csSetting = "setting"
      ## A CodeTracer setting: `:set` this session, a `[terminal "<glob>"]`
      ## section, or the global settings (Terminal-Adaptation §5.2 ranks 1,
      ## 4 and 5). The axis's note says which.
    csIdentity = "identity"
      ## The terminal's identity (XTVERSION, DA2, tmux's client) looked up in
      ## the documented tables (§5.2 rank 8).
    csCache = "cache"
      ## The answers this terminal gave last time (§4.7), before this
      ## session's arrive (§5.2 rank 10).

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
    colorFgBg*: string
      ## `$COLORFGBG` — `fg;bg` (or `fg;default;bg`) as ANSI indices, set by
      ## rxvt and Konsole. PLAT-46's second source for the background, after
      ## OSC 11.
    tmux*: string
      ## `$TMUX`. Non-empty inside tmux, which is where a conservative `TERM`
      ## (`screen`, `tmux-256color`) most often hides a 24-bit outer terminal.
    termProgramVersion*: string
      ## `$TERM_PROGRAM_VERSION` (Terminal-Adaptation §4.1).
    vteVersion*, konsoleVersion*, kittyWindowId*, weztermExecutable*,
      alacrittyWindowId*, ghosttyResourcesDir*, wtSession*,
      terminalEmulator*: string
      ## The terminals' own markers (§4.1): local only, a hint, never proof.
    sty*, zellij*: string
      ## `$STY` (screen) and `$ZELLIJ`.
    sshConnection*, sshTty*: string
      ## A remote session (§3.4). Marks remote, not slow.
    ctGlyphs*, ctModernUnicode*, ctAmbiguousWidth*, ctColors*,
      ctProbe*: string
      ## The CodeTracer environment overrides (§5.2 rank 3):
      ## `CODETRACER_TUI_GLYPHS`, `…_MODERN_UNICODE`, `…_AMBIGUOUS_WIDTH`,
      ## `…_COLORS`, `…_PROBE`.

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
    themePinned*: bool
      ## Whether `--theme` was GIVEN. PLAT-46: with no `--theme` the mode is
      ## detected from the terminal's background, so "absent" and "`dark`" are
      ## two different requests and the zero value must be the first.
    palette*: PaletteKind
      ## `--palette=design|terminal`. `pkDesign` when absent.
    imageTier*: ImageTier
      ## `--image-tier=<name>` — PLAT-14, CodeTracer-TUI-Graphics.md §2.2: "A
      ## user override exists (`--image-tier`) and always wins, per the
      ## campaign's established rule that an explicit flag beats a probe."
      ##
      ## MEANINGLESS UNLESS `imageTierPinned`, and the pair is two fields rather
      ## than an `Option` for `initCapabilityFlags`' reason: `parseTuiCommand`'s
      ## default is compared with `initCapabilityFlags()` BY EQUALITY in
      ## `app/tests/test_capability_resolution.nim`, so the unpinned value has
      ## to be a stated constant rather than whatever an option's zero happens
      ## to be. It is `itAscii` — the weakest tier — so that a consumer which
      ## read the tier without checking the flag would get the answer that
      ## cannot put escape bytes on a screen. See `tiers.parseTierName`, which
      ## makes the same choice for the same reason.
    imageTierPinned*: bool
    choices*: TerminalChoices
      ## Terminal-Adaptation §5.3's flags for this run (§5.2 rank 2):
      ## `--glyphs=`, `--modern-unicode=`, `--ambiguous-width=`, `--colors=`,
      ## `--no-probe` / `--terminal-probe=`, `--reduce-motion=`.

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
      ## Whether the environment ADVERTISES the Kitty keyboard protocol
      ## (`$TERM` / `$TERM_PROGRAM`). A hint for the report only: what is
      ## ENABLED is `keyProtocol`, and that is decided by asking the terminal
      ## (Base-Keymaps-And-Layer-Stack.md §7.2 — *"ask, do not guess"*).
    keyProtocol*: KeyProtocol
      ## PLAT-68: the extended key reporting this session negotiated — the
      ## Kitty protocol when the terminal answered `CSI ? u`, else xterm's
      ## `modifyOtherKeys` on an xterm-compatible terminal, else legacy. It
      ## was detected and deliberately NOT enabled until the decoder could
      ## read the encodings (`key_names.keyName` reads both now), and the CUA
      ## base needs it: `Ctrl+Shift+K`, `Shift+Enter` and `Ctrl+.` have no
      ## legacy bytes. `host/terminal_driver.adoptCapabilities` enables it and
      ## `nim-termctl`'s async-signal-safe restore undoes it on every exit
      ## path. It is the `keyProtocol` context key a binding's `when` reads.
    keyProtocolFrom*: CapabilitySource
    tmuxExtendedKeysOff*: bool
      ## Inside tmux, and tmux's `extended-keys` option is off, so the
      ## protocol cannot reach this pane. The status line names the remedy
      ## (`tmuxExtendedKeysRemedy`).
    theme*: UiTheme
      ## Which theme was asked for (or `utDark` when none was) — CTUI-14.
    mode*: DesignMode
      ## PLAT-46: the design-system colour MODE the roles resolve in. From
      ## `--theme` when given, else detected from the terminal's background.
    modeFrom*: BackgroundSource
    background*: string
      ## The terminal background the mode was decided from, as `#rrggbb`; ""
      ## when none was reported (a flag, or no answer).
    palette*: PaletteKind
    tmuxRgbWithheld*: bool
      ## Inside tmux, and tmux reports no `RGB` feature for its client, so a
      ## 24-bit outer terminal is being painted below its depth. The status
      ## line names the remedy (`tmuxRgbRemedy`).
    tmuxClientTerm*: string
      ## tmux's `client_termname`, for the remedy's pattern. "" when unknown.
    colorsFrom*: CapabilitySource
    bordersFrom*: CapabilitySource
    mouseFrom*: CapabilitySource
    syncFrom*: CapabilitySource
    themeFrom*: CapabilitySource
    # --- Terminal-Adaptation §5.1: the rest of the profile -----------------
    identity*: TerminalIdentity
    identityFrom*: CapabilitySource
    tier*: ChromeTier
      ## The glyph tier (§6.1). `borders` is its two-valued shadow, kept for
      ## the callers that only ask "ASCII or not".
    tierNote*: string
    modernUnicode*: bool
      ## Symbols for Legacy Computing in the chrome (§6.7): only on the
      ## `extended` tier, and never by detection alone (TA-9).
    modernChoice*: ModernChoice
    modernUnicodeFrom*: CapabilitySource
    modernNote*: string
    widths*: WidthModel
    widthsFrom*: CapabilitySource
    ambiguousWide*: bool
      ## The ambiguous-wide rule is in force (§6.2): a one-cell role may use
      ## only a glyph that is not East Asian Width `A`.
    ambiguousFrom*: CapabilitySource
    ambiguousNote*: string
    graphemeMode*: bool
      ## DEC 2027 is on for this session (already, or set by us).
    graphemeSet*: bool
      ## …and it was off, so this session sets it and resets it on exit.
    syncNote*: string
    rttMs*: int
      ## The start-up round's round trip, write to DA1 answer; -1 unknown.
    rttFrom*: CapabilitySource
    linkConservative*: bool
      ## `rttMs` over `LinkConservativeMs` (§4.6): animations show their end
      ## state, hover repaints are coalesced.
    reduceMotion*: bool
    reduceMotionFrom*: CapabilitySource
    probeOff*: bool
      ## The start-up round was turned off (§4.8 rule 4).
    probeFrom*: CapabilitySource
    clipboard*: string
      ## `osc52`, `osc52 via tmux`, or `in-app only` (§8).
    clipboardFrom*: CapabilitySource
    remedies*: seq[string]
      ## The one-line fixes the report and the status line offer (§10.1).

const
  ClipboardInAppOnly* = "in-app only"
    ## The clipboard axis when no OSC 52 writer was found (§8).
  InAppOnlyCopyNote* = "inside CodeTracer only — your terminal does not " &
                       "accept OSC 52 (see :terminal-info)"
    ## What a copy says then (§8), after "copied <what>".
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
    ## Terminals that advertise the Kitty keyboard protocol — the report's
    ## hint; `keyProtocol` is decided by the terminal's answer.

  ModifyOtherKeysTermPrefixes* = ["xterm", "tmux"]
    ## `$TERM` prefixes of terminals that implement xterm's `modifyOtherKeys`
    ## (tmux does, when its `extended-keys` option is on). A terminal that
    ## does not answers nothing to `CSI > 4 ; 2 m` and keeps the legacy
    ## encoding, which the decoder reads either way.

  DumbTerm* = "dumb"
    ## §6.3's floor: "`TERM=dumb` … uses monochrome styling with bold and
    ## underline attributes".

proc initTerminalEnv*(term = ""; colorterm = ""; termProgram = "";
                      lcAll = ""; lcCtype = ""; lang = "";
                      noColor = ""; isTty = true; colorFgBg = "";
                      tmux = ""; termProgramVersion = "";
                      sshConnection = ""; sty = ""; zellij = "";
                      vteVersion = ""; kittyWindowId = "";
                      ctGlyphs = ""; ctModernUnicode = "";
                      ctAmbiguousWidth = ""; ctColors = "";
                      ctProbe = ""): TerminalEnv =
  ## A `TerminalEnv` with every field named. Written as a constructor with
  ## defaults so a test that varies one variable says which one it varied
  ## instead of listing eight positional strings.
  TerminalEnv(term: term, colorterm: colorterm, termProgram: termProgram,
              lcAll: lcAll, lcCtype: lcCtype, lang: lang, noColor: noColor,
              isTty: isTty, colorFgBg: colorFgBg, tmux: tmux,
              termProgramVersion: termProgramVersion,
              sshConnection: sshConnection, sty: sty, zellij: zellij,
              vteVersion: vteVersion, kittyWindowId: kittyWindowId,
              ctGlyphs: ctGlyphs, ctModernUnicode: ctModernUnicode,
              ctAmbiguousWidth: ctAmbiguousWidth, ctColors: ctColors,
              ctProbe: ctProbe)

proc initCapabilityFlags*(forceTrueColor = false; noColor = false;
                          asciiBorders = false; noMouse = false;
                          theme = utDark;
                          imageTier = itAscii;
                          imageTierPinned = false;
                          themePinned = false;
                          palette = pkDesign): CapabilityFlags =
  CapabilityFlags(forceTrueColor: forceTrueColor, noColor: noColor,
                  asciiBorders: asciiBorders, noMouse: noMouse, theme: theme,
                  imageTier: imageTier, imageTierPinned: imageTierPinned,
                  themePinned: themePinned, palette: palette)

const
  RetiredThemes*: array[1, (string, UiTheme)] = [("monokai", utDark)]
    ## Theme names that USED to be accepted, each with the one that replaces
    ## it. `app/cli.nim` refuses them with `retiredThemeMessage` rather than
    ## silently ignoring them.

proc retiredThemeMessage*(name: string): string =
  ## "" for a name that was never retired; otherwise the refusal naming the
  ## replacement.
  let wanted = name.toLowerAscii()
  for (old, replacement) in RetiredThemes:
    if old == wanted:
      return "--theme=" & old & " was retired: the design system's syntax " &
        "palette (Dracula / Alucard) replaces it; use --theme=" &
        $replacement & " (or --theme=light)"
  ""

proc parsePalette*(name: string): (bool, PaletteKind) =
  ## `--palette=<name>`'s argument, matched against the enum's spellings.
  let wanted = name.toLowerAscii()
  for p in PaletteKind:
    if $p == wanted:
      return (true, p)
  (false, pkDesign)

proc paletteNames*(): string =
  var parts: seq[string] = @[]
  for p in PaletteKind:
    parts.add $p
  parts.join(", ")

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
  ## The theme names, for a usage message. Same source as `parseTheme`.
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

proc resolveMouse(env: TerminalEnv;
                  flags: CapabilityFlags): (bool, CapabilitySource) =
  if flags.noMouse:
    return (false, csFlag)
  if isDumbTerminal(env):
    return (false, csEnvironment)
  (true, csDefault)

const
  LightBackgroundLuminance* = 0.18
    ## A background whose WCAG relative luminance is ABOVE this is light.
    ## 0.18 is CIE L* ≈ 50, the perceptual midpoint between black and white —
    ## mid-grey `#777777` sits on it — so the threshold is where a reader's own
    ## "is this a dark or a light terminal" flips, not a tuned constant.

proc isLightBackground*(c: Rgb8): bool =
  relativeLuminance(c) > LightBackgroundLuminance

proc modeForBackground*(c: Rgb8): DesignMode =
  if isLightBackground(c): dmLight else: dmDark

proc parseColorFgBg*(value: string): (bool, DesignMode) =
  ## `$COLORFGBG` -> the mode its background implies. `(false, …)` when the
  ## variable is absent or unreadable.
  ##
  ## The value is `fg;bg` or `fg;default;bg` (rxvt's three-field form); the
  ## LAST field is the background's ANSI index. Indices 0-6 and 8 are dark
  ## backgrounds and every other index is light — vim's own reading of the
  ## variable (`:help 'background'`), kept so the two editors agree.
  if value.len == 0:
    return (false, dmDark)
  let parts = value.split(';')
  var idx = -1
  try:
    idx = parseInt(parts[^1].strip())
  except ValueError:
    return (false, dmDark)
  if idx < 0 or idx > 15:
    return (false, dmDark)
  if idx in {0 .. 6, 8}: (true, dmDark) else: (true, dmLight)

proc parseOsc11Reply*(reply: string): (bool, Rgb8) =
  ## An `OSC 11` answer -> the terminal's background colour.
  ##
  ## xterm's form is `ESC ] 11 ; rgb:RRRR/GGGG/BBBB` terminated by BEL or ST;
  ## each channel is 1-4 hex digits and SCALED to its own width
  ## (https://invisible-island.net/xterm/ctlseqs/ctlseqs.html, "Operating
  ## System Commands", and XParseColor). Anything else is `(false, …)`.
  let at = reply.find("11;rgb:")
  if at < 0:
    return (false, (0, 0, 0))
  var body = reply[at + "11;rgb:".len .. ^1]
  var stop = body.len
  for i, ch in body:
    if ch notin HexDigits and ch != '/':
      stop = i
      break
  body = body[0 ..< stop]
  let channels = body.split('/')
  if channels.len != 3:
    return (false, (0, 0, 0))
  var rgb: array[3, int]
  for i, c in channels:
    if c.len < 1 or c.len > 4:
      return (false, (0, 0, 0))
    let v = fromHex[int](c)
    let maxV = (1 shl (4 * c.len)) - 1
    rgb[i] = (v * 255 + maxV div 2) div maxV
  (true, (rgb[0], rgb[1], rgb[2]))

type
  TerminalProbe* = object
    ## What the start-up query round OBSERVED — data, not a decision.
    ## `host/terminal_probe.nim` fills it by writing the queries down the tty
    ## and reading the answers back; `applyProbe` below decides what they mean.
    attempted*: bool
    answered*: bool
      ## The DA1 fence came back: the terminal is answering queries at all.
    hasBackground*: bool
    background*: Rgb8
      ## From `OSC 11`.
    truecolor*: bool
      ## A positive DECRQSS (the terminal kept a 24-bit SGR) or XTGETTCAP
      ## (`RGB` / `Tc`) answer.
    truecolorVia*: string
      ## "decrqss" / "xtgettcap" / "tmux", for the diagnostic line.
    tmuxQueried*: bool
    tmuxRgb*: bool
      ## tmux's `client_termfeatures` includes `RGB`.
    tmuxClientTerm*: string
    pixelMouseAnswered*: bool
      ## PLAT-51 (Layout-ViewModel §4.2.2): the terminal answered DECRQM for
      ## SGR-pixel mouse reporting (`CSI ? 1016 $ p`).
    pixelMouse*: bool
      ## …and said it RECOGNISES the mode (set, reset or permanently set) —
      ## so `?1016h` will make its reports pixels.
    cellWidthPx*, cellHeightPx*: int
      ## PLAT-51: the terminal's cell in pixels, from `CSI 16 t`
      ## (`CSI 6 ; height ; width t`); 0 when it did not say.
    kittyKeyboardAnswered*: bool
      ## PLAT-68: the terminal answered `CSI ? u` (`CSI ? <flags> u`) before
      ## the DA1 fence — it implements the Kitty keyboard protocol.
    tmuxExtendedKeys*: string
      ## tmux's `extended-keys` option (`on`, `off`, `always`); "" unknown.
    # --- Terminal-Adaptation §4.2's additions to the round -----------------
    xtversion*: string
      ## XTVERSION's text (`kitty(0.36.4)`, `tmux 3.4`); "" unanswered.
    da2Answered*: bool
    da2Pp*, da2Pv*: int
    sync2026Answered*, grapheme2027Answered*: bool
    sync2026*, grapheme2027*: int
      ## DECRQM's `Ps` for each mode (meaningful when answered).
    cprExpected*: int
      ## How many cursor reports the width probe asked for. A `CSI r ; c R`
      ## is taken as a REPLY only while fewer than this have arrived (§4.3's
      ## F3 rule); after that it is Ctrl+F3 again.
    cprAnswers*: seq[int]
      ## The width each answered probe measured (column − 1), in probe order.
    rttMeasured*: bool
    rttMs*: int
      ## Write to the DA1 answer.
    tmuxClientTermType*, tmuxClientUtf8*, tmuxVersion*, tmuxPassthrough*,
      tmuxSetClipboard*, tmuxFocusEvents*, tmuxMouse*: string
      ## tmux's view of its client and its options, from ONE
      ## `tmux display -p` (§4.5); "" unknown.

const AutoDetectSelectsLight* = false
  ## **WHETHER BACKGROUND DETECTION MAY CHOOSE LIGHT — it may not.** A product
  ## decision (the user, 2026-09-27, PLAT-47): the design system's Light
  ## editor surface is poorly legible (PLAT-46's review measured every editor
  ## glyph below 4.5:1 on it), so a terminal whose background is light still
  ## opens in DARK until the design system fixes that surface in Figma.
  ## `--theme=light` (and `:theme light`) still select Light: a user who asks
  ## for it gets it. The detection itself still runs and is still REPORTED on
  ## the status line (`backgroundNote`), so the day this becomes `true` the
  ## only change is this constant.

proc resolveMode(env: TerminalEnv; flags: CapabilityFlags;
                 probe: TerminalProbe): (DesignMode, BackgroundSource, string) =
  ## PLAT-46 deliverable 8, as amended by PLAT-47: `--theme` wins; else the
  ## mode the terminal's ACTUAL background (OSC 11), else `$COLORFGBG`,
  ## implies — which, while `AutoDetectSelectsLight` is false, is Dark
  ## whatever the background; else Dark.
  proc gated(m: DesignMode): DesignMode =
    if m == dmLight and not AutoDetectSelectsLight: dmDark else: m
  if flags.themePinned:
    return ((if flags.theme == utLight: dmLight else: dmDark), bsFlag, "")
  if probe.hasBackground:
    return (gated(modeForBackground(probe.background)), bsOsc11,
            hexOf(probe.background))
  let (known, mode) = parseColorFgBg(env.colorFgBg)
  if known:
    return (gated(mode), bsColorFgBg, "")
  (dmDark, bsDefault, "")

proc resolveKeyProtocol*(env: TerminalEnv;
                         probe: TerminalProbe): (KeyProtocol, CapabilitySource) =
  ## Base-Keymaps-And-Layer-Stack.md §7.2: the Kitty protocol when the
  ## terminal SAID it implements it; else `modifyOtherKeys` on an
  ## xterm-compatible terminal; else legacy. `$TERM_PROGRAM`'s Kitty list is
  ## not consulted — it is a hint for the report, not the decision.
  if isDumbTerminal(env):
    return (kpLegacy, csEnvironment)
  if probe.kittyKeyboardAnswered:
    return (kpKitty, csProbe)
  let term = env.term.toLowerAscii()
  for prefix in ModifyOtherKeysTermPrefixes:
    if term.startsWith(prefix):
      return (kpModifyOtherKeys, csEnvironment)
  (kpLegacy, csDefault)

const
  LinkConservativeMs* = 40
    ## Terminal-Adaptation §4.6 (OQ-T11): a start-up round trip above this
    ## makes the session link-conservative. An assumed threshold, to be
    ## re-tuned on a real SSH link.

type
  Ranked[T] = object
    found: bool
    value: T
    source: CapabilitySource
    note: string

proc envChoices*(env: TerminalEnv): (TerminalChoices, seq[string]) =
  ## §5.2 rank 3: the `CODETRACER_TUI_*` overrides, parsed. A value that is
  ## not one of the setting's words is named in the second result, never
  ## silently ignored.
  var c = TerminalChoices()
  var bad: seq[string] = @[]
  if env.ctGlyphs.len > 0:
    var v: GlyphsChoice
    if parseChoice(env.ctGlyphs, v): c.glyphs = some(v)
    else: bad.add "CODETRACER_TUI_GLYPHS=" & env.ctGlyphs & " is not " &
                  choiceNames[GlyphsChoice]()
  if env.ctModernUnicode.len > 0:
    var v: ModernChoice
    if parseChoice(env.ctModernUnicode, v): c.modernUnicode = some(v)
    else: bad.add "CODETRACER_TUI_MODERN_UNICODE=" & env.ctModernUnicode &
                  " is not " & choiceNames[ModernChoice]()
  if env.ctAmbiguousWidth.len > 0:
    var v: AmbiguousChoice
    if parseChoice(env.ctAmbiguousWidth, v): c.ambiguousWidth = some(v)
    else: bad.add "CODETRACER_TUI_AMBIGUOUS_WIDTH=" & env.ctAmbiguousWidth &
                  " is not " & choiceNames[AmbiguousChoice]()
  if env.ctColors.len > 0:
    var v: ColorsChoice
    if parseChoice(env.ctColors, v): c.colors = some(v)
    else: bad.add "CODETRACER_TUI_COLORS=" & env.ctColors & " is not " &
                  choiceNames[ColorsChoice]()
  if env.ctProbe.len > 0:
    var v: bool
    if parseOnOffWord(env.ctProbe, v): c.probe = some(v)
    else: bad.add "CODETRACER_TUI_PROBE=" & env.ctProbe & " is not on or off"
  (c, bad)

proc flagChoices(flags: CapabilityFlags): TerminalChoices =
  ## Rank 2, with the older flags folded in: `--ascii-borders` is
  ## `--glyphs=ascii`, `--no-color` and `--theme=plain` are `--colors=mono`,
  ## `--truecolor` is `--colors=truecolor` (`app/cli.nim` refuses the
  ## contradictory pairs).
  result = flags.choices
  if flags.asciiBorders and result.glyphs.isNone:
    result.glyphs = some(gcAscii)
  if (flags.noColor or flags.theme == utPlain) and result.colors.isNone:
    result.colors = some(ccMono)
  if flags.forceTrueColor and result.colors.isNone:
    result.colors = some(ccTrueColor)

type
  RankSource = object
    choices: TerminalChoices
    source: CapabilitySource
    note: string

proc explicitRanks(env: TerminalEnv; flags: CapabilityFlags;
                   prefs: TerminalPrefs; session: TerminalChoices;
                   identity: TerminalIdentity): seq[RankSource] =
  ## Ranks 1–5 of §5.2, strongest first.
  result = @[
    RankSource(choices: session, source: csSetting, note: ":set"),
    RankSource(choices: flagChoices(flags), source: csFlag, note: "flag"),
    RankSource(choices: envChoices(env)[0], source: csEnvironment,
               note: "CODETRACER_TUI_*")]
  for scope in prefs.scoped:
    if identity.known and (globMatch(scope.glob, identity.name) or
                           globMatch(scope.glob, identity.chainName)):
      result.add RankSource(choices: scope.choices, source: csSetting,
                            note: "[terminal \"" & scope.glob & "\"]")
  result.add RankSource(choices: prefs.global, source: csSetting,
                        note: "setting")

template firstExplicit(ranks: seq[RankSource]; field: untyped;
                       T: typedesc; skipAuto: bool): Ranked[T] =
  var r = Ranked[T]()
  for rank in ranks:
    let o = rank.choices.field
    if o.isSome:
      when skipAuto:
        if ord(o.get) == 0:   # `auto` is every enum's first value
          continue
      r = Ranked[T](found: true, value: o.get, source: rank.source,
                    note: rank.note)
      break
  r

# ---------------------------------------------------------------------------
# Identity (§4.4)
# ---------------------------------------------------------------------------

proc versionOfVteNumber(raw: string): string =
  if raw.len >= 4 and raw.allCharsInSet(Digits):
    let n = parseInt(raw)
    $(n div 10000) & "." & $((n div 100) mod 100) & "." & $(n mod 100)
  else: raw

proc identityFromEnvironment(env: TerminalEnv): (string, string) =
  ## The terminal's own markers (§4.1), best first. Local sessions only.
  let term = env.term.toLowerAscii
  let program = env.termProgram
  if env.kittyWindowId.len > 0 or term == "xterm-kitty":
    return ("kitty", "")
  if env.ghosttyResourcesDir.len > 0 or program == "ghostty":
    return ("ghostty", (if program == "ghostty": env.termProgramVersion
                        else: ""))
  if env.weztermExecutable.len > 0 or program == "WezTerm":
    return ("wezterm", (if program == "WezTerm": env.termProgramVersion
                        else: ""))
  if program == "iTerm.app":
    return ("iterm2", env.termProgramVersion)
  if program == "Apple_Terminal":
    return ("terminal.app", env.termProgramVersion)
  if program == "vscode":
    return ("xterm.js", env.termProgramVersion)
  if env.vteVersion.len > 0:
    return ("vte", versionOfVteNumber(env.vteVersion))
  if env.konsoleVersion.len > 0:
    return ("konsole", env.konsoleVersion)
  if env.alacrittyWindowId.len > 0 or term.startsWith("alacritty"):
    return ("alacritty", "")
  if env.wtSession.len > 0:
    return ("windows-terminal", "")
  if env.terminalEmulator == "JetBrains-JediTerm":
    return ("jediterm", "")
  if term.startsWith("foot"):
    return ("foot", "")
  if term == "linux":
    return ("linux", "")
  ("", "")

proc resolveIdentity*(env: TerminalEnv; probe: TerminalProbe;
                      cache: Option[CachedProfile]):
    (TerminalIdentity, CapabilitySource) =
  ## §4.4: XTVERSION, then DA2, then tmux's view of its client, then the
  ## environment (local only), then the cache.
  var id = TerminalIdentity(remote: env.sshConnection.len > 0 or
                                    env.sshTty.len > 0)
  var (xName, xVersion) = ("", "")
  if probe.xtversion.len > 0:
    (xName, xVersion) = parseXtversionText(probe.xtversion)
  var (dName, dVersion) = ("", "")
  if probe.da2Answered:
    (dName, dVersion) = identityOfDa2(probe.da2Pp, probe.da2Pv)
  let inTmux = env.tmux.len > 0 or xName == "tmux" or dName == "tmux"
  let inScreen = not inTmux and (env.sty.len > 0 or dName == "screen" or
                                 xName == "screen")
  let inZellij = env.zellij.len > 0
  if inTmux:
    let ver = if xName == "tmux" and xVersion.len > 0: xVersion
              elif probe.tmuxVersion.len > 0: probe.tmuxVersion
              else: ""
    id.via = @["tmux" & (if ver.len > 0: " " & ver else: "")]
    if probe.tmuxClientTermType.len > 0:
      let (n, v) = parseXtversionText(probe.tmuxClientTermType)
      id.name = n
      id.version = v
      id.source = isTmuxClient
      id.endToEnd = true
      return (id, csProbe)
    # The outer terminal is not known through tmux. `TERM_PROGRAM` names the
    # tmux itself (3.2+) or is inherited from outside — a hint.
    id.endToEnd = false
    id.source = isUnknown
    return (id, csDefault)
  if inScreen or inZellij:
    id.via = @[(if inScreen: "screen" else: "zellij")]
    id.endToEnd = false
    id.source = isUnknown
    return (id, csDefault)
  if xName.len > 0:
    id.name = xName
    id.version = xVersion
    id.source = isXtversion
    id.endToEnd = true
    return (id, csProbe)
  if dName.len > 0:
    id.name = dName
    id.version = dVersion
    id.source = isDa2
    id.endToEnd = true
    return (id, csProbe)
  if not id.remote:
    let (n, v) = identityFromEnvironment(env)
    if n.len > 0:
      id.name = n
      id.version = v
      id.source = isEnvironment
      id.endToEnd = true
      return (id, csEnvironment)
  if cache.isSome and cache.get.identityName.len > 0:
    id.name = cache.get.identityName
    id.version = cache.get.identityVersion
    id.source = isCache
    id.endToEnd = true
    return (id, csCache)
  (id, csDefault)

# ---------------------------------------------------------------------------
# The widths (§4.3)
# ---------------------------------------------------------------------------

proc liveWidths(probe: TerminalProbe): array[WidthProbe, int] =
  result = noWidthAnswers()
  var i = 0
  for p in WidthProbe:
    if i < probe.cprAnswers.len:
      result[p] = probe.cprAnswers[i]
    inc i

proc resolveWidths(probe: TerminalProbe; cache: Option[CachedProfile]):
    (WidthModel, CapabilitySource) =
  let live = liveWidths(probe)
  let g = if probe.grapheme2027Answered: probe.grapheme2027 else: -1
  let model = widthModelOf(live, g)
  if model.measured:
    return (model, csProbe)
  if cache.isSome:
    let cached = widthModelOf(cache.get.widths, cache.get.grapheme2027)
    if cached.measured:
      return (cached, csCache)
  (model, csDefault)

# ---------------------------------------------------------------------------
# The axes
# ---------------------------------------------------------------------------

proc resolveColorDepth(env: TerminalEnv;
                       explicit: Ranked[ColorsChoice]):
                      (ColorDepth, CapabilitySource) =
  ## §6.3's colour ladder (PLAT-46) under §5.2: an explicit choice — ranks
  ## 1–5, the flags among them — first; then `NO_COLOR` (rank 6), as
  ## no-color.org asks; then the environment.
  if explicit.found:
    let depth = case explicit.value
      of ccTrueColor: cdTrueColor
      of cc256: cdAnsi256
      of cc16: cdAnsi16
      of ccMono, ccAuto: cdMonochrome
    return (depth, explicit.source)
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

proc resolveTier(env: TerminalEnv; explicit: Ranked[GlyphsChoice];
                 widths: WidthModel; widthsFrom: CapabilitySource;
                 identity: TerminalIdentity; probe: TerminalProbe):
                (ChromeTier, CapabilitySource, string) =
  ## §6.1's `auto`, under §5.2.
  if explicit.found:
    let t = case explicit.value
      of gcAscii: tierAscii
      of gcBasic: tierBasic
      of gcExtended, gcAuto: tierExtended
    return (t, explicit.source, explicit.note)
  if isDumbTerminal(env):
    # Not a locale question but a rendering one: a `TERM=dumb` stream is not
    # promised to survive a three-byte glyph, and there is no screen at all
    # when `isTty` is false.
    return (tierAscii, csEnvironment,
            (if env.isTty: "TERM=" & (if env.term.len > 0: env.term
                                      else: "(unset)")
             else: "not a terminal"))
  let console = env.term.toLowerAscii == "linux"
  let ceiling = if console: tierBasic else: tierExtended
  let consoleNote = if console: ", the Linux console" else: ", not a console"
  let locale = effectiveLocale(env)
  let utf8Locale = isUtf8Locale(locale)
  # Under tmux, a client that is not UTF-8 keeps ASCII whatever the probe
  # measured inside tmux (OQ-T8's exception).
  if env.tmux.len > 0 and probe.tmuxClientUtf8 == "0":
    return (tierAscii, csProbe, "tmux client_utf8=0")
  if widths.utf8 == knNo:
    return (tierAscii, widthsFrom, "the terminal decodes Latin-1 (P0=3)")
  if utf8Locale:
    return (ceiling, csEnvironment, "auto: UTF-8 (" & locale & ")" &
            consoleNote)
  if widths.utf8 == knYes:
    # OQ-T8: a C locale on a terminal that decodes UTF-8 uses Unicode, and
    # the report gives the `LANG` remedy.
    return (ceiling, widthsFrom, "locale " &
            (if locale.len > 0: locale else: "unset") &
            ", terminal decodes UTF-8" & consoleNote)
  (tierAscii, csDefault, "locale " & (if locale.len > 0: locale else: "unset") &
              " is not UTF-8")

proc resolveAmbiguous(env: TerminalEnv; explicit: Ranked[AmbiguousChoice];
                      widths: WidthModel; widthsFrom: CapabilitySource):
                     (bool, CapabilitySource, string) =
  ## §6.2: is the ambiguous-wide rule in force?
  if explicit.found:
    return (explicit.value == acWide, explicit.source,
            $explicit.value & " (" & explicit.note & ")")
  if widths.ambiguous == apWide or widths.blockAmbig == apWide:
    return (true, widthsFrom,
            "measured wide (P1=" & $widths.answered[wpEllipsis] & ", P2=" &
            $widths.answered[wpBlock] & ")")
  if widths.ambiguous == apNarrow:
    return (false, widthsFrom, "measured narrow (P1=" &
            $widths.answered[wpEllipsis] & ")")
  let locale = effectiveLocale(env)
  if isCjkLocale(locale):
    # OQ-T3: unmeasured on a CJK desktop, where the wide setting lives.
    return (true, csEnvironment, "unmeasured, CJK locale " & locale)
  (false, csDefault, "unmeasured: narrow")

proc resolveModern(explicit: Ranked[ModernChoice]; tier: ChromeTier;
                   identity: TerminalIdentity; widths: WidthModel):
                  (bool, ModernChoice, CapabilitySource, string) =
  ## §6.7. `off` is the default (the user's decision); `on` draws them on
  ## the `extended` tier; `auto` only where the terminal draws the range
  ## itself and the identity is known end to end. NOTHING BELOW RANK 5 CAN
  ## TURN IT ON (TA-9).
  let choice = if explicit.found: explicit.value else: mcOff
  let source = if explicit.found: explicit.source else: csDefault
  let where = if explicit.found: " (" & explicit.note & ")" else: ""
  case choice
  of mcOff:
    let (would, why) = drawsModernGlyphs(identity)
    (false, mcOff, source, "off" & where &
       (if would and identity.endToEnd: "; auto would turn it on: " & why
        else: ""))
  of mcOn:
    if tier != tierExtended:
      (false, mcOn, source, "on" & where & ", but the tier is " & $tier)
    else:
      (true, mcOn, source, "on" & where)
  of mcAuto:
    if tier != tierExtended:
      return (false, mcAuto, source, "auto" & where & ": the tier is " & $tier)
    let (draws, why) = drawsModernGlyphs(identity)
    if not draws:
      return (false, mcAuto, source, "auto" & where & ": " & why)
    if not identity.endToEnd:
      return (false, mcAuto, source, "auto" & where &
              ": the terminal is not known through " & identity.via.join(", "))
    if widths.unicode13 != knYes:
      return (false, mcAuto, source, "auto" & where &
              ": U+1FB87 not measured one cell (P3=" &
              $widths.answered[wpLegacy] & ")")
    (true, mcAuto, csIdentity, "auto" & where & ": " & why)

proc resolveSync(env: TerminalEnv; probe: TerminalProbe;
                 identity: TerminalIdentity;
                 cache: Option[CachedProfile]):
                (bool, CapabilitySource, string) =
  ## §8: DECRQM 2026 decides; a NEGATIVE answer (Ps 0 or 4) beats an
  ## identity list that claims support; with no answer the identity, then the
  ## environment lists (§6.3), then the cache.
  if isDumbTerminal(env):
    return (false, csEnvironment, "no terminal to bracket")
  if probe.sync2026Answered:
    let on = probe.sync2026 in {1, 2, 3}
    return (on, csProbe, "DECRQM 2026=" & $probe.sync2026)
  if syncByIdentity(identity):
    return (true, csIdentity, identity.name & " implements DEC 2026")
  if env.termProgram in SynchronizedOutputPrograms:
    return (true, csEnvironment, "TERM_PROGRAM=" & env.termProgram)
  if env.term.toLowerAscii() in SynchronizedOutputTerms:
    return (true, csEnvironment, "TERM=" & env.term)
  if cache.isSome and cache.get.sync2026 >= 0:
    return (cache.get.sync2026 in {1, 2, 3}, csCache,
            "DECRQM 2026=" & $cache.get.sync2026 & " last time")
  (false, csDefault, "not answered")

proc resolveKittyKeyboard(env: TerminalEnv): bool =
  if isDumbTerminal(env):
    return false
  if env.term.toLowerAscii() in KittyKeyboardTerms:
    return true
  env.termProgram in KittyKeyboardPrograms

proc resolveCapabilities*(env: TerminalEnv; flags: CapabilityFlags;
                          probe = TerminalProbe();
                          prefs = TerminalPrefs();
                          session = TerminalChoices();
                          cache = none(CachedProfile)): TerminalCapabilities =
  ## THE whole decision, as one pure function of (environment, flags,
  ## settings, answers, cache) — Terminal-Adaptation TA-1.
  ##
  ## Every axis follows §5.2: a runtime `:set` (`session`), then a flag, then
  ## a `CODETRACER_TUI_*` variable, then a `[terminal "<glob>"]` section, then
  ## the global settings (`prefs`), then `NO_COLOR`, then the terminal's
  ## answers (`probe`), then its identity, then environment hints, then the
  ## cache, then the safe default. Each axis records which rank decided it.
  ##
  ## The cache is consulted only where nothing live answered: it is a
  ## remembered answer, so it beats a CONSERVATIVE environment guess (a
  ## `TERM` rung, a C locale) but never a live answer, a positive
  ## environment claim (`COLORTERM`, a UTF-8 locale) or an explicit choice
  ## (TA-12).
  let (identity, identityFrom) = resolveIdentity(env, probe, cache)
  let ranks = explicitRanks(env, flags, prefs, session, identity)
  let (widths, widthsFrom) = resolveWidths(probe, cache)

  # Colours.
  let colorChoice = firstExplicit(ranks, colors, ColorsChoice, true)
  var (colors, colorsFrom) = resolveColorDepth(env, colorChoice)
  var tmuxWithheld = false
  let envFloored = noColorRequested(env) or isDumbTerminal(env)
  if not colorChoice.found and not envFloored and colors < cdTrueColor:
    if probe.truecolor:
      (colors, colorsFrom) = (cdTrueColor, csProbe)
    elif env.tmux.len > 0 and probe.tmuxQueried:
      if probe.tmuxRgb:
        (colors, colorsFrom) = (cdTrueColor, csProbe)
      else:
        tmuxWithheld = true
    elif not probe.answered and cache.isSome and cache.get.truecolor:
      (colors, colorsFrom) = (cdTrueColor, csCache)

  # Glyphs.
  let glyphChoice = firstExplicit(ranks, glyphs, GlyphsChoice, true)
  let (tier, tierFrom, tierNote) =
    resolveTier(env, glyphChoice, widths, widthsFrom, identity, probe)
  let ambiguousChoice = firstExplicit(ranks, ambiguousWidth, AmbiguousChoice,
                                      true)
  let (ambiguousWide, ambiguousFrom, ambiguousNote) =
    resolveAmbiguous(env, ambiguousChoice, widths, widthsFrom)
  let modernChoice = firstExplicit(ranks, modernUnicode, ModernChoice, false)
  let (modern, modernValue, modernFrom, modernNote) =
    resolveModern(modernChoice, tier, identity, widths)

  let (mouse, mouseFrom) = resolveMouse(env, flags)
  let (sync, syncFrom, syncNote) = resolveSync(env, probe, identity, cache)
  let (mode, modeFrom, background) = resolveMode(env, flags, probe)
  let (keyProtocol, keyProtocolFrom) = resolveKeyProtocol(env, probe)

  # The link (§4.6).
  var rtt = -1
  var rttFrom = csDefault
  if probe.rttMeasured:
    (rtt, rttFrom) = (probe.rttMs, csProbe)
  elif cache.isSome and cache.get.rttMs >= 0:
    (rtt, rttFrom) = (cache.get.rttMs, csCache)
  let conservative = rtt > LinkConservativeMs
  let motionChoice = firstExplicit(ranks, reduceMotion, bool, false)
  var (reduceMotion, reduceMotionFrom) = (false, csDefault)
  if motionChoice.found:
    (reduceMotion, reduceMotionFrom) = (motionChoice.value, motionChoice.source)
  elif conservative:
    (reduceMotion, reduceMotionFrom) = (true, rttFrom)
  let probeChoice = firstExplicit(ranks, probe, bool, false)

  # Grapheme clustering (DEC 2027): set it when recognised and off.
  let graphemeKnown = probe.grapheme2027Answered and not isDumbTerminal(env)
  let graphemeMode = graphemeKnown and probe.grapheme2027 in {1, 2, 3}
  let graphemeSet = graphemeKnown and probe.grapheme2027 == 2

  # The clipboard (§8): no query exists.
  var (clipboard, clipboardFrom) = (ClipboardInAppOnly, csDefault)
  if env.tmux.len > 0 and probe.tmuxSetClipboard in ["on", "external"]:
    (clipboard, clipboardFrom) = ("osc52 via tmux", csProbe)
  elif env.tmux.len == 0 and identity.name in Osc52Writers:
    (clipboard, clipboardFrom) = ("osc52", csIdentity)

  result = TerminalCapabilities(
    colors: colors,
    borders: (if tier == tierAscii: bmAscii else: bmUnicode),
    mouse: mouse, synchronizedOutput: sync,
    kittyKeyboard: resolveKittyKeyboard(env),
    keyProtocol: keyProtocol, keyProtocolFrom: keyProtocolFrom,
    tmuxExtendedKeysOff: env.tmux.len > 0 and keyProtocol != kpLegacy and
      probe.tmuxExtendedKeys notin ["", "on", "always"],
    theme: flags.theme,
    colorsFrom: colorsFrom, bordersFrom: tierFrom, mouseFrom: mouseFrom,
    syncFrom: syncFrom,
    themeFrom: (if flags.themePinned: csFlag else: csDefault),
    mode: mode, modeFrom: modeFrom, background: background,
    palette: flags.palette,
    tmuxRgbWithheld: tmuxWithheld,
    tmuxClientTerm: probe.tmuxClientTerm,
    identity: identity, identityFrom: identityFrom,
    tier: tier, tierNote: tierNote,
    modernUnicode: modern, modernChoice: modernValue,
    modernUnicodeFrom: modernFrom, modernNote: modernNote,
    widths: widths, widthsFrom: widthsFrom,
    ambiguousWide: ambiguousWide, ambiguousFrom: ambiguousFrom,
    ambiguousNote: ambiguousNote,
    graphemeMode: graphemeMode, graphemeSet: graphemeSet,
    syncNote: syncNote,
    rttMs: rtt, rttFrom: rttFrom, linkConservative: conservative,
    reduceMotion: reduceMotion, reduceMotionFrom: reduceMotionFrom,
    probeOff: probeChoice.found and not probeChoice.value,
    probeFrom: (if probeChoice.found: probeChoice.source else: csDefault),
    clipboard: clipboard, clipboardFrom: clipboardFrom)

  # Remedies (§10.1), most useful first.
  if tmuxWithheld:
    let pattern = if probe.tmuxClientTerm.len > 0: probe.tmuxClientTerm & "*"
                  else: "xterm*"
    result.remedies.add "tmux withholds 24-bit colour: set -as " &
      "terminal-features '," & pattern & ":RGB'"
  if result.tmuxExtendedKeysOff:
    result.remedies.add "tmux withholds extended keys (Ctrl+Shift+…): " &
      "set -s extended-keys on"
  if env.tmux.len > 0 and probe.tmuxMouse in ["off", "0"] and mouse:
    result.remedies.add "tmux withholds the mouse: set -g mouse on"
  if tier != tierAscii and not isUtf8Locale(effectiveLocale(env)) and
     widths.utf8 == knYes:
    result.remedies.add "locale is " &
      (if effectiveLocale(env).len > 0: effectiveLocale(env) else: "unset") &
      " but the terminal decodes UTF-8: set LANG=C.UTF-8"
  for bad in envChoices(env)[1]:
    result.remedies.add bad

proc probeWanted*(env: TerminalEnv; flags: CapabilityFlags;
                  prefs = TerminalPrefs();
                  session = TerminalChoices()): bool =
  ## Whether the start-up query round runs at all.
  ##
  ## Terminal-Adaptation §4.2: the identity questions (XTVERSION, DA2,
  ## DECRQM 2026 / 2027) and the width probe are asked on EVERY start, so the
  ## round always has something to decide — except when there is no terminal
  ## to ask (a dumb terminal echoes queries) or the user turned the round off
  ## (`--no-probe`, `CODETRACER_TUI_PROBE=off`, `terminal-probe = off`;
  ## §4.8 rule 4).
  if isDumbTerminal(env):
    return false
  let ranks = explicitRanks(env, flags, prefs, session, TerminalIdentity())
  let choice = firstExplicit(ranks, probe, bool, false)
  not (choice.found and not choice.value)

proc backgroundNote*(caps: TerminalCapabilities): string =
  ## `bg: osc11 #1e1e2e -> dark` — the source of the mode decision, for the
  ## status line.
  result = "bg: " & $caps.modeFrom
  if caps.background.len > 0:
    result.add " " & caps.background
  # A light background that did NOT select Light says so, so a user on a
  # light terminal knows the Dark screen is a decision and how to override it.
  var detectedLight = false
  if caps.modeFrom == bsOsc11 and caps.background.len == 7:
    try:
      detectedLight = isLightBackground((
        fromHex[int](caps.background[1 .. 2]),
        fromHex[int](caps.background[3 .. 4]),
        fromHex[int](caps.background[5 .. 6])))
    except ValueError:
      detectedLight = false
  if detectedLight and caps.mode == dmDark:
    result.add " (light; --theme=light to use it)"
  result.add " -> " & (if caps.mode == dmLight: "light" else: "dark")

proc tmuxRgbRemedy*(caps: TerminalCapabilities): string =
  ## The one-line remedy when tmux withholds 24-bit colour; "" otherwise.
  if not caps.tmuxRgbWithheld:
    return ""
  let pattern = if caps.tmuxClientTerm.len > 0: caps.tmuxClientTerm & "*"
                else: "xterm*"
  "tmux withholds 24-bit colour: set -as terminal-features ',"  & pattern &
    ":RGB'"

proc tmuxExtendedKeysRemedy*(caps: TerminalCapabilities): string =
  ## The one-line remedy when tmux keeps extended keys from this pane; ""
  ## otherwise (Base-Keymaps §7.2 step 6).
  if not caps.tmuxExtendedKeysOff:
    return ""
  "tmux withholds extended keys (Ctrl+Shift+…): set -s extended-keys on"

proc capabilityNote*(caps: TerminalCapabilities; hint = true): string =
  ## What the status line says about the start-up negotiation: the
  ## background's source and — unless the user dismissed the hints
  ## (`:terminal-info dismiss`, §10.2) — the ONE most useful remedy.
  result = backgroundNote(caps)
  if hint and caps.remedies.len > 0:
    result.add " | " & caps.remedies[0]

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
  " keys=" & $caps.keyProtocol & "(" & $caps.keyProtocolFrom & ")" &
  " kitty-keyboard=" & (if caps.kittyKeyboard: "advertised" else: "no") &
  " mode=" & (if caps.mode == dmLight: "light" else: "dark") &
  "(" & $caps.modeFrom & ")" &
  " palette=" & $caps.palette &
  " glyphs=" & $caps.tier & "(" & $caps.bordersFrom & ")" &
  " modern-unicode=" & (if caps.modernUnicode: "on" else: "off") &
  "(" & $caps.modernUnicodeFrom & ")" &
  " ambiguous=" & (if caps.ambiguousWide: "wide" else: "narrow") &
  "(" & $caps.ambiguousFrom & ")" &
  " terminal=" & caps.identity.chainName & "(" & $caps.identityFrom & ")"
