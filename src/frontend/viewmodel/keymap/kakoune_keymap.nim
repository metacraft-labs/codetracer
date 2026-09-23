## kakoune_keymap.nim — PLAT-31: THE KAKOUNE KEYMAP, as data over PLAT-30's
## names.
##
## Owns: one `KeymapDefinition` — the noun-then-verb bindings, and the
## explicit, reasoned list of published operations this model does NOT claim.
##
## =========================================================================
## NOUN THEN VERB, AND WHY THERE IS NO OPERATOR-PENDING ROW ANYWHERE BELOW
## =========================================================================
##
## `Editing-Operations-And-Keymaps.md` §2.1: *"In Kakoune and Helix, `w`
## SELECTS the next word and `d` deletes the selection — noun, then verb."*
## So `w` is `select-group-right` in NORMAL mode and `d` is `delete-selection`
## in NORMAL mode, and the user's two keystrokes are those two operations in
## that order. There is no `begin-operator` anywhere in this table and
## `emOperatorPending` is never a scope of any row — which is the point, and is
## why `DIFF-4` compares operation SEQUENCES rather than only documents: the
## same task reaches the same end document through two operations here and four
## under Vim.
##
## **A MOTION IS A SELECTION, SO NINE MOTIONS HAVE NO `move-` FORM AT ALL.**
## `w`, `b`, `e`, `f`, `t`, `n`, `_`, `{`, `(` produce a selection in Kakoune;
## there is no collapsing variant of any of them, and the shifted key extends.
## Those nine `move-` operations are FILED — per FORM, which is what
## `FiledDeclaration.forms` exists for — rather than bound to a chord this
## preset invented. §6.4's rule, owed to Kakoune as much as to Vim: *"where
## this editor's operation is not exactly Vim's, the import says so"*.
##
## **THE SELECTION IS THE STATE, SO THE MODEL NEEDS FEWER MODES AND MORE
## SELECTION OPERATIONS.** Everything Vim files as *"Kakoune's multi-selection
## vocabulary"* — `flip-selections`, `keep-primary-selection`,
## `simplify-selection`, the six `add-cursor-*`/`*-cursor` operations — is
## bound here, and everything Kakoune files as *"Vim's operator-pending
## machinery"* — `begin-operator`, `enter-replace`, `enter-visual-block` — is
## bound there. Those two lists ARE `DIFF-4`'s reachable-set difference, and
## the gate requires every member of it to be a filed row on one side.
##
## =========================================================================
## WHAT `keyName` CAN AND CANNOT SPELL, AND WHAT THAT COSTS THIS TABLE
## =========================================================================
##
## Kakoune leans on `Alt+<letter>` (`<a-w>`, `<a-i>`, `<a-s>`).
## `key_names.keyName` produces `Alt+` only for the function keys and the
## arrows, because that is what xterm's `CSI 1 ; m <final>` encodes; a bare
## `Alt+w` arrives as two bytes (`ESC`, `w`) and is framed as two tokens, which
## is a DECODER question and not a keymap one.
##
## So this table binds no `Alt+<letter>`, and the operations that are `<a-…>`
## upstream use a prefixed or shifted spelling here. **It also binds no
## `Ctrl+h`, `Ctrl+i`, `Ctrl+j` or `Ctrl+m`**, and that is not taste: those
## four bytes are `Backspace`, `Tab`, `Enter` and `Enter` on the wire, so
## `keyName` never answers with those spellings and a binding on one would be
## a chord no terminal can deliver. The pty suite is what would catch it; the
## list is here so it does not have to.

import std/strutils

import ./editing_keymap

export editing_keymap

const
  KakouneVisualModes* = {emVisual, emVisualLine}
    ## Kakoune has no separate visual MODE — a selection is always live. The
    ## two members exist because `enter-visual` and `enter-visual-line` are
    ## published operations and this model binds them to the two keys Kakoune
    ## spends on the same idea. What it does NOT have is `enter-visual-block`,
    ## which is filed.

  KakouneLiveModes* = {emNormal} + KakouneVisualModes
    ## Where a chord resolves in this model. Spelled once: every row but the
    ## insert-mode handful is scoped to exactly this, which is itself the
    ## statement that Kakoune's normal mode is where editing happens.

  RegisterLetters* = "abcdefghijklmnopqrstuvwxyz"

  ReplaceCharKeys* = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" &
                     "0123456789 !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"

proc eb(chords: seq[string]; op: string; modes: set[EditingMode];
        args = OpArgs()): EditingBinding =
  EditingBinding(model: kmKakoune,
                 scope: BindingScope(modes: modes, products: {}, panes: {epEditor}),
                 chords: chords, operation: op, args: args,
                 spelling: chords.join(" "))

proc selectAndExtend(r: var seq[EditingBinding]; selectKey, extendKey: string;
                     decl: string) =
  ## **THE KAKOUNE PAIR, AND THE ABSENT THIRD.** The lower-case key SELECTS,
  ## the upper-case key EXTENDS, and there is no collapsing form — see the
  ## header, and the filed rows that record it.
  r.add eb(@[selectKey], "select-" & decl, KakouneLiveModes)
  r.add eb(@[extendKey], "extend-" & decl, KakouneLiveModes)

proc tripleRows(r: var seq[EditingBinding]; movePrefix, extendPrefix,
                selectPrefix, key, decl: string) =
  ## A two-chord family in all three forms, one prefix per form.
  r.add eb(@[movePrefix, key], "move-" & decl, KakouneLiveModes)
  r.add eb(@[extendPrefix, key], "extend-" & decl, KakouneLiveModes)
  r.add eb(@[selectPrefix, key], "select-" & decl, KakouneLiveModes)

proc objectRows(r: var seq[EditingBinding]; key: string; decl: string) =
  ## Kakoune's object menu: `<a-i>` / `<a-a>` upstream, `[` / `]` here for the
  ## `Alt+<letter>` reason in the header.
  r.add eb(@["[", key], "select-inner-" & decl, KakouneLiveModes)
  r.add eb(@["]", key], "select-around-" & decl, KakouneLiveModes)

proc buildKakouneKeymap(): EditingKeymap =
  var r: seq[EditingBinding] = @[]

  # --- A. Motions -------------------------------------------------------
  # The cursor keys, in all three forms: bare moves, Shift extends, Ctrl
  # selects. All three spellings are ones `keyName` produces from real xterm
  # bytes (`CSI A`, `CSI 1;2A`, `CSI 1;5A`).
  for (key, decl) in [("h", "char-left"), ("l", "char-right"),
                      ("k", "line-up"), ("j", "line-down")]:
    r.add eb(@[key], "move-" & decl, KakouneLiveModes)
  for (arrow, decl) in [("Left", "char-left"), ("Right", "char-right"),
                        ("Up", "line-up"), ("Down", "line-down")]:
    r.add eb(@[arrow], "move-" & decl, KakouneLiveModes)
    r.add eb(@["Shift+" & arrow], "extend-" & decl, KakouneLiveModes)
    r.add eb(@["Ctrl+" & arrow], "select-" & decl, KakouneLiveModes)

  # The selecting half. Nine motions, two forms each, and the missing `move-`
  # form filed rather than invented.
  selectAndExtend(r, "w", "W", "group-right")
  selectAndExtend(r, "b", "B", "group-left")
  selectAndExtend(r, "e", "E", "group-forward")
  selectAndExtend(r, "f", "F", "char-forward")
  selectAndExtend(r, "t", "T", "char-backward")
  selectAndExtend(r, "n", "N", "search-next")
  # `<a-n>` upstream, and `Alt+<letter>` is not a spelling `keyName`
  # produces (see the header), so this preset picks two free keys and says
  # so. `p`/`P` are NOT available for it: they are Kakoune's own paste
  # keys, and the trie's duplicate detector is what said so — `P` was
  # `extend-search-prev` AND `paste-before` on the first build, and
  # `conflictsIn` named it in three scopes before any case ran.
  selectAndExtend(r, "_", "+", "search-prev")
  selectAndExtend(r, "{", "}", "paragraph-backward")
  selectAndExtend(r, "(", ")", "paragraph-forward")

  # The `goto` family: `g` moves, `G` extends, `S` selects.
  for (key, decl) in [("h", "line-start"), ("l", "line-end"),
                      ("i", "line-start-smart"), ("g", "doc-start"),
                      ("e", "doc-end"), ("m", "matching-bracket")]:
    tripleRows(r, "g", "G", "S", key, decl)
  # The `view` family: `Ctrl+v` moves, `V` extends, `Z` selects.
  for (key, decl) in [("k", "display-line-up"), ("j", "display-line-down"),
                      ("h", "display-line-start"), ("l", "display-line-end"),
                      ("b", "page-up"), ("f", "page-down")]:
    tripleRows(r, "Ctrl+v", "V", "Z", key, decl)

  r.add eb(@["Ctrl+o"], "move-jump-back", KakouneLiveModes)
  r.add eb(@["Tab"], "move-jump-forward", KakouneLiveModes)
  r.add eb(@["Ctrl+p"], "extend-jump-back", KakouneLiveModes)
  r.add eb(@["Shift+Tab"], "extend-jump-forward", KakouneLiveModes)
  r.add eb(@["Ctrl+n"], "select-jump-back", KakouneLiveModes)
  r.add eb(@["Ctrl+t"], "select-jump-forward", KakouneLiveModes)
  for ch in RegisterLetters:
    r.add eb(@["'", $ch], "move-mark", KakouneLiveModes, OpArgs(id: $ch))
    r.add eb(@["\\", $ch], "extend-mark", KakouneLiveModes, OpArgs(id: $ch))
    r.add eb(@["|", $ch], "select-mark", KakouneLiveModes, OpArgs(id: $ch))

  # --- B. Text objects --------------------------------------------------
  objectRows(r, "w", "word")
  objectRows(r, "s", "subword")
  objectRows(r, "x", "line")
  objectRows(r, "p", "paragraph")
  objectRows(r, "(", "parens")
  objectRows(r, "r", "brackets")
  objectRows(r, "b", "braces")
  objectRows(r, "a", "angle")
  objectRows(r, "q", "quote-single")
  objectRows(r, "Q", "quote-double")
  objectRows(r, "g", "quote-back")
  objectRows(r, "t", "tag")
  objectRows(r, "i", "indent-block")

  # --- C. Operators — THEY CONSUME THE SELECTION THAT IS ALREADY THERE ---
  # **ALL TWENTY.** Kakoune files nothing in category C, which is the other
  # half of the `DIFF-4` difference: the four comment operations and
  # `pipe-selection` are Vim's filed rows and are bound here.
  r.add eb(@["d"], "delete-selection", KakouneLiveModes)
  r.add eb(@["c"], "change-selection", KakouneLiveModes)
  r.add eb(@["y"], "yank-selection", KakouneLiveModes)
  r.add eb(@["P"], "paste-before", KakouneLiveModes)
  r.add eb(@["p"], "paste-after", KakouneLiveModes)
  r.add eb(@["R"], "paste-replace", KakouneLiveModes)
  r.add eb(@[">"], "indent-selection", KakouneLiveModes)
  r.add eb(@["<"], "dedent-selection", KakouneLiveModes)
  r.add eb(@["="], "reindent-selection", KakouneLiveModes)
  r.add eb(@["#"], "toggle-comment", KakouneLiveModes)
  r.add eb(@["&", "c"], "line-comment", KakouneLiveModes)
  r.add eb(@["&", "u"], "line-uncomment", KakouneLiveModes)
  r.add eb(@["&", "b"], "block-comment", KakouneLiveModes)
  r.add eb(@["&", "B"], "block-uncomment", KakouneLiveModes)
  r.add eb(@["~"], "upper-case", KakouneLiveModes)
  r.add eb(@["`"], "lower-case", KakouneLiveModes)
  r.add eb(@["^"], "swap-case", KakouneLiveModes)
  r.add eb(@["J"], "join-lines", KakouneLiveModes)
  r.add eb(@["!"], "pipe-selection", KakouneLiveModes, OpArgs(command: "cat"))
  for ch in ReplaceCharKeys:
    r.add eb(@["m", $ch], "replace-char", KakouneLiveModes, OpArgs(ch: $ch))

  # --- D. Commands ------------------------------------------------------
  r.add eb(@["i"], "enter-insert", KakouneLiveModes)
  r.add eb(@["I"], "enter-insert-line-start", KakouneLiveModes)
  r.add eb(@["A"], "enter-append-line-end", KakouneLiveModes)
  r.add eb(@["Ctrl+a"], "enter-append", KakouneLiveModes)
  r.add eb(@["v"], "enter-visual", {emNormal})
  r.add eb(@["x"], "enter-visual-line", {emNormal})
  r.add eb(@["Esc"], "enter-normal", {emInsert} + KakouneVisualModes)
  # Kakoune's `o` / `O` open a line and enter insert mode. They were bound
  # to `insert-blank-line-*` — Kakoune's `Alt+o` / `Alt+O`, which stay in
  # normal mode — until 2026-09-23. `Alt+o` itself is not bound: the terminal
  # decoder (`key_names`) produces no `Alt+<letter>`, because an ESC followed
  # by a letter is also a fast `Esc` then the letter.
  r.add eb(@["o"], "open-line-below", KakouneLiveModes)
  r.add eb(@["O"], "open-line-above", KakouneLiveModes)
  r.add eb(@["Ctrl+d"], "delete-char-forward", KakouneLiveModes)
  r.add eb(@["Ctrl+f"], "delete-char-backward", KakouneLiveModes)
  r.add eb(@["D"], "delete-to-line-end", KakouneLiveModes)
  r.add eb(@["Ctrl+k"], "delete-to-line-start", KakouneLiveModes)
  r.add eb(@["Ctrl+x"], "delete-line", KakouneLiveModes)
  r.add eb(@["u"], "undo", {emNormal})
  r.add eb(@["U"], "redo", {emNormal})
  r.add eb(@["Ctrl+u"], "undo-selection", {emNormal})
  r.add eb(@["Ctrl+r"], "redo-selection", {emNormal})
  r.add eb(@["."], "repeat-last-change", {emNormal})
  r.add eb(@["%"], "select-all", KakouneLiveModes)
  r.add eb(@["X"], "select-line", KakouneLiveModes)
  r.add eb(@["&", "s"], "simplify-selection", KakouneLiveModes)
  r.add eb(@[";"], "collapse-to-cursors", KakouneLiveModes)
  r.add eb(@["\""], "flip-selections", KakouneLiveModes)
  r.add eb(@[","], "keep-primary-selection", KakouneLiveModes)
  r.add eb(@["C"], "add-cursor-below", KakouneLiveModes)
  r.add eb(@["Ctrl+c"], "add-cursor-above", KakouneLiveModes)
  r.add eb(@["Ctrl+e"], "add-cursor-at-next-match", KakouneLiveModes)
  r.add eb(@["Ctrl+g"], "add-cursor-at-each-line-of-selection", KakouneLiveModes)
  r.add eb(@["Ctrl+w"], "remove-primary-cursor", KakouneLiveModes)
  r.add eb(@["Ctrl+b"], "rotate-primary-cursor", KakouneLiveModes)
  r.add eb(@["/"], "search-forward", {emNormal})
  r.add eb(@["?"], "search-backward", {emNormal})
  r.add eb(@["s"], "search-selection", KakouneLiveModes)
  r.add eb(@["Ctrl+l"], "search-clear", {emNormal})
  r.add eb(@["Ctrl+s"], "save", {emNormal, emInsert})
  r.add eb(@["z", "c"], "fold", {emNormal})
  r.add eb(@["z", "o"], "unfold", {emNormal})
  r.add eb(@["z", "M"], "fold-all", {emNormal})
  r.add eb(@["z", "R"], "unfold-all", {emNormal})
  r.add eb(@["z", "a"], "toggle-fold", {emNormal})
  for ch in RegisterLetters:
    r.add eb(@["$", $ch], "set-register", {emNormal}, OpArgs(id: $ch))
    r.add eb(@["q", $ch], "record-macro", {emNormal}, OpArgs(id: $ch))
    r.add eb(@["@", $ch], "replay-macro", {emNormal}, OpArgs(id: $ch))
  for d in 1 .. 9:
    r.add eb(@[$d], "push-count-digit", {emNormal}, OpArgs(digit: d))
  r.add eb(@["Enter"], "insert-newline", {emInsert})
  r.add eb(@["Tab"], "insert-tab", {emInsert})
  r.add eb(@["Backspace"], "delete-char-backward", {emInsert})
  r.add eb(@["Delete"], "delete-char-forward", {emInsert})

  EditingKeymap(bindings: r)

const
  NoCollapsingForm* = [
    ## The nine motions whose `move-` form Kakoune does not have. Named as data
    ## so the nine filed rows below are generated from one list, and so the
    ## claim *"exactly nine"* is a thing a case DOES assert rather than a thing
    ## a reader counts. `test_editor_keymap_laws.nim` asserts the length AND,
    ## per member, that the `move-` form is unreachable while the `select-` form
    ## is bound — because a list of the right length naming the wrong nine would
    ## satisfy a count on its own.
    "group-right", "group-left", "group-forward", "char-forward",
    "char-backward", "search-next", "search-prev", "paragraph-forward",
    "paragraph-backward",
  ]

proc buildKakouneFiled(): seq[FiledDeclaration] =
  result = @[]
  for decl in NoCollapsingForm:
    result.add FiledDeclaration(decl: decl, forms: {ofMove}, reason:
      "**A MOTION IS A SELECTION IN KAKOUNE**, so this motion has no " &
      "collapsing form at all: the lower-case key selects and the shifted key " &
      "extends. Filed per FORM — the `select-` and `extend-` forms ARE bound — " &
      "because inventing a chord for a variant the model does not have would " &
      "be this preset diverging from the editor it is named after (§6.4)")
  result.add @[
    FiledDeclaration(decl: "group-backward", forms: {}, reason:
      "`<a-b>` upstream. `keyName` spells `Alt+` only for the function keys " &
      "and the arrows — a bare `Alt+b` is two tokens on the wire — so there " &
      "is no chord for it and inventing one would be the §6.4 divergence again"),
    FiledDeclaration(decl: "subword-forward", forms: {}, reason:
      "Kakoune has no subword motion either; `<a-w>` is WORD (whitespace-" &
      "delimited), a different concept this vocabulary does not publish"),
    FiledDeclaration(decl: "subword-backward", forms: {}, reason:
      "as `subword-forward`"),
    FiledDeclaration(decl: "insert-blank-line-below", forms: {}, reason:
      "`<a-o>` upstream — add an empty line below and stay in normal mode. " &
      "`keyName` produces no `Alt+<letter>` (see `group-backward`), so there " &
      "is no chord for it; `o` is `open-line-below`"),
    FiledDeclaration(decl: "insert-blank-line-above", forms: {}, reason:
      "`<a-O>` upstream; as `insert-blank-line-below`"),
    FiledDeclaration(decl: "line-number", forms: {}, reason:
      "`:42` — the command line, which is §4.3's text-entry scope, where " &
      "every printable key is a character and no chord resolves"),
    FiledDeclaration(decl: "syntax-left", forms: {}, reason:
      "no syntax-node motion in Kakoune, and §5.1 makes it refuse without a " &
      "parse the editor model does not yet have"),
    FiledDeclaration(decl: "syntax-right", forms: {}, reason: "as `syntax-left`"),
    FiledDeclaration(decl: "syntax-node", forms: {}, reason: "as `syntax-left`"),
    FiledDeclaration(decl: "function", forms: {}, reason: "as `syntax-left`"),
    FiledDeclaration(decl: "argument", forms: {}, reason: "as `syntax-left`"),
    FiledDeclaration(decl: "select-parent-syntax", forms: {}, reason:
      "as `syntax-left` — it needs the parse §5.1 refuses to wait for"),
    FiledDeclaration(decl: "delete-trailing-whitespace", forms: {}, reason:
      "a `|` pipe to `sed` in Kakoune, which §5.2 puts on the HOST"),
    FiledDeclaration(decl: "swap-line-up", forms: {}, reason:
      "Kakoune composes it from a selection and a pipe"),
    FiledDeclaration(decl: "swap-line-down", forms: {}, reason: "as `swap-line-up`"),
    FiledDeclaration(decl: "copy-line-up", forms: {}, reason:
      "composed from `xy` and a paste, which is the composition §2.1 exists for"),
    FiledDeclaration(decl: "copy-line-down", forms: {}, reason: "as `copy-line-up`"),
    FiledDeclaration(decl: "split-line", forms: {}, reason:
      "composed as `i<ret><esc>`"),
    FiledDeclaration(decl: "transpose-chars", forms: {}, reason:
      "no Kakoune key; it is a two-selection rotate upstream"),
    FiledDeclaration(decl: "delete-group-backward", forms: {}, reason:
      "**REACHED AS A COMPOSITION, DELIBERATELY NOT BOUND.** Kakoune deletes " &
      "a SELECTION, so this is `bd` — two named operations. A key for the " &
      "fused behaviour is the `delete-word-forward` shape §2.1 refuses"),
    FiledDeclaration(decl: "delete-group-forward", forms: {}, reason:
      "as `delete-group-backward`: `wd`"),
    FiledDeclaration(decl: "insert-newline-and-indent", forms: {}, reason:
      "an `indentwidth` hook in Kakoune, a setting rather than a chord"),
    FiledDeclaration(decl: "enter-visual-block", forms: {}, reason:
      "**KAKOUNE HAS NO BLOCK MODE.** Rectangular editing is expressed as many " &
      "selections, which is why the six multi-cursor operations ARE bound here " &
      "and are filed on the Vim side"),
    FiledDeclaration(decl: "enter-replace", forms: {}, reason:
      "no replace MODE; `m<c>` replaces the selection's characters in one " &
      "operation (`replace-char`), which is bound"),
    FiledDeclaration(decl: "begin-operator", forms: {}, reason:
      "**THE DEFINING ABSENCE.** §2.1: Kakoune is noun-then-verb, so there is " &
      "no operator-pending state to enter. `emOperatorPending` is not a scope " &
      "of any row in this file, and `DIFF-4`'s whole subject is that the two " &
      "keymaps reach one document through two different paths"),
    FiledDeclaration(decl: "save-as", forms: {}, reason: "`:w path` — the command line"),
    FiledDeclaration(decl: "save-all", forms: {}, reason: "`:wa` — the command line"),
    FiledDeclaration(decl: "reload-from-disk", forms: {}, reason:
      "`:e!` — the command line"),
    FiledDeclaration(decl: "toggle-breakpoint", forms: {}, reason:
      "A DEBUGGER SURFACE. §4.4: *'the product's own bindings for the " &
      "debugger are not re-decided by them'*"),
    FiledDeclaration(decl: "toggle-tracepoint", forms: {}, reason:
      "as `toggle-breakpoint`"),
    FiledDeclaration(decl: "toggle-flow-overlay", forms: {}, reason:
      "as `toggle-breakpoint`"),
    FiledDeclaration(decl: "jump-to-value-origin", forms: {}, reason:
      "as `toggle-breakpoint`"),
  ]

let
  KakouneKeymapTable = buildKakouneKeymap()
  KakouneFiledTable = buildKakouneFiled()

# `kakouneFiled()` WAS HERE AND IS DELETED, for `editing_keymap.anyScope`'s
# reason: `ci/test/frontend-reachability.sh` put it in the `nothing` bucket and
# it was a second way to reach `kakouneKeymap().filed`. §4.4's point is that a
# model's bindings and the claim they are graded against are ONE value so
# neither can be read without the other — a separate accessor for half of it
# works against exactly that.

proc kakouneKeymap*(): KeymapDefinition =
  ## **THE KAKOUNE MODEL.** Called by name — see `vimKeymap`'s note on why the
  ## two constructors are two names rather than one with a parameter.
  KeymapDefinition(model: kmKakoune, keymap: KakouneKeymapTable,
                   filed: KakouneFiledTable)
