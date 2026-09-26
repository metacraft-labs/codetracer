## vim_import.nim — PLAT-36: a user's `.vimrc` / `init.vim`, translated into
## bindings over PLAT-30's 224 named operations, **plus a report naming exactly
## what could not be translated**.
##
## `codetracer-specs/GUI/Editing-Operations-And-Keymaps.md` §6 owns the
## behaviour. Three sentences of it decide the shape of this module:
##
##   §6.3  *"A partial import that reports exactly what it could not translate
##         is the useful product; a silent partial import is worse than none,
##         because the user discovers the gap through muscle memory failing —
##         at the moment they are doing something else."*
##   §6.4  *"a translated mapping that behaves slightly differently from Vim's
##         is a defect to be reported in the same report rather than a
##         feature."*
##   §6.2  *"Anything that invokes Vimscript, Lua or a plugin."* is not
##         translatable, *"and no amount of pattern-matching makes it so."*
##
## ===========================================================================
## THE OUTCOME IS A VARIANT, AND THAT IS THE MILESTONE
## ===========================================================================
##
## Every source line becomes exactly one `LineOutcome`, and `LineOutcome` is an
## object VARIANT over `OutcomeKind`. An untranslatable line is not a `None`,
## not an empty `seq`, and not a line that fell off the end of a `case`: it is
## `okReported`, and `okReported` is the only shape that CARRIES a reason. A
## translated line cannot be read for a reason, because the field is not there.
##
## The five kinds exist because THREE DIFFERENT THINGS PRODUCE NO BINDING and
## collapsing them is this campaign's most repeated defect:
##
##   `okUnbind`         an `unmap`/`mapclear`, or a right-hand side of `<Nop>`.
##                      It binds nothing ON PURPOSE. `cleared == 0` is a
##                      legitimate answer — `unmap` of a chord nothing claimed
##                      is what Vim does too — and is NOT an error.
##   `okUniqueRefused`  a `<unique>` mapping whose chord was already claimed.
##                      Vim refuses to install it; so do we, by name.
##   `okReported`       we could not translate it. THIS is the failure.
##
## *"I could not read this"* and *"this is empty"* are different answers and
## are different constructors here. A `seq[EditingBinding]` of length zero
## would have been all three at once.
##
## ===========================================================================
## THE PARTITION LAW, AND WHY THE TOTAL IS COUNTED TWICE
## ===========================================================================
##
## The law is `translated + reported == total mapping lines`, per file. If both
## sides were derived from `outcomes`, it would read `|A| + |B| == |A ∪ B|` and
## could not fail — Verification-Harness-Traps §22, a cross-check whose two
## sides are computed from the same expression. So `countMappingLines` is a
## SECOND pass over the raw text that never looks at an outcome, and the
## corpus's `manifest.tsv` carries a THIRD number produced by a Python reader
## that shares no code with this module at all. The suite asserts all three.
##
## ===========================================================================
## WHAT IS NOT INTERPRETED, STATED ONCE
## ===========================================================================
##
## There is no Vimscript engine here, no Lua, and no plugin emulation. An ex
## command on the right-hand side — `:w<CR>`, `:nohlsearch<CR>`, `:call f()` —
## is *invokes Vimscript* and is reported, including the ones whose effect this
## editor happens to have an operation for. Translating a hand-picked subset of
## ex commands would be the beginning of the interpreter §6.4 refuses, and the
## line between "easy" and "hard" would be invisible to the user.
##
## THE ONE LEXICAL EXCEPTION IS `mapleader`, and it is not an interpretation.
## `<leader>` appears in 103 lines of the pinned corpus, and Vim's own default
## for `mapleader` is `\`. We read a `let mapleader = "<string literal>"` that
## sits at COLUMN ZERO — unconditional, outside any `if` or `function` block —
## and nothing else. A `mapleader` assigned from a variable, or assigned only
## inside a conditional, leaves `<leader>` unresolved and every mapping using
## it is reported as *invokes Vimscript*. That distinction is live in the
## corpus: `amix/vimrc` assigns a literal at column zero and `spf13-vim`
## assigns `g:spf13_leader` inside an `if`, so one file's `<leader>` mappings
## translate and the other's are reported.

import std/[strutils, tables]

import ./editing_keymap
import ./vim_keymap

export editing_keymap

# ===========================================================================
# §6.1's MAP FAMILIES — the 22 published spellings
# ===========================================================================

type
  VimMapFamily* = enum
    ## `Editing-Operations-And-Keymaps.md` §6.1's list, as an enum whose `$` is
    ## the published spelling. The sweep in the suite is over THIS enum, so it
    ## is over the published list rather than over the spellings the corpus
    ## happens to contain — a corpus-driven sweep grades the importer on the
    ## files somebody chose.
    vmfMap = "map"
    vmfNmap = "nmap"
    vmfVmap = "vmap"
    vmfXmap = "xmap"
    vmfSmap = "smap"
    vmfOmap = "omap"
    vmfImap = "imap"
    vmfCmap = "cmap"
    vmfLmap = "lmap"
    vmfNoremap = "noremap"
    vmfNnoremap = "nnoremap"
    vmfVnoremap = "vnoremap"
    vmfXnoremap = "xnoremap"
    vmfSnoremap = "snoremap"
    vmfOnoremap = "onoremap"
    vmfInoremap = "inoremap"
    vmfCnoremap = "cnoremap"
    vmfLnoremap = "lnoremap"
    vmfMapBang = "map!"
    vmfNoremapBang = "noremap!"
    vmfUnmap = "unmap"
    vmfMapclear = "mapclear"

  ImportReason* = enum
    ## **THE CLOSED SET**, §6.3. Its five members are compared row by row
    ## against the parenthesised list in the spec by
    ## `test_editor_vim_import.nim`, in both directions with the cardinality
    ## asserted, so a member added here and not published (or the other way
    ## round) is a red run. Each one has a planted line in the verification
    ## gate, because a reason no planted line can produce is a reason nothing
    ## has ever emitted, and a closed set with an unreachable member is an open
    ## set wearing a type.
    irVimscript = "invokes Vimscript"
    irPlugin = "names a plugin"
    irNoOperation = "the right-hand side uses an operation this editor does not have"
    irNoOption = "the option has no equivalent"
    irSyntax = "the syntax was not understood"

  VimMapArgument* = enum
    ## §6.1's five `<...>` arguments. Each gets an EXPLICIT RECORDED DECISION
    ## rather than a silent drop — `MapArgumentDecisions` below.
    vmaBuffer = "<buffer>"
    vmaSilent = "<silent>"
    vmaExpr = "<expr>"
    vmaNowait = "<nowait>"
    vmaUnique = "<unique>"

  ArgumentDecision* = enum
    ## What this importer DOES with each of the five. The enum exists so the
    ## decision is a value a test can assert against, not a paragraph.
    adGlobalWithDivergence = "imported as a global binding, with a divergence recorded"
    adNoDistinctionHere = "honoured trivially: nothing on this side echoes"
    adRefusesTheMapping = "refuses the mapping: the right-hand side is an expression"
    adTimeoutIsGlobal = "imported, with a divergence recorded: the resolver's timeout is not per binding"
    adEnforced = "enforced: an already-claimed chord leaves the mapping uninstalled"

  VimOptionId* = enum
    ## §6.1's *"small set of `set` options that this model genuinely has"*.
    voTabstop = "tabstop"
    voShiftwidth = "shiftwidth"
    voExpandtab = "expandtab"
    voWrap = "wrap"
    voNumber = "number"
    voRelativenumber = "relativenumber"
    voIgnorecase = "ignorecase"
    voSmartcase = "smartcase"
    voTimeoutlen = "timeoutlen"
    voScrolloff = "scrolloff"

  OutcomeKind* = enum
    okBinding = "binding"
    okUnbind = "unbind"
    okUniqueRefused = "unique-refused"
    okOption = "option"
    okReported = "reported"

  LineKind* = enum
    ## What the line IS, before anything is asked about whether it worked.
    ## `lkBlank` and `lkOther` are not mapping lines and are not option lines,
    ## so they are in neither partition — and they are TYPED rather than
    ## dropped, so "this file has 400 lines and 40 of them are mappings" is a
    ## statement the outcome list can answer.
    lkBlank = "blank"
    lkOther = "other"
    lkSet = "set"
    lkMapping = "mapping"

  LineOutcome* = object
    line*: int              ## 1-based, and the FIRST line of a continued command
    text*: string           ## the logical line, continuations joined
    kind*: LineKind
    case outcome*: OutcomeKind
    of okBinding:
      family*: VimMapFamily
      chords*: seq[string]
      operations*: seq[string]
      macroId*: string      ## "" when the right-hand side was ONE operation
      modes*: set[EditingMode]
    of okUnbind:
      unbindFamily*: VimMapFamily
      cleared*: int         ## 0 is a legitimate answer, not a failure
    of okUniqueRefused:
      claimedBy*: string
    of okOption:
      option*: VimOptionId
      value*: string
    of okReported:
      reason*: ImportReason
      detail*: string

  ImportReportEntry* = object
    ## §6.3's report row: the line number, the text, and a reason from the
    ## closed set. Never a generic failure.
    line*: int
    text*: string
    reason*: ImportReason
    detail*: string

  DivergenceEntry* = object
    ## §6.4: *"a translated mapping that behaves slightly differently from
    ## Vim's is a defect to be reported in the same report rather than a
    ## feature."* A divergence is attached to a line that WAS translated, so it
    ## is a second list rather than a sixth reason.
    line*: int
    text*: string
    note*: string

  VimOptionValue* = object
    given*: bool
    raw*: string
    number*: int
    boolean*: bool

  VimImport* = object
    keymap*: EditingKeymap
    macros*: Table[string, seq[string]]
      ## Multi-operation right-hand sides, keyed by the id the binding replays.
      ## Install into `EditorState.macros` before resolving against the keymap.
    mapleader*: string
    mapleaderResolved*: bool
    options*: array[VimOptionId, VimOptionValue]
    outcomes*: seq[LineOutcome]
    report*: seq[ImportReportEntry]
    divergences*: seq[DivergenceEntry]

const
  # THE FIVE DECISIONS §6.1 ASKS FOR, AS DATA RATHER THAN AS A PARAGRAPH.
  #
  # `<buffer>`  §4.3's scopes are product mode, pane, editing mode and text
  #             entry. There is no per-buffer dimension, so a `<buffer>`
  #             mapping becomes a global one and the line carries a divergence
  #             saying so. Dropping it would be the silent partial import §6.3
  #             calls worse than none.
  # `<silent>`  Vim's `<silent>` suppresses the ECHO of the mapping's command
  #             on the command line. Nothing on this side echoes a resolution,
  #             so the flag distinguishes nothing and the mapping is imported
  #             unchanged. This is the one of the five with NO divergence, and
  #             that is a claim rather than an omission.
  # `<expr>`    §6.2 names it: *"an `<expr>` mapping whose value is computed is
  #             not translatable"*. The right-hand side is a Vimscript
  #             expression, so the reason is `irVimscript`.
  # `<nowait>`  `EditingPendingTimeoutMs` is one value for the whole resolver —
  #             *"one value, Vim's own `timeoutlen`"*. A per-binding "do not
  #             wait" is not expressible, so the mapping is imported and the
  #             line carries a divergence.
  # `<unique>`  Vim refuses to install a `<unique>` mapping over an existing one
  #             and errors. We refuse too, and the line is `okUniqueRefused` —
  #             neither a translation nor a failure to translate, and it has its
  #             own constructor for exactly that reason.
  MapArgumentDecisions*: array[VimMapArgument, ArgumentDecision] = [
    vmaBuffer: adGlobalWithDivergence,
    vmaSilent: adNoDistinctionHere,
    vmaExpr: adRefusesTheMapping,
    vmaNowait: adTimeoutIsGlobal,
    vmaUnique: adEnforced,
  ]

  MapFamilyCount = 22
  ImportReasonCount = 5
  VimMapArgumentCount = 5
  VimOptionCount = 10

  DefaultMapleader* = "\\"
    ## Vim's own default (`:help mapleader`): *"if it is not set, the
    ## backslash is used"*.

  VisualLikeModes = {emVisual, emVisualLine, emVisualBlock}

# ===========================================================================
# FAMILIES → MODES, AND THE THREE THAT NEED A DIVERGENCE
# ===========================================================================

func familyModes*(f: VimMapFamily): set[EditingMode] =
  ## The editing modes a family's mapping is installed in.
  case f
  of vmfMap, vmfNoremap:
    {emNormal, emOperatorPending} + VisualLikeModes
  of vmfNmap, vmfNnoremap: {emNormal}
  of vmfVmap, vmfVnoremap, vmfXmap, vmfXnoremap, vmfSmap, vmfSnoremap:
    VisualLikeModes
  of vmfOmap, vmfOnoremap: {emOperatorPending}
  of vmfImap, vmfInoremap, vmfCmap, vmfCnoremap, vmfLmap, vmfLnoremap,
     vmfMapBang, vmfNoremapBang: {emInsert}
  of vmfUnmap, vmfMapclear: {emNormal, emOperatorPending} + VisualLikeModes

func familyPanes*(f: VimMapFamily): set[EditingPane] =
  ## A `cmap` is Vim's COMMAND LINE, which is text entry outside the document.
  ## §4.3 has a `pane` dimension and `epOtherPane` is exactly that place, so
  ## the mapping lands somewhere real instead of being dropped.
  case f
  of vmfCmap, vmfCnoremap: {epOtherPane}
  of vmfMapBang, vmfNoremapBang, vmfLmap, vmfLnoremap: {}   ## every pane
  else: {epEditor}

func familyDivergence*(f: VimMapFamily): string =
  ## The note §6.4 asks for, for the families whose Vim mode has no exact
  ## counterpart here. "" means the family maps across exactly.
  case f
  of vmfSmap, vmfSnoremap:
    "Vim's Select mode is not a mode this editor has; the mapping is installed " &
      "in the three visual modes, where Vim would have kept it out of Visual"
  of vmfCmap, vmfCnoremap:
    "Vim's Command-line mode is not an editing mode here; the mapping is " &
      "installed as insert-mode text entry outside the editor pane"
  of vmfLmap, vmfLnoremap:
    "Vim's language mappings apply when 'iminsert' selects a language keymap; " &
      "this editor has no such switch, so the mapping is unconditional"
  of vmfMapBang, vmfNoremapBang:
    "Vim's `!` is Insert AND Command-line; this editor has one text-entry " &
      "mode, so the mapping is installed once"
  of vmfVmap, vmfVnoremap:
    "Vim's `vmap` is Visual AND Select; this editor has no Select mode, so " &
      "the mapping is installed in the three visual modes only"
  else: ""

func startModeOf(f: VimMapFamily): EditingMode =
  ## The mode the RIGHT-HAND SIDE is read in. Vim reads a mapping's right-hand
  ## side in the mode the mapping fires in, so a `nnoremap`'s `dw` is normal
  ## mode and an `inoremap`'s `abc` is three characters.
  let m = familyModes(f)
  if emNormal in m: emNormal
  elif emOperatorPending in m: emOperatorPending
  elif emVisual in m: emVisual
  else: emInsert

func isTextEntryMode*(m: EditingMode): bool =
  ## §4.3's text-entry dimension read as what it says — *"a mode that is
  ## accepting text"*. Insert and Replace accept text; normal, the three
  ## visual modes and operator-pending spell commands.
  m in {emInsert, emReplace}

# ===========================================================================
# THE SPELLING TABLE — the 22, their abbreviations, and their mode prefixes
# ===========================================================================

const
  FamilySpellings: array[VimMapFamily, string] = [
    vmfMap: "map", vmfNmap: "nmap", vmfVmap: "vmap", vmfXmap: "xmap",
    vmfSmap: "smap", vmfOmap: "omap", vmfImap: "imap", vmfCmap: "cmap",
    vmfLmap: "lmap", vmfNoremap: "noremap", vmfNnoremap: "nnoremap",
    vmfVnoremap: "vnoremap", vmfXnoremap: "xnoremap", vmfSnoremap: "snoremap",
    vmfOnoremap: "onoremap", vmfInoremap: "inoremap", vmfCnoremap: "cnoremap",
    vmfLnoremap: "lnoremap", vmfMapBang: "map!", vmfNoremapBang: "noremap!",
    vmfUnmap: "unmap", vmfMapclear: "mapclear",
  ]

  FamilyMinimal: array[VimMapFamily, string] = [
    ## Vim's documented minimal abbreviation for each command (`:help
    ## :map`, `:help :noremap`, …). `cno` for `cnoremap` is in the pinned
    ## corpus five times, so recognising abbreviations is not a nicety: the
    ## alternative is five mapping lines silently classified as "some other
    ## Vimscript", which is a lost line and a lost line is indistinguishable
    ## from a line the user never wrote.
    vmfMap: "map", vmfNmap: "nm", vmfVmap: "vm", vmfXmap: "xm",
    vmfSmap: "sm", vmfOmap: "om", vmfImap: "im", vmfCmap: "cm",
    vmfLmap: "lm", vmfNoremap: "no", vmfNnoremap: "nn",
    vmfVnoremap: "vn", vmfXnoremap: "xn", vmfSnoremap: "snor",
    vmfOnoremap: "ono", vmfInoremap: "ino", vmfCnoremap: "cno",
    vmfLnoremap: "ln", vmfMapBang: "map!", vmfNoremapBang: "no!",
    vmfUnmap: "unm", vmfMapclear: "mapc",
  ]

  UnmapPrefixes = "nvxsoicl"
    ## `nunmap`, `vunmap`, … fold onto `vmfUnmap` with the prefix deciding the
    ## modes; likewise `nmapclear`. The published list of 22 does not spell
    ## them out and neither does this enum — but a line that names one is a
    ## mapping line, and classifying it as "other Vimscript" would lose it.

func modesOfPrefix(c: char): set[EditingMode] =
  case c
  of 'n': {emNormal}
  of 'v', 's': VisualLikeModes
  of 'x': VisualLikeModes
  of 'o': {emOperatorPending}
  of 'i', 'c', 'l': {emInsert}
  else: {}

type
  CommandToken = object
    isMapping: bool
    family: VimMapFamily
    modeOverride: set[EditingMode]   ## non-empty for `nunmap`-style spellings
    spelled: string

func matchFamily(word: string): CommandToken =
  ## Read the first word of a line as one of the 22, by full spelling or by any
  ## prefix at least as long as Vim's minimal abbreviation.
  result = CommandToken(isMapping: false, family: vmfMap, modeOverride: {},
                        spelled: word)
  if word.len == 0: return
  # The bang is part of the spelling for `map!` / `noremap!` and is a separate
  # thing for `unmap!`, which Vim also accepts.
  for f in VimMapFamily:
    if word == FamilySpellings[f]:
      return CommandToken(isMapping: true, family: f, modeOverride: {},
                          spelled: word)
  for f in VimMapFamily:
    let full = FamilySpellings[f]
    let minimal = FamilyMinimal[f]
    if word.len >= minimal.len and word.len <= full.len and
       full.startsWith(word) and word.startsWith(minimal):
      return CommandToken(isMapping: true, family: f, modeOverride: {},
                          spelled: word)
  # `nunmap`, `vunmap`, …, `unmap!`, and `nmapclear`, `imapclear`, …
  if word.len >= 2 and word[0] in UnmapPrefixes:
    let rest = word[1 .. ^1]
    if rest.len >= 3 and "unmap".startsWith(rest.strip(chars = {'!'})):
      return CommandToken(isMapping: true, family: vmfUnmap,
                          modeOverride: modesOfPrefix(word[0]), spelled: word)
    if rest.len >= 4 and "mapclear".startsWith(rest.strip(chars = {'!'})):
      return CommandToken(isMapping: true, family: vmfMapclear,
                          modeOverride: modesOfPrefix(word[0]), spelled: word)
  if word == "unmap!" or word == "unm!":
    return CommandToken(isMapping: true, family: vmfUnmap,
                        modeOverride: {emInsert}, spelled: word)

# ===========================================================================
# VIM KEY NOTATION → THIS PRODUCT'S CANONICAL KEY NAMES
# ===========================================================================
#
# `key_names.keyName` goes the other way: BYTES to names. This goes NOTATION to
# names, which is a different function over a different input, so the two are
# not two copies of one predicate (§30). What ties them together is asserted
# rather than assumed: the suite round-trips every name this module can produce
# for an ASCII or control byte back through `keyName` and requires the same
# string.

type
  KeyToken = object
    ok: bool
    name: string
    raw: string

const
  NamedKeys = {
    "cr": "Enter", "enter": "Enter", "return": "Enter",
    "esc": "Esc", "escape": "Esc",
    "tab": "Tab", "s-tab": "Shift+Tab",
    "space": "Space",
    "bs": "Backspace", "backspace": "Backspace",
    "del": "Delete", "delete": "Delete",
    "home": "Home", "end": "End",
    "pageup": "PageUp", "pagedown": "PageDown",
    "insert": "Insert",
    "up": "Up", "down": "Down", "left": "Left", "right": "Right",
    "f1": "F1", "f2": "F2", "f3": "F3", "f4": "F4", "f5": "F5", "f6": "F6",
    "f7": "F7", "f8": "F8", "f9": "F9", "f10": "F10", "f11": "F11",
    "f12": "F12",
    "lt": "<", "bar": "|", "bslash": "\\",
  }.toTable

  # The five Vim control spellings that ARE a named key's byte. `key_names`
  # reads the byte and answers the name, so these are the only spellings a
  # terminal can ever produce for them.
  ControlAliases = {
    "c-h": "Backspace", "c-i": "Tab", "c-m": "Enter", "c-j": "Enter",
    "c-[": "Esc",
  }.toTable

  # The same five, for the §6.4 divergence: two of them (`<C-M>` and `<C-J>`)
  # collapse onto ONE name, so a file that maps both has one of them silently
  # won by the other.
  CollapsingControls = ["<c-h>", "<c-i>", "<c-m>", "<c-j>", "<c-[>"]

  PluginMarkers = ["<plug>"]
    ## `<SID>` and `<SNR>` are NOT here. They are script-local FUNCTION
    ## references, which §6.2 lists under Vimscript, and treating them as
    ## plugin markers made `macros/less.vim` — which loads no plugin at all —
    ## report twenty-nine plugin references.
  VimscriptMarkers = ["<cmd>", "<scriptcmd>", "<sid>", "<snr>", "<c-r>=",
                      "<c-\\>"]

func splitNotation(s: string): seq[string] =
  ## Split a Vim key-notation string into tokens: `<...>` groups and single
  ## characters. A `<` with no `>` after it is a literal `<`, which is Vim's
  ## own reading.
  result = @[]
  var i = 0
  while i < s.len:
    if s[i] == '<':
      let close = s.find('>', i + 1)
      if close > i and close - i <= 24 and s.find(' ', i + 1, close) < 0:
        result.add s[i .. close]
        i = close + 1
        continue
    result.add $s[i]
    inc i

func canonicalKey(token: string; mapleader: string;
                  mapleaderResolved: bool): KeyToken =
  ## One notation token to one canonical key name.
  result = KeyToken(ok: false, name: "", raw: token)
  if token.len == 0: return
  if token[0] != '<' or token.len < 3 or token[^1] != '>':
    # A `<` with no `>` after it is a literal `<`, which is Vim's own reading.
    if token.len == 1 and token[0] >= ' ' and token[0] <= '~':
      return KeyToken(ok: true, name: (if token == " ": "Space" else: token),
                      raw: token)
    return
  let inner = token[1 ..< token.len - 1]
  let lower = inner.toLowerAscii
  if lower == "leader" or lower == "localleader":
    if not mapleaderResolved: return
    let sub = splitNotation(mapleader)
    if sub.len != 1: return
    return canonicalKey(sub[0], mapleader, false)
  if lower == "nop": return KeyToken(ok: false, name: "<Nop>", raw: token)
  if NamedKeys.hasKey(lower):
    return KeyToken(ok: true, name: NamedKeys[lower], raw: token)
  if ControlAliases.hasKey(lower):
    # **FIVE CONTROL KEYS ARE THE SAME BYTE AS A NAMED KEY**, and `key_names`
    # names the byte. `<C-H>` is 0x08 and `keyName("\b")` is `Backspace`; a
    # chord spelled `Ctrl+h` is one no reader of a terminal can ever produce,
    # so a binding on it would resolve for nobody. Found by the round-trip
    # case in `test_editor_vim_import.nim`, which is why that case is there.
    return KeyToken(ok: true, name: ControlAliases[lower], raw: token)
  # Modifier forms: C-, A-, M-, S-, and their combinations.
  var mods: seq[string] = @[]
  var rest = inner
  while rest.len >= 2 and rest[1] == '-' and
        rest[0] in {'C', 'c', 'A', 'a', 'M', 'm', 'S', 's', 'D', 'd'}:
    case rest[0]
    of 'C', 'c': mods.add "Ctrl"
    of 'A', 'a', 'M', 'm': mods.add "Alt"
    of 'S', 's': mods.add "Shift"
    else: return   ## `<D-…>` is macOS Command; this product has no such name
    rest = rest[2 .. ^1]
  if mods.len == 0: return
  var base = ""
  if NamedKeys.hasKey(rest.toLowerAscii):
    base = NamedKeys[rest.toLowerAscii]
  elif rest.len == 1 and rest[0] >= ' ' and rest[0] <= '~':
    base = rest
  else:
    return
  if "Ctrl" in mods and base.len == 1 and base[0] in {'A' .. 'Z'}:
    # `<C-X>` and `<C-x>` are the same byte, and `key_names` spells it
    # lowercase. Keeping both spellings would put two names on one key.
    base = base.toLowerAscii
  if "Shift" in mods and base.len == 1 and base[0] in {'a' .. 'z'} and
     "Ctrl" notin mods and "Alt" notin mods:
    return KeyToken(ok: true, name: base.toUpperAscii, raw: token)
  var name = ""
  for m in ["Ctrl", "Alt", "Shift"]:
    if m in mods: name.add(m & "+")
  result = KeyToken(ok: true, name: name & base, raw: token)

proc chordsOf*(notation: string; mapleader: string; mapleaderResolved: bool):
    (bool, seq[string], string) =
  ## `(ok, chords, offendingToken)`. The offending token is the FIRST one that
  ## has no name here, so the report names the thing rather than the line.
  var chords: seq[string] = @[]
  for tok in splitNotation(notation):
    let k = canonicalKey(tok, mapleader, mapleaderResolved)
    if not k.ok: return (false, chords, tok)
    chords.add k.name
  if chords.len == 0: return (false, chords, "")
  (true, chords, "")

# ===========================================================================
# THE RIGHT-HAND SIDE — resolved through the HAND-WRITTEN VIM KEYMAP
# ===========================================================================
#
# This is what §6's opening sentence is about: *"an abstract named-operation
# layer is what makes this possible at all"*. The right-hand side of a Vim
# mapping is a Vim key sequence, and `vim_keymap.nim` is exactly a table from
# Vim key sequences to named operations. So the translation is a WALK OF THAT
# TRIE, not a second table of Vim's semantics — there is one Vim keymap in this
# repository and the importer is a reader of it.

proc importScope(mode: EditingMode): EditingScope =
  EditingScope(model: kmVim, product: pmEdit, pane: epEditor, mode: mode,
               textEntry: isTextEntryMode(mode))

const
  ModeEntering = {
    "enter-insert": emInsert, "enter-insert-line-start": emInsert,
    "enter-append": emInsert, "enter-append-line-end": emInsert,
    "enter-normal": emNormal, "enter-visual": emVisual,
    "enter-visual-line": emVisualLine, "enter-visual-block": emVisualBlock,
    "enter-replace": emReplace,
  }.toTable

type
  ResolvedOp* = object
    ## One step of a translated right-hand side: the operation's NAME and the
    ## argument the Vim keymap's own binding carries for it. Both halves are
    ## needed — see `MacroCarriesNoArguments` below.
    name*: string
    args*: OpArgs

proc translateRhsKeys*(chords: seq[string]; startMode: EditingMode):
    (bool, seq[ResolvedOp], string) =
  ## `(ok, resolved operations, offending chord)`.
  ##
  ## A STATIC WALK, not an execution. No document is opened and no operation is
  ## applied; the mode is tracked because Vim's `Vdd` reads its second and third
  ## keys in a different mode from its first, and the trie is per-scope.
  ##
  ## It is deliberately NOT `driveKeys`: that applies operations to a real
  ## document, and `DIFF-5`'s other side is exactly that. A differential whose
  ## two sides call one function cannot fail (§30), so the importer walks and
  ## the differential drives.
  let km = vimKeymap().keymap
  var mode = startMode
  var trie = trieFor(km, importScope(mode))
  var st = initEditorState("")
  var ops: seq[ResolvedOp] = @[]
  var i = 0
  while i < chords.len:
    let key = chords[i]
    let res = resolve(trie, st, importScope(mode), key, 0)
    case res.kind
    of erNothing:
      return (false, ops, key)
    of erPending:
      st.pending = res.pending
      inc i
    of erCharacter:
      # CONSECUTIVE CHARACTERS COLLAPSE INTO ONE `insert-text`. `cmap Tabe
      # tabe` is four keys and ONE operation carrying the string, which is
      # both what Vim does and the only spelling that survives a macro — see
      # `MacroCarriesNoArguments`.
      if ops.len > 0 and ops[^1].name == "insert-text":
        ops[^1].args.text = ops[^1].args.text & res.character
      else:
        ops.add ResolvedOp(name: "insert-text",
                           args: OpArgs(text: res.character))
      st.pending = res.pending
      inc i
    of erOperation:
      ops.add ResolvedOp(name: res.operation, args: res.args)
      st.pending = res.pending
      if ModeEntering.hasKey(res.operation):
        mode = ModeEntering[res.operation]
        trie = trieFor(km, importScope(mode))
        st = initEditorState("")
      inc i
  if st.pending.chords.len > 0:
    # The sequence ENDED mid-prefix: `nnoremap x d` leaves the operator
    # pending forever. Vim would too, so this is not a failure to translate —
    # but it is a right-hand side that names no complete operation, and the
    # honest answer is the offending chord rather than a shorter list.
    return (false, ops, st.pending.chords.join(" "))
  if ops.len == 0: return (false, ops, "")
  (true, ops, "")

proc argumentBearing*(ops: seq[ResolvedOp]): string =
  ## The name of the first operation in `ops` that carries an argument, or "".
  ##
  ## **`MacroCarriesNoArguments` — THE ONE PLACE THE MODEL CANNOT EXPRESS A
  ## VIM MAPPING, AND IT WAS FOUND BY READING WHAT THE IMPORT PRODUCED.**
  ## `EditorState.macros` is a `Table[string, seq[string]]` — operation NAMES —
  ## and `replay-macro` replays each step with `runNamed(cur, step, …)`, which
  ## constructs a fresh empty `OpArgs`. So a macro carrying `begin-operator` or
  ## `insert-text` replays it with no operator and no text: a binding that
  ## resolves, acts, and does nothing. That is exactly the failure §6.3 exists
  ## to prevent, so a multi-operation right-hand side containing one is
  ## REPORTED rather than bound.
  ##
  ## The alternative — widening `EditorState.macros` to carry arguments — is a
  ## change to PLAT-30's core state that every state comparison in four
  ## milestones' suites would feel, and it is recorded as a residue in PLAT-36
  ## rather than taken here.
  let table = operations()
  for op in ops:
    let idx = operationNamed(op.name)
    if idx >= 0 and table[idx].arg != akNone: return op.name
  ""

# ===========================================================================
# `set` OPTIONS
# ===========================================================================

const
  OptionSpellings: array[VimOptionId, seq[string]] = [
    voTabstop: @["tabstop", "ts"],
    voShiftwidth: @["shiftwidth", "sw"],
    voExpandtab: @["expandtab", "et"],
    voWrap: @["wrap"],
    voNumber: @["number", "nu"],
    voRelativenumber: @["relativenumber", "rnu"],
    voIgnorecase: @["ignorecase", "ic"],
    voSmartcase: @["smartcase", "scs"],
    voTimeoutlen: @["timeoutlen", "tm"],
    voScrolloff: @["scrolloff", "so"],
  ]

  BooleanOptions = {voExpandtab, voWrap, voNumber, voRelativenumber,
                    voIgnorecase, voSmartcase}

func optionNamed(word: string): tuple[ok: bool, id: VimOptionId] =
  for o in VimOptionId:
    for spelling in OptionSpellings[o]:
      if word == spelling: return (ok: true, id: o)
  (ok: false, id: voTabstop)

# ===========================================================================
# THE IMPORTER
# ===========================================================================

func isCommentLine(line: string; vim9: bool): bool =
  let s = line.strip()
  if s.len == 0: return false
  if s[0] == '"': return true
  if vim9 and s[0] == '#': return true
  false

proc countMappingLines*(text: string): int =
  ## **A SECOND PASS THAT NEVER LOOKS AT AN OUTCOME**, so the partition law is
  ## not `|A| + |B| == |A ∪ B|` (§22). It shares `matchFamily` with the
  ## importer deliberately — §30's remedy is one predicate with two callers,
  ## and the independence that matters comes from the corpus manifest's third
  ## number, produced by a reader in another language.
  result = 0
  var vim9 = false
  var pendingText = ""
  var pendingLive = false
  for raw in text.splitLines():
    let s = raw.strip()
    if s.startsWith("vim9script"): vim9 = true
    if s.startsWith("\\"):
      if pendingLive: pendingText.add s[1 .. ^1]
      continue
    if pendingLive:
      pendingLive = false
    if isCommentLine(raw, vim9) or s.len == 0: continue
    var body = s
    if body.len > 0 and body[0] == ':': body = body[1 .. ^1].strip()
    let fields = body.splitWhitespace()
    if fields.len == 0: continue
    if matchFamily(fields[0]).isMapping:
      inc result
      pendingText = body
      pendingLive = true

proc logicalLines(text: string): seq[tuple[line: int, text: string]] =
  ## Vim's line continuation (`:help line-continuation`): a line whose first
  ## non-blank character is `\` continues the previous one. The reported line
  ## number is the FIRST line of the command, which is where a user looks.
  result = @[]
  let lines = text.splitLines()
  for i in 0 ..< lines.len:
    let raw = lines[i]
    let s = raw.strip()
    if s.startsWith("\\") and result.len > 0:
      result[^1].text = result[^1].text & s[1 .. ^1]
    else:
      result.add (line: i + 1, text: raw)

proc readMapleader(text: string): (bool, string) =
  ## A LEXICAL READ, and only of an UNCONDITIONAL assignment — see the header.
  ## `let mapleader = ","` at column zero counts; `let mapleader=g:x` and an
  ## indented one do not.
  result = (false, DefaultMapleader)
  for raw in text.splitLines():
    if raw.len == 0 or raw[0] in {' ', '\t'}: continue
    let s = raw.strip()
    if not (s.startsWith("let mapleader") or s.startsWith("let g:mapleader")):
      continue
    let eq = s.find('=')
    if eq < 0: continue
    let rhs = s[eq + 1 .. ^1].strip()
    if rhs.len >= 2 and (rhs[0] == '"' or rhs[0] == '\'') and rhs[^1] == rhs[0]:
      var lit = rhs[1 ..< rhs.len - 1]
      if rhs[0] == '"': lit = lit.replace("\\\\", "\\")
      if lit.len > 0: result = (true, lit)

proc parseMapArguments(rest: string): (set[VimMapArgument], string) =
  var args: set[VimMapArgument] = {}
  var s = rest.strip(trailing = false)
  while true:
    var matched = false
    for a in VimMapArgument:
      let spelling = $a
      if s.len >= spelling.len and
         cmpIgnoreCase(s[0 ..< spelling.len], spelling) == 0:
        args.incl a
        s = s[spelling.len .. ^1].strip(trailing = false)
        matched = true
        break
    if not matched: break
  (args, s)

func rhsIsPlugin(rhs: string): bool =
  let low = rhs.toLowerAscii
  for m in PluginMarkers:
    if low.contains(m): return true
  false

func rhsIsVimscript(rhs: string; startMode: EditingMode): bool =
  ## **A LEADING `:` IS AN EX COMMAND ONLY IN A MODE THAT SPELLS COMMANDS.**
  ## In Insert mode a mapping's right-hand side is TYPED, so `inoremap z :`
  ## inserts a colon and `inoremap jk :w<CR>` types the three characters
  ## `:w` and a newline — neither is Vimscript. Reading the colon
  ## unconditionally made one of `dvorak/enable.vim`'s seventy pure key-to-key
  ## remaps report *invokes Vimscript*, which is how this was found.
  let s = rhs.strip()
  if s.len == 0: return false
  if s.len > 1 and s[0] == ':' and not isTextEntryMode(startMode): return true
  let low = s.toLowerAscii
  for m in VimscriptMarkers:
    if low.contains(m): return true
  false

proc removeBindings(km: var EditingKeymap; modes: set[EditingMode];
                    chords: seq[string]; anyChords: bool): int =
  ## Remove `chords` (or everything, when `anyChords`) from `modes`, and
  ## return how many bindings were affected.
  ##
  ## **THE MODE SETS INTERSECT RATHER THAN MATCHING, AND THAT WAS A DEFECT.**
  ## The first spelling compared `b.scope.modes == modes`, so `:unmap gQ` after
  ## `:nnoremap gQ 0` cleared NOTHING: `unmap` covers Normal, Visual, Select
  ## and Operator-pending and `nnoremap` installs into Normal alone, and two
  ## unequal sets never matched. Vim removes the Normal mapping there, and a
  ## teardown block that silently clears nothing is the exact shape §6.3 calls
  ## worse than none — `macros/less.vim` is fifty-four such lines.
  ##
  ## A binding whose modes are only PARTLY covered is NARROWED rather than
  ## deleted, which is also Vim's behaviour: `:iunmap` does not remove a
  ## `:map!` mapping's Command-line half.
  result = 0
  var kept: seq[EditingBinding] = @[]
  for b in km.bindings:
    if (anyChords or b.chords == chords) and (b.scope.modes * modes).len > 0:
      inc result
      var narrowed = b
      narrowed.scope.modes = b.scope.modes - modes
      if narrowed.scope.modes.len > 0: kept.add narrowed
    else:
      kept.add b
  km.bindings = kept

proc importVimConfig*(text: string; base = EditingKeymap()): VimImport =
  ## Read a `.vimrc` / `init.vim` and produce bindings plus the report.
  ##
  ## **EVERY LINE GETS AN OUTCOME.** A line this importer does not act on is
  ## `lkOther`, which is a statement; a line that could not be translated is
  ## `okReported`, which is a different statement; and there is no third way
  ## out of the loop.
  result = VimImport(keymap: base, macros: initTable[string, seq[string]](),
                     mapleader: DefaultMapleader, mapleaderResolved: false,
                     outcomes: @[], report: @[], divergences: @[])
  let (leaderOk, leader) = readMapleader(text)
  result.mapleader = leader
  result.mapleaderResolved = leaderOk

  var vim9 = false
  var macroSeq = 0

  template report(ln: int; txt: string; rs: ImportReason; dt: string) =
    result.outcomes.add LineOutcome(line: ln, text: txt, kind: lkMapping,
                                    outcome: okReported, reason: rs,
                                    detail: dt)
    result.report.add ImportReportEntry(line: ln, text: txt, reason: rs,
                                        detail: dt)

  template diverge(ln: int; txt: string; why: string) =
    result.divergences.add DivergenceEntry(line: ln, text: txt, note: why)

  for (lineNo, rawLine) in logicalLines(text):
    let stripped = rawLine.strip()
    if stripped.startsWith("vim9script"): vim9 = true
    if stripped.len == 0 or isCommentLine(rawLine, vim9):
      result.outcomes.add LineOutcome(line: lineNo, text: rawLine,
                                      kind: lkBlank, outcome: okUnbind,
                                      unbindFamily: vmfUnmap, cleared: 0)
      continue

    var body = stripped
    if body[0] == ':': body = body[1 .. ^1].strip()
    let fields = body.splitWhitespace()
    if fields.len == 0:
      result.outcomes.add LineOutcome(line: lineNo, text: rawLine,
                                      kind: lkBlank, outcome: okUnbind,
                                      unbindFamily: vmfUnmap, cleared: 0)
      continue

    # ---- `set` -------------------------------------------------------------
    let head = fields[0]
    if head in ["set", "se", "setlocal", "setl", "setglobal", "setg"]:
      var argText = body[head.len .. ^1].strip()
      # A TRAILING `"` COMMENT, which `:set` permits and `:map` does not — and
      # the whitespace before it is a TAB as often as a space. Matching on
      # `" \"` alone read `set ruler<TAB>" show the cursor position` as eight
      # further options, all of them reported as having no equivalent, which is
      # a report full of words from a comment.
      block stripComment:
        for i in 1 ..< argText.len:
          if argText[i] == '"' and argText[i - 1] in {' ', '\t'}:
            argText = argText[0 ..< i].strip()
            break stripComment
      if argText.len == 0:
        result.outcomes.add LineOutcome(line: lineNo, text: body, kind: lkOther,
                                        outcome: okUnbind,
                                        unbindFamily: vmfUnmap, cleared: 0)
        continue
      for item in argText.splitWhitespace():
        var word = item
        var value = ""
        var negated = false
        let eq = word.find('=')
        if eq >= 0:
          value = word[eq + 1 .. ^1]
          word = word[0 ..< eq]
        if word.endsWith("?") or word.endsWith("!") or word.endsWith("&"):
          word = word[0 ..< word.len - 1]
        if word.startsWith("no") and optionNamed(word).ok == false and
           optionNamed(word[2 .. ^1]).ok:
          negated = true
          word = word[2 .. ^1]
        elif word.startsWith("inv") and optionNamed(word[3 .. ^1]).ok:
          word = word[3 .. ^1]
        let (known, opt) = optionNamed(word)
        if not known:
          result.outcomes.add LineOutcome(
            line: lineNo, text: body, kind: lkSet, outcome: okReported,
            reason: irNoOption,
            detail: "this model has no concept for the option '" & word & "'")
          result.report.add ImportReportEntry(
            line: lineNo, text: body, reason: irNoOption,
            detail: "this model has no concept for the option '" & word & "'")
          continue
        var v = VimOptionValue(given: true, raw: value, number: 0,
                               boolean: not negated)
        if opt notin BooleanOptions:
          try: v.number = parseInt(value)
          except ValueError:
            result.outcomes.add LineOutcome(
              line: lineNo, text: body, kind: lkSet, outcome: okReported,
              reason: irSyntax,
              detail: "'" & $opt & "' takes a number and was given '" &
                value & "'")
            result.report.add ImportReportEntry(
              line: lineNo, text: body, reason: irSyntax,
              detail: "'" & $opt & "' takes a number and was given '" &
                value & "'")
            continue
        result.options[opt] = v
        result.outcomes.add LineOutcome(line: lineNo, text: body, kind: lkSet,
                                        outcome: okOption, option: opt,
                                        value: (if opt in BooleanOptions:
                                                  (if negated: "off" else: "on")
                                                else: value))
      continue

    # ---- the 22 map-family spellings --------------------------------------
    let cmd = matchFamily(head)
    if not cmd.isMapping:
      result.outcomes.add LineOutcome(line: lineNo, text: body, kind: lkOther,
                                      outcome: okUnbind,
                                      unbindFamily: vmfUnmap, cleared: 0)
      continue

    let family = cmd.family
    var modes = familyModes(family)
    if cmd.modeOverride.len > 0: modes = cmd.modeOverride
    let after = body[head.len .. ^1].strip(trailing = false)
    let (mapArgs, operands) = parseMapArguments(after)

    if family == vmfMapclear:
      let removed = removeBindings(result.keymap, modes, @[], true)
      result.outcomes.add LineOutcome(line: lineNo, text: body,
                                      kind: lkMapping, outcome: okUnbind,
                                      unbindFamily: family, cleared: removed)
      continue

    let opText = operands.strip()
    if opText.len == 0:
      report(lineNo, body, irSyntax,
             "'" & cmd.spelled & "' with no left-hand side lists mappings; " &
               "it declares none")
      continue

    # The left-hand side is the first whitespace-delimited token.
    var lhsText = opText
    var rhsText = ""
    let sp = opText.find({' ', '\t'})
    if sp >= 0:
      lhsText = opText[0 ..< sp]
      rhsText = opText[sp .. ^1].strip(trailing = false)

    if family == vmfUnmap:
      let (lhsOk, chords, badTok) = chordsOf(lhsText, result.mapleader,
                                             result.mapleaderResolved)
      if not lhsOk:
        report(lineNo, body, irSyntax,
               "the left-hand side token '" & badTok &
                 "' is not a key this editor can spell")
        continue
      let removed = removeBindings(result.keymap, modes, chords, false)
      result.outcomes.add LineOutcome(line: lineNo, text: body,
                                      kind: lkMapping, outcome: okUnbind,
                                      unbindFamily: family, cleared: removed)
      continue

    if rhsText.len == 0:
      report(lineNo, body, irSyntax,
             "a mapping needs a right-hand side; '" & lhsText &
               "' has none, which in Vim lists the mapping instead")
      continue

    let startMode = (if cmd.modeOverride.len > 0:
                       (if emNormal in modes: emNormal
                        elif emOperatorPending in modes: emOperatorPending
                        elif emInsert in modes: emInsert
                        else: emVisual)
                     else: startModeOf(family))

    # ---- §6.2, AND THE ORDER IS A DECISION ---------------------------------
    #
    # THE RIGHT-HAND SIDE IS ASKED FIRST, AND THAT WAS MEASURED RATHER THAN
    # ASSUMED. With the left-hand side asked first, `swapmouse.vim`'s twenty
    # `noremap <LeftMouse> <RightMouse>` lines came back as *the syntax was not
    # understood* — which is false: the syntax was understood perfectly and
    # what it names is a mouse button this editor has no name for. Asking the
    # right-hand side first gives them *the right-hand side uses an operation
    # this editor does not have*, which is what is actually wrong with them.
    # `irSyntax` keeps the cases where the LEFT-hand side alone is unreadable,
    # and it is still reached SEVENTEEN times in the pinned corpus, so this is
    # not a reason being emptied to tidy a table. (Seventeen is measured from
    # `manifest.tsv`; this line said fifteen until it was re-taken.)
    #
    # `<Plug>` is checked before Vimscript because a `<Plug>` right-hand side
    # is overwhelmingly ALSO Vimscript, and *names a plugin* is the more
    # actionable of the two for a user deciding what to do about it. `<SID>`
    # and `<SNR>` are NOT plugin markers: they are script-local function
    # references, which §6.2 lists under Vimscript, and putting them here made
    # `macros/less.vim` — a file that loads no plugin at all — report
    # twenty-nine plugin references.
    if rhsIsPlugin(rhsText) or rhsIsPlugin(lhsText):
      report(lineNo, body, irPlugin,
             "the mapping names a plugin's own binding; this editor loads no " &
               "Vim plugin")
      continue
    if vmaExpr in mapArgs:
      report(lineNo, body, irVimscript,
             "<expr> makes the right-hand side an expression to evaluate")
      continue
    if rhsIsVimscript(rhsText, startMode):
      report(lineNo, body, irVimscript,
             "the right-hand side runs an Ex command or a Vimscript expression")
      continue
    if lhsText.toLowerAscii.contains("<leader>") and
       not result.mapleaderResolved:
      report(lineNo, body, irVimscript,
             "<leader> needs 'mapleader', which this file assigns only " &
               "conditionally or from a variable")
      continue

    let (rhsOk, rhsChords, badRhs) = chordsOf(rhsText, result.mapleader,
                                              result.mapleaderResolved)
    let (lhsOk, chords, badLhs) = chordsOf(lhsText, result.mapleader,
                                           result.mapleaderResolved)
    if not rhsOk and badRhs.toLowerAscii != "<nop>":
      report(lineNo, body, irNoOperation,
             "the right-hand side token '" & badRhs &
               "' names nothing this editor can do")
      continue
    if not lhsOk:
      report(lineNo, body, irSyntax,
             "the left-hand side token '" & badLhs &
               "' is not a key this editor can spell")
      continue
    if not rhsOk:
      # `<Nop>` — the right-hand side that binds nothing ON PURPOSE. It is an
      # `okUnbind`, not an `okReported`, and the two are different answers.
      let removed = removeBindings(result.keymap, modes, chords, false)
      result.outcomes.add LineOutcome(line: lineNo, text: body,
                                      kind: lkMapping, outcome: okUnbind,
                                      unbindFamily: family, cleared: removed)
      continue

    let (opsOk, resolved, badOp) = translateRhsKeys(rhsChords, startMode)
    if not opsOk:
      report(lineNo, body, irNoOperation,
             "the right-hand side reaches '" & badOp &
               "', which this editor's Vim keymap binds to no operation")
      continue
    var ops: seq[string] = @[]
    for r in resolved: ops.add r.name
    if resolved.len > 1:
      let carries = argumentBearing(resolved)
      if carries.len > 0:
        report(lineNo, body, irNoOperation,
               "the right-hand side is " & $resolved.len & " operations and " &
                 "one of them ('" & carries & "') carries an argument; this " &
                 "editor's macro facility records operation names without " &
                 "their arguments, so replaying it would drop the argument " &
                 "and the binding would do nothing")
        continue

    # ---- <unique>: Vim refuses over an existing mapping --------------------
    if vmaUnique in mapArgs:
      var claimed = ""
      for b in result.keymap.bindings:
        if b.chords == chords and b.scope.modes == modes:
          claimed = b.operation
          break
      if claimed.len > 0:
        result.outcomes.add LineOutcome(line: lineNo, text: body,
                                        kind: lkMapping,
                                        outcome: okUniqueRefused,
                                        claimedBy: claimed)
        continue

    # ---- the binding ------------------------------------------------------
    var operation = ""
    var args = OpArgs()
    var macroId = ""
    if resolved.len == 1:
      operation = resolved[0].name
      args = resolved[0].args
    else:
      inc macroSeq
      macroId = "vimrc-" & $macroSeq
      result.macros[macroId] = ops
      operation = "replay-macro"
      args = OpArgs(id: macroId)

    var kept: seq[EditingBinding] = @[]
    for b in result.keymap.bindings:
      if b.chords == chords and b.scope.modes == modes: continue
      kept.add b
    # A LATER MAPPING WINS, which is Vim's rule and `.cttui-keys`' too.
    kept.add EditingBinding(
      model: kmVim,
      scope: BindingScope(modes: modes, products: {}, panes: familyPanes(family)),
      chords: chords, operation: operation, args: args,
      spelling: chords.join(" "))
    result.keymap.bindings = kept

    result.outcomes.add LineOutcome(line: lineNo, text: body, kind: lkMapping,
                                    outcome: okBinding, family: family,
                                    chords: chords, operations: ops,
                                    macroId: macroId, modes: modes)

    # ---- §6.4's divergences, on a line that WAS translated -----------------
    let famNote = familyDivergence(family)
    if famNote.len > 0: diverge(lineNo, body, famNote)
    if vmaBuffer in mapArgs:
      diverge(lineNo, body,
              "<buffer> asks for a mapping local to one buffer; §4.3 has no " &
                "per-buffer scope, so this is imported globally")
    if vmaNowait in mapArgs:
      diverge(lineNo, body,
              "<nowait> asks for no ambiguity timeout on this binding; the " &
                "resolver's timeout is one value for every binding")
    block controlAlias:
      let lowLhs = lhsText.toLowerAscii
      for spelling in CollapsingControls:
        if lowLhs.contains(spelling):
          diverge(lineNo, body,
                  "'" & spelling & "' IS the byte of a named key, so this " &
                    "editor spells it as that key; `<C-M>` and `<C-J>` are " &
                    "one name here and Vim keeps them apart")
          break controlAlias
    if isTextEntryMode(startMode) and chords.len > 0 and
       chords[0].len == 1 and chords[0][0] >= ' ' and chords[0][0] <= '~':
      diverge(lineNo, body,
              "§4.3's text-entry shadow: in a mode that accepts text, a " &
                "printable key stands for itself, so this binding does not " &
                "fire while the scope's text-entry flag is set")
    if family in {vmfMap, vmfNmap, vmfVmap, vmfXmap, vmfSmap, vmfOmap,
                  vmfImap, vmfCmap, vmfLmap, vmfMapBang}:
      # A RECURSIVE mapping. The right-hand side was read through the DEFAULT
      # Vim keymap; Vim would have read it through the user's own mappings.
      # The divergence is recorded only where it can bite — where an earlier
      # imported binding claims a prefix of the right-hand side — rather than
      # on every recursive mapping, which would make the report unreadable.
      var shadowed = false
      for b in result.keymap.bindings:
        if b.operation.len == 0: continue
        if b.chords.len <= rhsChords.len and
           b.chords == rhsChords[0 ..< b.chords.len] and b.chords != chords:
          shadowed = true
          break
      if shadowed:
        diverge(lineNo, body,
                "a recursive mapping whose right-hand side is itself mapped " &
                  "in this file; the import reads it through the default Vim " &
                  "keymap, Vim would re-apply the user's mapping")

# ===========================================================================
# THE MEASURED FIGURES — derived from `outcomes`, never maintained beside it
# ===========================================================================

func mappingOutcomes*(imp: VimImport): int =
  for o in imp.outcomes:
    if o.kind == lkMapping: inc result

func translatedMappingLines*(imp: VimImport): int =
  for o in imp.outcomes:
    if o.kind == lkMapping and o.outcome != okReported: inc result

func reportedMappingLines*(imp: VimImport): int =
  for o in imp.outcomes:
    if o.kind == lkMapping and o.outcome == okReported: inc result

func optionOutcomes*(imp: VimImport): int =
  for o in imp.outcomes:
    if o.kind == lkSet: inc result

func translatedOptionLines*(imp: VimImport): int =
  for o in imp.outcomes:
    if o.kind == lkSet and o.outcome == okOption: inc result

func reportedOptionLines*(imp: VimImport): int =
  for o in imp.outcomes:
    if o.kind == lkSet and o.outcome == okReported: inc result

func reasonCounts*(imp: VimImport): array[ImportReason, int] =
  for e in imp.report: inc result[e.reason]

func boundLines*(imp: VimImport): int =
  for o in imp.outcomes:
    if o.kind == lkMapping and o.outcome == okBinding: inc result

func unbindLines*(imp: VimImport): int =
  for o in imp.outcomes:
    if o.kind == lkMapping and o.outcome == okUnbind: inc result

func uniqueRefusedLines*(imp: VimImport): int =
  for o in imp.outcomes:
    if o.kind == lkMapping and o.outcome == okUniqueRefused: inc result

func coverageFraction*(imp: VimImport): (int, int) =
  ## §6.3's headline: *"a count, not a list"* — N of M. Both numbers are
  ## measured, and M is `mappingOutcomes`, which the partition law ties to a
  ## second pass over the raw text.
  (translatedMappingLines(imp), mappingOutcomes(imp))

func describeReport*(e: ImportReportEntry): string =
  "line " & $e.line & ": " & $e.reason & " — " & e.detail & "\n    " & e.text
