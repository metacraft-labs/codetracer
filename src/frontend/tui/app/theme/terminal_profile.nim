## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/theme/terminal_profile.nim — the vocabulary of the terminal's
## CAPABILITY PROFILE (CodeTracer-TUI-Terminal-Adaptation.md §4, §5): what the
## start-up round can be told, how its answers are read, who the terminal is,
## how wide it draws the glyphs this front-end cares about, what the user chose
## and at which rank, and what is remembered per terminal between sessions.
##
## ## Pure, like `capabilities.nim`
##
## Nothing here reads the environment, a file or a descriptor. The host fills
## `TerminalProbe` (`host/terminal_probe.nim`) and reads the cache file
## (`host/terminal_cache.nim`); this module only PARSES their bytes and the
## resolver in `capabilities.nim` decides. That is what lets every answer
## combination of the width probe (P0–P6) and every rank of the precedence
## (§5.2) be swept in the fast lane.
##
## ## Documentation, not measurement
##
## The identity tables below (which terminals draw Symbols for Legacy
## Computing themselves, which accept an OSC 52 write, which implement DEC
## 2026) are the spec's §3.2 READINGS of each project's documentation and
## source. They are not measurements; the real-emulator lane that would earn
## them (§13.4) is listed as owed in the milestone. Each row names its source.

import std/[algorithm, json, options, strutils]

export options

# ---------------------------------------------------------------------------
# Settings: the values a user can choose, and where a choice came from
# ---------------------------------------------------------------------------

type
  ChromeTier* = enum
    ## §6.1: a PROMISE about which code points the font and the terminal
    ## render; each tier contains the one after it. Ordered RICHEST FIRST so
    ## the zero value is the `extended` screen every view drew before the
    ## glyph table existed — a model built without a profile paints what it
    ## always painted.
    tierExtended = "extended"
    tierBasic = "basic"
    tierAscii = "ascii"

  GlyphsChoice* = enum
    ## The `glyphs` setting (§5.3). `auto` resolves the tier (§6.1).
    gcAuto = "auto"
    gcAscii = "ascii"
    gcBasic = "basic"
    gcExtended = "extended"

  ModernChoice* = enum
    ## `modern-unicode` (§6.7). The DEFAULT is `off` (the user's decision);
    ## `auto` is a value a user may choose (OQ-T1), never the default.
    mcOff = "off"
    mcOn = "on"
    mcAuto = "auto"

  AmbiguousChoice* = enum
    ## `ambiguous-width` (§5.3): `auto` is measured.
    acAuto = "auto"
    acNarrow = "narrow"
    acWide = "wide"

  ColorsChoice* = enum
    ## `colors` (§7): `auto` is the PLAT-46 ladder.
    ccAuto = "auto"
    ccTrueColor = "truecolor"
    cc256 = "256"
    cc16 = "16"
    ccMono = "mono"

  TerminalChoices* = object
    ## What ONE rank of the precedence says about each terminal axis — a
    ## runtime `:set`, a flag, a `CODETRACER_TUI_*` variable, a
    ## `[terminal "<glob>"]` section or the global settings. `none` is "this
    ## rank says nothing", and the next rank down is asked.
    glyphs*: Option[GlyphsChoice]
    modernUnicode*: Option[ModernChoice]
    ambiguousWidth*: Option[AmbiguousChoice]
    colors*: Option[ColorsChoice]
    probe*: Option[bool]
      ## `terminal-probe`: false turns the start-up round off (§4.8 rule 4).
    reduceMotion*: Option[bool]

  ScopedChoices* = object
    ## A `[terminal "<glob>"]` section (§5.3, OQ-T6).
    glob*: string
    choices*: TerminalChoices

  TerminalPrefs* = object
    ## The remembered settings: global, then the sections scoped to a terminal
    ## identity. Ranks 5 and 4 of §5.2.
    global*: TerminalChoices
    scoped*: seq[ScopedChoices]

proc parseChoice*[T: enum](word: string; v: var T): bool =
  ## `word` as one of `T`'s spellings, case-insensitively.
  let w = word.strip.toLowerAscii
  for e in T:
    if $e == w:
      v = e
      return true
  # The colour depths have two common spellings each.
  when T is ColorsChoice:
    case w
    of "24bit", "true", "rgb": v = ccTrueColor; return true
    of "ansi256", "256color": v = cc256; return true
    of "ansi16", "16color": v = cc16; return true
    of "monochrome", "none", "off": v = ccMono; return true
    else: discard
  false

proc parseOnOffWord*(word: string; v: var bool): bool =
  case word.strip.toLowerAscii
  of "on", "true", "yes", "1": v = true; true
  of "off", "false", "no", "0": v = false; true
  else: false

proc choiceNames*[T: enum](): string =
  var parts: seq[string] = @[]
  for e in T:
    parts.add $e
  parts.join(", ")

proc merge*(above, below: TerminalChoices): TerminalChoices =
  ## `above` where it speaks, else `below`.
  result = below
  if above.glyphs.isSome: result.glyphs = above.glyphs
  if above.modernUnicode.isSome: result.modernUnicode = above.modernUnicode
  if above.ambiguousWidth.isSome: result.ambiguousWidth = above.ambiguousWidth
  if above.colors.isSome: result.colors = above.colors
  if above.probe.isSome: result.probe = above.probe
  if above.reduceMotion.isSome: result.reduceMotion = above.reduceMotion

proc isEmpty*(c: TerminalChoices): bool =
  c.glyphs.isNone and c.modernUnicode.isNone and c.ambiguousWidth.isNone and
    c.colors.isNone and c.probe.isNone and c.reduceMotion.isNone

# ---------------------------------------------------------------------------
# Glob matching for `[terminal "<glob>"]`
# ---------------------------------------------------------------------------

proc globMatch*(pattern, text: string): bool =
  ## `*` (any run) and `?` (one character), case-insensitively — enough for
  ## `kitty*`, `tmux>*`, `foot`.
  let p = pattern.toLowerAscii
  let t = text.toLowerAscii
  var pi, ti = 0
  var star = -1
  var mark = 0
  while ti < t.len:
    if pi < p.len and (p[pi] == '?' or p[pi] == t[ti]):
      inc pi
      inc ti
    elif pi < p.len and p[pi] == '*':
      star = pi
      mark = ti
      inc pi
    elif star >= 0:
      pi = star + 1
      inc mark
      ti = mark
    else:
      return false
  while pi < p.len and p[pi] == '*':
    inc pi
  pi == p.len

# ---------------------------------------------------------------------------
# The terminal's identity (§4.4)
# ---------------------------------------------------------------------------

type
  IdentitySource* = enum
    isUnknown = "unknown"
    isXtversion = "XTVERSION"
    isDa2 = "DA2"
    isTmuxClient = "tmux client_termtype"
    isEnvironment = "environment"
    isCache = "cache"

  TerminalIdentity* = object
    name*: string
      ## The terminal's canonical lower-case name (`kitty`, `foot`, `xterm`,
      ## `vte`, `wezterm`, `ghostty`, …); "" when unknown.
    version*: string
    via*: seq[string]
      ## The multiplexers between this process and the terminal, innermost
      ## first: `@["tmux 3.4"]`.
    remote*: bool
      ## An SSH session (`SSH_CONNECTION` / `SSH_TTY`).
    source*: IdentitySource
    endToEnd*: bool
      ## Whether the OUTER terminal is known through every layer (§6.7's
      ## fourth condition): no multiplexer, or tmux with a known
      ## `client_termtype`. False under screen / zellij or an unknown chain.

proc known*(id: TerminalIdentity): bool = id.name.len > 0

proc chainName*(id: TerminalIdentity): string =
  ## `tmux>kitty`: the multiplexers outermost-last joined to the terminal.
  var parts: seq[string] = @[]
  for v in id.via:
    parts.add v.split(' ')[0].toLowerAscii
  parts.add(if id.name.len > 0: id.name else: "unknown")
  parts.join(">")

proc describe*(id: TerminalIdentity): string =
  ## `kitty 0.36.4 via tmux 3.4`.
  result = if id.name.len > 0: id.name else: "unknown terminal"
  if id.version.len > 0:
    result.add " " & id.version
  if id.via.len > 0:
    result.add " via " & id.via.join(" via ")
  if id.remote:
    result.add " (remote)"

proc canonicalName*(raw: string): string =
  ## A terminal's self-reported name, as the tables below spell it.
  let r = raw.strip.toLowerAscii
  case r
  of "xterm", "xterm(": "xterm"
  of "vte": "vte"
  of "iterm2", "iterm.app": "iterm2"
  of "apple_terminal": "terminal.app"
  of "wezterm": "wezterm"
  of "ghostty": "ghostty"
  of "kitty", "xterm-kitty": "kitty"
  of "foot", "foot-extra": "foot"
  of "alacritty", "alacritty-direct": "alacritty"
  of "konsole": "konsole"
  of "tmux": "tmux"
  of "screen": "screen"
  of "xterm.js", "vscode": "xterm.js"
  of "contour": "contour"
  of "mintty": "mintty"
  of "windows terminal", "windowsterminal": "windows-terminal"
  else: r

proc parseXtversionText*(text: string): (string, string) =
  ## `kitty(0.36.4)`, `XTerm(379)`, `tmux 3.4`, `WezTerm 20240203-…`,
  ## `VTE(7600)` → `(name, version)`. VTE's number is its version times
  ## 10000 (`7600` → `0.76.0`), as its DA2 `Pv` is.
  let t = text.strip
  var name, version = ""
  let paren = t.find('(')
  let space = t.find(' ')
  if paren > 0 and (space < 0 or paren < space):
    name = t[0 ..< paren]
    let close = t.find(')', paren)
    version = if close > paren: t[paren + 1 ..< close] else: t[paren + 1 .. ^1]
  elif space > 0:
    name = t[0 ..< space]
    version = t[space + 1 .. ^1].strip
  else:
    name = t
  name = canonicalName(name)
  if name == "vte" and version.len >= 4 and version.allCharsInSet(Digits):
    let n = parseInt(version)
    version = $(n div 10000) & "." & $((n div 100) mod 100) & "." & $(n mod 100)
  (name, version)

proc parseXtversionReply*(token: string): (bool, string) =
  ## `DCS > | <text> ST` → `(true, text)`.
  const prefix = "\x1bP>|"
  if not token.startsWith(prefix):
    return (false, "")
  var body = token[prefix.len .. ^1]
  if body.endsWith("\x1b\\"):
    body = body[0 ..< body.len - 2]
  elif body.endsWith("\x07"):
    body = body[0 ..< body.len - 1]
  (true, body)

proc isDa2Reply*(token: string): bool =
  ## `CSI > Pp ; Pv ; Pc c`.
  if not (token.len >= 5 and token.startsWith("\x1b[>") and token[^1] == 'c'):
    return false
  for c in token[3 ..< token.len - 1]:
    if c notin {'0'..'9', ';'}: return false
  true

proc parseDa2*(token: string): (bool, int, int) =
  ## `(ok, Pp, Pv)`.
  if not isDa2Reply(token):
    return (false, 0, 0)
  let parts = token[3 ..< token.len - 1].split(';')
  var pp, pv = 0
  try:
    if parts.len > 0 and parts[0].len > 0: pp = parseInt(parts[0])
    if parts.len > 1 and parts[1].len > 0: pv = parseInt(parts[1])
  except ValueError:
    return (false, 0, 0)
  (true, pp, pv)

proc identityOfDa2*(pp, pv: int): (string, string) =
  ## The terminals DA2 identifies when XTVERSION is silent (§4.4): xterm
  ## (`41`, its patch level), screen (`83`), tmux (`84`), and VTE (`65` with
  ## a four-digit version, `6800` → `0.68.0`). Anything else: "".
  case pp
  of 41: ("xterm", $pv)
  of 83: ("screen", $pv)
  of 84: ("tmux", $pv)
  of 65:
    if pv >= 1000 and pv < 100000:
      ("vte", $(pv div 10000) & "." & $((pv div 100) mod 100) & "." & $(pv mod 100))
    else: ("", "")
  else: ("", "")

proc parseDecrqm*(token: string): (bool, int, int) =
  ## `CSI ? <mode> ; <Ps> $ y` → `(ok, mode, Ps)`. Ps 0 is "not recognised"
  ## — a NEGATIVE answer; 1 set, 2 reset, 3 permanently set, 4 permanently
  ## reset.
  if not (token.startsWith("\x1b[?") and token.endsWith("$y")):
    return (false, 0, 0)
  let parts = token[3 ..< token.len - 2].split(';')
  if parts.len != 2:
    return (false, 0, 0)
  try:
    (true, parseInt(parts[0]), parseInt(parts[1]))
  except ValueError:
    (false, 0, 0)

proc parseCpr*(token: string): (bool, int, int) =
  ## `CSI <row> ; <col> R` → `(ok, row, col)`.
  if not (token.len >= 6 and token.startsWith("\x1b[") and token[^1] == 'R'):
    return (false, 0, 0)
  let parts = token[2 ..< token.len - 1].split(';')
  if parts.len != 2:
    return (false, 0, 0)
  try:
    (true, parseInt(parts[0]), parseInt(parts[1]))
  except ValueError:
    (false, 0, 0)

proc versionAtLeast*(have, want: string): bool =
  ## Dotted numeric comparison; a missing component is 0. A version that is
  ## not numeric at all is NOT at least anything (an unknown version cannot
  ## satisfy a minimum).
  if have.len == 0:
    return false
  proc nums(s: string): seq[int] =
    for piece in s.split({'.', '-', '+', ' '}):
      var digits = ""
      for c in piece:
        if c in Digits: digits.add c
        else: break
      if digits.len == 0:
        break
      result.add parseInt(digits)
  let a = nums(have)
  let b = nums(want)
  if a.len == 0:
    return false
  for i in 0 ..< max(a.len, b.len):
    let x = if i < a.len: a[i] else: 0
    let y = if i < b.len: b[i] else: 0
    if x != y:
      return x > y
  true

# ---------------------------------------------------------------------------
# What a terminal is known (from its documentation) to do
# ---------------------------------------------------------------------------

type
  LegacyDrawer* = object
    name*: string
    minVersion*: string
    firstCp*, lastCp*: int
      ## The Legacy Computing range it draws without a font.
    source*: string

const
  ModernGlyphRange* = (0x1FB82, 0x1FB8B)
    ## The Symbols for Legacy Computing code points the glyph table actually
    ## draws (`🮂 … 🮆`, `🮇 🮈`, `🮉 🮊 🮋`). `auto` checks THESE against a
    ## terminal's range, not the block as a whole (§3.2 note).

  LegacyDrawers*: array[4, LegacyDrawer] = [
    LegacyDrawer(name: "kitty", minVersion: "0.20.0", firstCp: 0x1FB00,
                 lastCp: 0x1FBAE, source: "kitty/fonts.c, kitty/decorations.c"),
    LegacyDrawer(name: "ghostty", minVersion: "1.0.0", firstCp: 0x1FB00,
                 lastCp: 0x1FBAF, source: "ghostty src/font/sprite/draw"),
    LegacyDrawer(name: "foot", minVersion: "1.8.0", firstCp: 0x1FB70,
                 lastCp: 0x1FB8B, source: "foot CHANGELOG 1.8.0"),
    LegacyDrawer(name: "vte", minVersion: "0.60.0", firstCp: 0x1FB00,
                 lastCp: 0x1FBAE, source: "VTE src/minifont.cc")]
    ## §3.2's terminals that draw the range THEMSELVES and identify with a
    ## version (XTVERSION or DA2). Windows Terminal (≥ 1.25), Alacritty
    ## (≥ 0.17) and xterm.js with WebGL also draw these code points, but none
    ## of them reports a version the probe can read, so `auto` cannot check
    ## the minimum and leaves them off. DOCUMENTATION-DERIVED, not measured.

  SyncIdentities*: array[7, (string, string)] = [
    ("kitty", ""), ("foot", "1.8.0"), ("wezterm", ""), ("ghostty", ""),
    ("alacritty", "0.13.0"), ("iterm2", ""), ("contour", "")]
    ## DEC 2026 by identity, the no-reply fallback (§8).

  Osc52Writers*: array[7, string] = [
    "kitty", "wezterm", "ghostty", "foot", "alacritty", "windows-terminal",
    "iterm2"]
    ## Terminals documented to accept an OSC 52 write (§3.2). iTerm2 only
    ## behind a preference.

proc drawsModernGlyphs*(id: TerminalIdentity): (bool, string) =
  ## §6.7's first two conditions: `(true, why)` when the identity draws every
  ## code point the glyph table uses, at a version that has them.
  for d in LegacyDrawers:
    if d.name == id.name:
      if d.firstCp > ModernGlyphRange[0] or d.lastCp < ModernGlyphRange[1]:
        return (false, id.name & " draws only part of the range")
      if not versionAtLeast(id.version, d.minVersion):
        return (false, id.name & " " & (if id.version.len > 0: id.version
                                       else: "(version unknown)") &
                        " predates " & d.minVersion)
      return (true, id.name & " draws U+" & toHex(d.firstCp, 5) & "-" &
                    toHex(d.lastCp, 5) & " itself")
  (false, (if id.known: id.name else: "an unknown terminal") &
          " is not known to draw Legacy Computing itself")

proc syncByIdentity*(id: TerminalIdentity): bool =
  for (name, minV) in SyncIdentities:
    if name == id.name and (minV.len == 0 or versionAtLeast(id.version, minV)):
      return true
  false

# ---------------------------------------------------------------------------
# The width probe (§4.3)
# ---------------------------------------------------------------------------

type
  WidthProbe* = enum
    ## The probes, in the order they are written. P0 and P1 are ONE probe.
    wpEllipsis = "P1"   ## `…` U+2026 — UTF-8 decoding (P0) and the EAW-A policy
    wpBlock = "P2"      ## `▕` U+2595 — the policy for box and block glyphs
    wpLegacy = "P3"     ## `🮇` U+1FB87 — the width table's Unicode version
    wpPicto = "P4"      ## `⏮` U+23EE — text-default pictographs drawn wide
    wpWide = "P5"       ## `中` U+4E2D — wide glyphs at all
    wpCluster = "P6"    ## `👩‍💻` — grapheme clustering

  Knowledge* = enum
    knUnknown = "unknown"
    knNo = "no"
    knYes = "yes"

  AmbiguousPolicy* = enum
    apUnknown = "unknown"
    apNarrow = "narrow"
    apWide = "wide"

  WidthModel* = object
    ## What came out of the width probe — §4.3's model.
    answered*: array[WidthProbe, int]
      ## The measured width of each probe; -1 when it was not answered.
    utf8*: Knowledge
    ambiguous*: AmbiguousPolicy
    blockAmbig*: AmbiguousPolicy
    unicode13*: Knowledge
    pictoWide*: Knowledge
    wideOk*: Knowledge
    clusters*: Knowledge

const
  WidthProbeText*: array[WidthProbe, string] = [
    "…", "▕", "\U0001FB87", "⏮", "中",
    "\U0001F469‍\U0001F4BB"]

proc noWidthAnswers*(): array[WidthProbe, int] =
  for p in WidthProbe:
    result[p] = -1

proc widthModelOf*(answered: array[WidthProbe, int];
                   graphemeDecrqm = -1): WidthModel =
  ## §4.3's derivation. `graphemeDecrqm` is DECRQM 2027's `Ps` (-1 when not
  ## answered).
  result.answered = answered
  let p1 = answered[wpEllipsis]
  result.utf8 = if p1 < 0: knUnknown elif p1 == 3: knNo else: knYes
  proc policy(w: int): AmbiguousPolicy =
    if w == 2: apWide elif w == 1: apNarrow else: apUnknown
  # A terminal that decoded `…` as three Latin-1 characters says nothing
  # about the ambiguous policy.
  result.ambiguous = if result.utf8 == knNo: apUnknown else: policy(p1)
  result.blockAmbig =
    if result.utf8 == knNo: apUnknown else: policy(answered[wpBlock])
  proc knows(w, yes: int): Knowledge =
    if w < 0: knUnknown elif w == yes: knYes else: knNo
  result.unicode13 = knows(answered[wpLegacy], 1)
  result.pictoWide = knows(answered[wpPicto], 2)
  result.wideOk = knows(answered[wpWide], 2)
  if graphemeDecrqm in {1, 2, 3, 4}:
    result.clusters = knYes
  else:
    result.clusters = knows(answered[wpCluster], 2)
  if result.utf8 == knNo:
    result.unicode13 = knUnknown
    result.pictoWide = knUnknown
    result.wideOk = knUnknown
    result.clusters = knUnknown

proc measured*(w: WidthModel): bool =
  for p in WidthProbe:
    if w.answered[p] >= 0:
      return true
  false

proc describe*(w: WidthModel): string =
  if not w.measured:
    return "unmeasured"
  "ambiguous " & $w.ambiguous & " (P1=" & $w.answered[wpEllipsis] & ")" &
    ", blocks " & $w.blockAmbig & " (P2=" & $w.answered[wpBlock] & ")" &
    ", Unicode 13 " & $w.unicode13 & " (P3=" & $w.answered[wpLegacy] & ")" &
    ", wide " & $w.wideOk & " (P5=" & $w.answered[wpWide] & ")" &
    ", clusters " & $w.clusters & " (P6=" & $w.answered[wpCluster] & ")"

# ---------------------------------------------------------------------------
# East Asian Width "A", for the chrome code points (§6.2)
# ---------------------------------------------------------------------------

const
  EawAmbiguousChrome* = [
    "…", "─", "│", "━", "┃", "┊", "▏", "▕", "▁", "▂", "▃", "▄", "▅", "▆",
    "▇", "█", "▉", "▊", "▋", "▌", "▍", "▎", "▀", "▒", "▓", "▔", "●", "○",
    "◆", "◇", "▲", "▶", "▼", "■", "□", "·", "→", "←", "↑", "↓", "×",
    "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "═", "║", "░"]
    ## §6.2's list of chrome glyphs whose East Asian Width is `A` (and the
    ## light box corners and tees, which are `A` too). `░` is `A` in
    ## EastAsianWidth.txt despite §6.2 listing it as not; the file wins.

proc isEawAmbiguous*(glyph: string): bool =
  glyph in EawAmbiguousChrome

# ---------------------------------------------------------------------------
# CJK locales (OQ-T3)
# ---------------------------------------------------------------------------

proc isCjkLocale*(locale: string): bool =
  let l = locale.toLowerAscii
  l.startsWith("ja") or l.startsWith("zh") or l.startsWith("ko")

# ---------------------------------------------------------------------------
# The per-terminal cache (§4.7)
# ---------------------------------------------------------------------------

type
  CachedProfile* = object
    ## The last answers a terminal gave, for frame 0 on a slow link. Never
    ## a substitute for asking: live answers always replace it.
    key*: string
    identityName*, identityVersion*: string
    widths*: array[WidthProbe, int]
    sync2026*: int
    grapheme2027*: int
      ## DECRQM `Ps`, -1 unanswered.
    truecolor*: bool
    rttMs*: int
    stampSec*: int64
      ## When it was written, in seconds since the epoch.

const
  CacheMaxEntries* = 32
  CacheMaxAgeSec* = 90'i64 * 24 * 3600

proc cacheKey*(term, termProgram, termProgramVersion: string;
               multiplexers: seq[string]; remote, utf8Locale: bool): string =
  ## The environment fingerprint available BEFORE any answer (§4.7).
  [term, termProgram, termProgramVersion, multiplexers.join("+"),
   (if remote: "ssh" else: "local"),
   (if utf8Locale: "utf8" else: "other")].join("|")

proc toJson*(c: CachedProfile): JsonNode =
  var widths = newJArray()
  for p in WidthProbe:
    widths.add newJInt(c.widths[p])
  %*{"key": c.key, "name": c.identityName, "version": c.identityVersion,
     "widths": widths, "sync2026": c.sync2026,
     "grapheme2027": c.grapheme2027, "truecolor": c.truecolor,
     "rttMs": c.rttMs, "stamp": c.stampSec}

proc cachedProfileOf*(n: JsonNode): (bool, CachedProfile) =
  if n.kind != JObject or not n.hasKey("key"):
    return (false, CachedProfile())
  var c = CachedProfile(key: n{"key"}.getStr,
                        identityName: n{"name"}.getStr,
                        identityVersion: n{"version"}.getStr,
                        sync2026: n{"sync2026"}.getInt(-1),
                        grapheme2027: n{"grapheme2027"}.getInt(-1),
                        truecolor: n{"truecolor"}.getBool,
                        rttMs: n{"rttMs"}.getInt(-1),
                        stampSec: n{"stamp"}.getBiggestInt)
  c.widths = noWidthAnswers()
  let w = n{"widths"}
  if not w.isNil and w.kind == JArray:
    var i = 0
    for p in WidthProbe:
      if i < w.len: c.widths[p] = w[i].getInt(-1)
      inc i
  (c.key.len > 0, c)

proc decodeCache*(text: string): (bool, seq[CachedProfile], string) =
  ## The file's entries. `(false, …, why)` for a file that is not a cache —
  ## reported and left as it is (the `tui-layout.json` rule).
  if text.strip.len == 0:
    return (true, @[], "")
  var root: JsonNode
  try:
    root = parseJson(text)
  except CatchableError as e:
    return (false, @[], "not JSON: " & e.msg)
  if root.kind != JObject or root{"profiles"}.isNil or
     root{"profiles"}.kind != JArray:
    return (false, @[], "no \"profiles\" list")
  var entries: seq[CachedProfile] = @[]
  for item in root["profiles"]:
    let (ok, c) = cachedProfileOf(item)
    if ok: entries.add c
  (true, entries, "")

proc encodeCache*(entries: seq[CachedProfile]): string =
  var list = newJArray()
  for e in entries:
    list.add e.toJson
  $(%*{"version": 1, "profiles": list}) & "\n"

proc lookupCache*(entries: seq[CachedProfile]; key: string;
                  nowSec: int64): Option[CachedProfile] =
  ## The live entry for `key`; entries older than 90 days are ignored.
  for e in entries:
    if e.key == key and nowSec - e.stampSec <= CacheMaxAgeSec:
      return some(e)
  none(CachedProfile)

proc rememberInCache*(entries: seq[CachedProfile];
                      entry: CachedProfile): seq[CachedProfile] =
  ## `entry` first, the others after it most recent first, at most 32 (the
  ## least recently used dropped).
  result = @[entry]
  var rest = entries
  rest.sort(proc(a, b: CachedProfile): int = cmp(b.stampSec, a.stampSec))
  for e in rest:
    if e.key != entry.key and result.len < CacheMaxEntries:
      result.add e
