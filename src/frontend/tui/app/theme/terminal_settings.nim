## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/theme/terminal_settings.nim — PLAT-71 (CodeTracer-TUI-Terminal-
## Adaptation.md §5.2, §5.3): the remembered and the typed terminal settings,
## as the RANKS the capability resolver reads.
##
## `layout_settings` holds every setting as a value WORD — the form `:set`,
## the omnibox, a flag and the remembered file share. The resolver
## (`capabilities.resolveCapabilities`) reads `TerminalChoices`: per axis, a
## value or nothing. This module is the one translation between them, so a
## setting cannot mean one thing typed and another remembered.
##
## `auto` SAYS NOTHING at its rank (the next rank down is asked) for every
## setting except `modern-unicode`, where `auto` is a value of its own
## (§6.7) and `off` is the default.

import codetracer_embed

import ./terminal_profile

export terminal_profile

proc choicesOf*(which: LayoutSetting; word: string;
                into: var TerminalChoices): bool =
  ## Put one terminal setting's word into the rank `into`. False for a
  ## setting that is not a terminal setting, or a word it does not take.
  case which
  of lsGlyphs:
    var v: GlyphsChoice
    if not parseChoice(word, v): return false
    into.glyphs = (if v == gcAuto: none(GlyphsChoice) else: some(v))
  of lsModernUnicode:
    var v: ModernChoice
    if not parseChoice(word, v): return false
    into.modernUnicode = some(v)
  of lsAmbiguousWidth:
    var v: AmbiguousChoice
    if not parseChoice(word, v): return false
    into.ambiguousWidth = (if v == acAuto: none(AmbiguousChoice) else: some(v))
  of lsColors:
    var v: ColorsChoice
    if not parseChoice(word, v): return false
    into.colors = (if v == ccAuto: none(ColorsChoice) else: some(v))
  of lsTerminalProbe:
    var v: bool
    if not parseOnOffWord(word, v): return false
    into.probe = some(v)
  of lsReduceMotion:
    if word == "auto":
      into.reduceMotion = none(bool)
    else:
      var v: bool
      if not parseOnOffWord(word, v): return false
      into.reduceMotion = some(v)
  else:
    return false
  true

proc choicesOf*(words: TerminalSettingWords): TerminalChoices =
  ## The global settings (rank 5). `modern-unicode = off` is the default and
  ## is therefore NOT a choice the remembered file makes for the user; only
  ## `on` or `auto` written there speaks at rank 5.
  discard choicesOf(lsGlyphs, words.glyphs, result)
  if words.modernUnicode in ["on", "auto"]:
    discard choicesOf(lsModernUnicode, words.modernUnicode, result)
  discard choicesOf(lsAmbiguousWidth, words.ambiguousWidth, result)
  discard choicesOf(lsColors, words.colors, result)
  if words.terminalProbe == "off":
    discard choicesOf(lsTerminalProbe, words.terminalProbe, result)
  discard choicesOf(lsReduceMotion, words.reduceMotion, result)

proc prefsOf*(s: LayoutSettings): TerminalPrefs =
  ## Ranks 4 and 5: the `[terminal "<glob>"]` sections and the global
  ## settings of the remembered file.
  result.global = choicesOf(s.terminal)
  for scope in s.scoped:
    var c = TerminalChoices()
    for (which, word) in scope.values:
      discard choicesOf(which, word, c)
    if not c.isEmpty:
      result.scoped.add ScopedChoices(glob: scope.glob, choices: c)
