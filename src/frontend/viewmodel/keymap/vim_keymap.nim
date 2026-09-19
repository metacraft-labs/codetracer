## vim_keymap.nim — PLAT-31: THE VIM KEYMAP, as data over PLAT-30's names.
##
## Owns: one `KeymapDefinition` — the bindings a Vim user expects, and the
## explicit, reasoned list of published operations this model does NOT claim.
##
## =========================================================================
## OPERATOR-PENDING COMPOSITION, AND WHY ONE CHORD IS THREE ROWS
## =========================================================================
##
## `Editing-Operations-And-Keymaps.md` §2.1: *"in Vim, `dw` is verb-then-noun:
## `d` enters operator-pending state and `w` supplies the range."* That is a
## statement about SCOPE, and it is what lets this keymap bind the three
## generated forms of a motion to ONE key:
##
##   | editing mode      | `w` resolves to      |
##   |-------------------|----------------------|
##   | normal            | `move-group-right`   |
##   | visual            | `extend-group-right` |
##   | operator-pending  | `select-group-right` |
##
## Three rows, one chord, three of the 224 — and no fused name anywhere. The
## *editor's* `pendingOperator` (§3) is what turns the third row's result into
## `d`'s argument, and `editing_keymap.applyResolution` discharges it with the
## operator's own published name.
##
## **`i` AND `a` ARE THE SHARPEST DEMONSTRATION THAT THE MODE DIMENSION IS
## LOAD-BEARING.** In normal mode they are `enter-insert` and `enter-append`;
## in operator-pending and visual they are the INNER and AROUND object
## prefixes. Same two keys, four meanings, one scope rule — and if the editing
## mode were folded into the product mode the way
## `CodeTracer-TUI-Edit-Mode.md` §1.2 refuses, there would be nowhere to put
## the distinction.
##
## =========================================================================
## WHAT THIS MODEL DOES NOT CLAIM, AND WHY THAT LIST IS DATA
## =========================================================================
##
## §4.4 asks for the claim to be *"stated exactly"*. `VimFiled` is that
## statement: one row per declaration Vim has no key for, with the reason.
## `covered + filed == 224` is asserted as an equality with the two sets
## disjoint, so an operation whose binding was dropped becomes a GAP — neither
## bound nor filed — rather than quietly leaving the claim.
##
## Two of the rows are worth reading before the rest, because they are
## decisions rather than observations:
##
##   * **`delete-line`, `select-all` and the other fused shapes are FILED, not
##     bound.** Vim reaches `dd` as *operator + line object + operator*, which
##     is the composition §2.1 exists for. Giving the fused behaviour its own
##     key would put a `delete-word-forward`-shaped entry back into the
##     product through the keymap after the vocabulary refused it. Which line
##     object the doubled operator supplies is NOT uniform in Vim and this
##     table records both halves — see `LinewiseAroundOperatorKeys`, whose
##     header records the one-byte defect `DIFF-4` found in the first draft.
##   * **`0` IS `line-start` HERE AND IS NOT A COUNT DIGIT.** In Vim, `0` means
##     *line-start* with no count pending and *a zero* with one — which is a
##     binding scoped by whether `EditorState.count` is non-empty. §4.3
##     publishes FOUR scope dimensions and the model is the fifth; a sixth
##     would change the cardinality the laws sweep is asserted against. So the
##     divergence is FILED against `push-count-digit`'s row rather than taken
##     silently, and §6.4's rule is the precedent: *"a translated mapping that
##     behaves slightly differently from Vim's is a defect to be REPORTED"*.
##     **No number is claimed for what a sixth dimension would cost** — it was
##     not measured (§36b).

import std/strutils

import ./editing_keymap

export editing_keymap

const
  VisualModes* = {emVisual, emVisualLine, emVisualBlock}
    ## The three visual modes, which every `extend-` row is scoped to at once.
    ## Spelled as a set once rather than three times per row.

  RegisterLetters* = "abcdefghijklmnopqrstuvwxyz"
    ## `'a`, `"a`, `qa`, `@a`. The four register/mark families are GENERATED
    ## over this string rather than written out, which is 26 rows becoming one
    ## line and, more usefully, makes "every letter is bound" a property of the
    ## loop instead of a thing to check by eye.

  ReplaceCharKeys* = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" &
                     "0123456789 !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
    ## `r<c>` — the printable ASCII a replace can substitute. Generated for the
    ## same reason, and `test_editor_keymap_laws.nim` asserts it **against the
    ## `' '` … `'~'` RANGE rather than against a remembered count**: a family
    ## that silently lost half its members would leave `r` a prefix of a smaller
    ## alphabet and nothing would say so, and a family that kept its length
    ## while changing a member would defeat a length check alone.
    ##
    ## That case was written asserting 94 and the real answer is **95** — the
    ## printable ASCII range is `0x20 … 0x7E` inclusive. Recorded because the
    ## claim *"its cardinality is asserted by the suite"* stood in this header
    ## before any case asserted it, which is the campaign's own signature defect
    ## in a doc comment: a sentence about a check is not a check.

proc eb(chords: seq[string]; op: string; modes: set[EditingMode];
        args = OpArgs()): EditingBinding =
  EditingBinding(model: kmVim,
                 scope: BindingScope(modes: modes, products: {}, panes: {epEditor}),
                 chords: chords, operation: op, args: args,
                 spelling: chords.join(" "))

proc motionRows(r: var seq[EditingBinding]; chords: seq[string]; decl: string) =
  ## ONE MOTION, THREE FORMS, THREE SCOPES — the table in the header, executed.
  r.add eb(chords, "move-" & decl, {emNormal})
  r.add eb(chords, "extend-" & decl, VisualModes)
  r.add eb(chords, "select-" & decl, {emOperatorPending})

proc objectRows(r: var seq[EditingBinding]; key: string; decl: string) =
  ## Vim's `i` / `a`, in the two modes an object means anything in.
  r.add eb(@["i", key], "select-inner-" & decl, VisualModes + {emOperatorPending})
  r.add eb(@["a", key], "select-around-" & decl, VisualModes + {emOperatorPending})

proc operatorRows(r: var seq[EditingBinding]; chords: seq[string]; op: string) =
  ## An operator is `begin-operator(op)` in NORMAL — the state the editor holds
  ## — and the operator ITSELF in visual, where the selection already exists.
  ## That asymmetry is Vim's model and is the whole of why `DIFF-4`'s two arms
  ## record different sequences for the same task.
  r.add eb(chords, "begin-operator", {emNormal}, OpArgs(operator: op))
  r.add eb(chords, op, VisualModes)

const
  LinewiseAroundOperatorKeys* = ["d", "y"]
    ## `dd` and `yy`, whose line **includes its terminator**, so they resolve to
    ## `select-around-line`.
    ##
    ## **THIS SPLIT IS A DEFECT `DIFF-4` FOUND, AND IT IS WORTH READING AS
    ## EVIDENCE RATHER THAN AS A TABLE.** Until 2026-09-19 all six keys below
    ## resolved to the published `select-line`, whose span is
    ## `lineStart … lineEnd` — the line's TEXT, terminator excluded
    ## (`operations.cSelectLine`). That makes `dd` leave an empty line behind,
    ## which is not what `dd` does in the editor this model is named after.
    ##
    ## Nothing in the Vim table could see it: the chord resolved, the operation
    ## was published, `covered + filed == 224` still held and the trie reported
    ## no conflict. What saw it was `DIFF-4`'s `delete-line` row — Vim's `dd`
    ## against Kakoune's `Ctrl+x` (`delete-line`, which deletes
    ## `lineStart … nextLineStart`) — disagreeing by exactly one byte **on all
    ## eighteen scenario documents**. That is the differential doing the job
    ## §8's table gives it, and it is why the compared artefact had to be a
    ## SECOND path to the same document rather than one path asserted against
    ## itself (§30).
    ##
    ## `y` is here with `d` because Vim's `yy` yanks the terminator too — a
    ## register pasted with `p` lands on a new line. **WHAT THAT DOES NOT BUY
    ## IS LINEWISE PASTE**, and this is said rather than left to be discovered:
    ## a register in `EditorState` carries text and not a linewise FLAG, so
    ## `yy` then `p` inserts at the caret rather than below the line. The
    ## yanked TEXT is Vim's; the paste PLACEMENT is not, and modelling register
    ## type is a change to `Register` that this milestone does not take.

  LinewiseInnerOperatorKeys* = ["c", ">", "<", "="]
    ## `cc`, `>>`, `<<`, `==`, whose line is its TEXT: `cc` leaves you on an
    ## empty line in insert mode rather than removing the line, and the three
    ## indent operators rewrite lines in place. They keep `select-line`.
    ##
    ## **THE NON-UNIFORMITY IS VIM'S, NOT THIS TABLE'S**, which is why it is two
    ## named lists and not one list with a comment. A single list would have to
    ## pick one of the two behaviours and be wrong about the other three keys.
    ##
    ## `select-line` and `select-inner-line` have the same span for a single
    ## caret, and the COMMAND is bound here rather than the object's inner form
    ## for §4.4's reason: `select-line` is a published operation that Vim would
    ## otherwise reach through no chord at all, and a filed row saying "Vim has
    ## no way to select a line" would be false about the editor that spells it
    ## `V`.
    ##
    ## **BOTH LISTS ARE LISTS AND NOT A LINE INSIDE `operatorRows`**, because
    ## the two-chord operators (`gc`, `gU`, `gu`, `g~`) have no linewise
    ## shorthand and deriving the key as *"the last chord"* would have bound
    ## `c`, `U`, `u` and `~` in operator-pending — of which `c` collides with
    ## `change-selection`'s own shorthand. That is a DUPLICATE the trie refuses
    ## at build time; it is named here so the next reader knows the lists are a
    ## decision rather than a transcription.

proc buildVimKeymap(): EditingKeymap =
  var r: seq[EditingBinding] = @[]

  # --- A. Motions -------------------------------------------------------
  motionRows(r, @["h"], "char-left")
  motionRows(r, @["Left"], "char-left")
  motionRows(r, @["l"], "char-right")
  motionRows(r, @["Right"], "char-right")
  motionRows(r, @["w"], "group-right")
  motionRows(r, @["b"], "group-left")
  motionRows(r, @["k"], "line-up")
  motionRows(r, @["Up"], "line-up")
  motionRows(r, @["j"], "line-down")
  motionRows(r, @["Down"], "line-down")
  motionRows(r, @["g", "k"], "display-line-up")
  motionRows(r, @["g", "j"], "display-line-down")
  motionRows(r, @["PageUp"], "page-up")
  motionRows(r, @["Ctrl+b"], "page-up")
  motionRows(r, @["PageDown"], "page-down")
  motionRows(r, @["Ctrl+f"], "page-down")
  motionRows(r, @["0"], "line-start")
  motionRows(r, @["$"], "line-end")
  motionRows(r, @["^"], "line-start-smart")
  motionRows(r, @["g", "0"], "display-line-start")
  motionRows(r, @["g", "$"], "display-line-end")
  motionRows(r, @["g", "g"], "doc-start")
  motionRows(r, @["G"], "doc-end")
  motionRows(r, @["%"], "matching-bracket")
  motionRows(r, @["}"], "paragraph-forward")
  motionRows(r, @["{"], "paragraph-backward")
  motionRows(r, @["n"], "search-next")
  motionRows(r, @["N"], "search-prev")
  motionRows(r, @["Ctrl+o"], "jump-back")
  # `Ctrl+i` and `Tab` are ONE BYTE on the wire (0x09) and `keyName` spells it
  # `Tab`. Binding the spelling `Ctrl+i` would be binding a chord no real
  # terminal can deliver, which is exactly what the pty suite exists to catch.
  motionRows(r, @["Tab"], "jump-forward")
  for ch in RegisterLetters:
    r.add eb(@["'", $ch], "move-mark", {emNormal}, OpArgs(id: $ch))
    r.add eb(@["'", $ch], "extend-mark", VisualModes, OpArgs(id: $ch))
    r.add eb(@["'", $ch], "select-mark", {emOperatorPending}, OpArgs(id: $ch))

  # --- B. Text objects --------------------------------------------------
  objectRows(r, "w", "word")
  objectRows(r, "p", "paragraph")
  objectRows(r, "(", "parens")
  objectRows(r, "[", "brackets")
  objectRows(r, "{", "braces")
  objectRows(r, "<", "angle")
  objectRows(r, "'", "quote-single")
  objectRows(r, "\"", "quote-double")
  objectRows(r, "`", "quote-back")
  objectRows(r, "t", "tag")

  # --- C. Operators -----------------------------------------------------
  operatorRows(r, @["d"], "delete-selection")
  operatorRows(r, @["c"], "change-selection")
  operatorRows(r, @["y"], "yank-selection")
  operatorRows(r, @[">"], "indent-selection")
  operatorRows(r, @["<"], "dedent-selection")
  operatorRows(r, @["="], "reindent-selection")
  operatorRows(r, @["g", "c"], "toggle-comment")
  operatorRows(r, @["g", "U"], "upper-case")
  operatorRows(r, @["g", "u"], "lower-case")
  operatorRows(r, @["g", "~"], "swap-case")
  for key in LinewiseAroundOperatorKeys:
    r.add eb(@[key], "select-around-line", {emOperatorPending})
  for key in LinewiseInnerOperatorKeys:
    r.add eb(@[key], "select-line", {emOperatorPending})
  # Not operators in Vim: they act on the caret or the line, never on a range
  # the user has just produced.
  r.add eb(@["P"], "paste-before", {emNormal})
  r.add eb(@["p"], "paste-after", {emNormal})
  r.add eb(@["p"], "paste-replace", VisualModes)
  r.add eb(@["J"], "join-lines", {emNormal} + VisualModes)
  for ch in ReplaceCharKeys:
    r.add eb(@["r", $ch], "replace-char", {emNormal} + VisualModes,
             OpArgs(ch: $ch))

  # --- D. Commands ------------------------------------------------------
  r.add eb(@["i"], "enter-insert", {emNormal})
  r.add eb(@["I"], "enter-insert-line-start", {emNormal})
  r.add eb(@["a"], "enter-append", {emNormal})
  r.add eb(@["A"], "enter-append-line-end", {emNormal})
  r.add eb(@["v"], "enter-visual", {emNormal})
  r.add eb(@["V"], "enter-visual-line", {emNormal})
  r.add eb(@["Ctrl+v"], "enter-visual-block", {emNormal})
  r.add eb(@["R"], "enter-replace", {emNormal})
  r.add eb(@["Esc"], "enter-normal", {emInsert, emReplace} + VisualModes)
  r.add eb(@["Esc"], "cancel-operator", {emOperatorPending})
  r.add eb(@["o"], "insert-blank-line-below", {emNormal})
  r.add eb(@["O"], "insert-blank-line-above", {emNormal})
  r.add eb(@["x"], "delete-char-forward", {emNormal})
  r.add eb(@["X"], "delete-char-backward", {emNormal})
  r.add eb(@["D"], "delete-to-line-end", {emNormal})
  r.add eb(@["u"], "undo", {emNormal})
  r.add eb(@["Ctrl+r"], "redo", {emNormal})
  r.add eb(@["."], "repeat-last-change", {emNormal})
  r.add eb(@["/"], "search-forward", {emNormal})
  r.add eb(@["?"], "search-backward", {emNormal})
  r.add eb(@["*"], "search-selection", {emNormal} + VisualModes)
  r.add eb(@["Ctrl+l"], "search-clear", {emNormal})
  r.add eb(@["Ctrl+s"], "save", {emNormal} + {emInsert})
  r.add eb(@["z", "c"], "fold", {emNormal})
  r.add eb(@["z", "o"], "unfold", {emNormal})
  r.add eb(@["z", "M"], "fold-all", {emNormal})
  r.add eb(@["z", "R"], "unfold-all", {emNormal})
  r.add eb(@["z", "a"], "toggle-fold", {emNormal})
  for ch in RegisterLetters:
    r.add eb(@["\"", $ch], "set-register", {emNormal}, OpArgs(id: $ch))
    r.add eb(@["q", $ch], "record-macro", {emNormal}, OpArgs(id: $ch))
    r.add eb(@["@", $ch], "replay-macro", {emNormal}, OpArgs(id: $ch))
  for d in 1 .. 9:
    r.add eb(@[$d], "push-count-digit", {emNormal, emOperatorPending},
             OpArgs(digit: d))
  # Insert mode. `Tab` and `Enter` are bound HERE and mean something else in
  # normal mode, which the scope keeps apart with no special case.
  r.add eb(@["Enter"], "insert-newline", {emInsert})
  r.add eb(@["Tab"], "insert-tab", {emInsert})
  r.add eb(@["Backspace"], "delete-char-backward", {emInsert, emReplace})
  r.add eb(@["Delete"], "delete-char-forward", {emInsert, emReplace})
  r.add eb(@["Ctrl+w"], "delete-group-backward", {emInsert})
  r.add eb(@["Ctrl+u"], "delete-to-line-start", {emInsert})

  EditingKeymap(bindings: r)

const
  VimFiled*: seq[FiledDeclaration] = @[
    ## **WHAT THE VIM MODEL DOES NOT CLAIM.** One row per declaration, with the
    ## reason, and the reason is a fact about Vim or about this vocabulary
    ## rather than "not done yet".
    FiledDeclaration(decl: "char-forward", forms: {}, reason:
      "Vim's motions are visual; `h`/`l` are `char-left`/`char-right` and it " &
      "has no bidi-agnostic pair to bind"),
    FiledDeclaration(decl: "char-backward", forms: {}, reason:
      "as `char-forward`"),
    FiledDeclaration(decl: "group-forward", forms: {}, reason:
      "as `char-forward`: `w`/`b` are the visual pair"),
    FiledDeclaration(decl: "group-backward", forms: {}, reason:
      "as `group-forward`"),
    FiledDeclaration(decl: "subword-forward", forms: {}, reason:
      "Vim has no subword motion; `camelcasemotion` is a plugin, and §6.2 is " &
      "explicit that a plugin's mappings are not translatable"),
    FiledDeclaration(decl: "subword-backward", forms: {}, reason:
      "as `subword-forward`"),
    FiledDeclaration(decl: "line-number", forms: {}, reason:
      "reached as `:42`, which is the COMMAND LINE — §4.3's text-entry scope, " &
      "where every printable key is a character and no chord resolves"),
    FiledDeclaration(decl: "syntax-left", forms: {}, reason:
      "Vim has no syntax-node motion, and §5.1 makes it refuse without a " &
      "parse the editor model does not yet have"),
    FiledDeclaration(decl: "syntax-right", forms: {}, reason:
      "as `syntax-left`"),
    FiledDeclaration(decl: "subword", forms: {}, reason:
      "no subword object in Vim, for `subword-forward`'s reason"),
    FiledDeclaration(decl: "line", forms: {ofInner}, reason:
      "**FILED PER FORM, AND THE NARROWING IS WHAT `DIFF-4` BOUGHT.** Vim has " &
      "no `il`, so `select-inner-line` is reached by no chord. `al` it DOES " &
      "have, under another spelling: the operator doubled (`dd`, `yy`) is " &
      "Vim's line-including-its-terminator, which is exactly " &
      "`select-around-line` — see `LinewiseAroundOperatorKeys` for the one-byte " &
      "disagreement on all eighteen documents that established it. This row " &
      "read `forms: {}` until then, which filed an operation the model " &
      "reaches"),
    FiledDeclaration(decl: "indent-block", forms: {}, reason:
      "`vim-indent-object` is a plugin"),
    FiledDeclaration(decl: "syntax-node", forms: {}, reason:
      "needs a parse (§5.1) and has no Vim key"),
    FiledDeclaration(decl: "function", forms: {}, reason: "as `syntax-node`"),
    FiledDeclaration(decl: "argument", forms: {}, reason: "as `syntax-node`"),
    FiledDeclaration(decl: "line-comment", forms: {}, reason:
      "Vim core has no comment command at all; `gc` is `vim-commentary`, and " &
      "this model binds the TOGGLE because that is the one shape every " &
      "comment plugin agrees on"),
    FiledDeclaration(decl: "line-uncomment", forms: {}, reason: "as `line-comment`"),
    FiledDeclaration(decl: "block-comment", forms: {}, reason: "as `line-comment`"),
    FiledDeclaration(decl: "block-uncomment", forms: {}, reason: "as `line-comment`"),
    FiledDeclaration(decl: "pipe-selection", forms: {}, reason:
      "Kakoune's `|`. Vim's `!` is a command-line construct, and §5.2 puts " &
      "the process on the HOST rather than in the operation"),
    FiledDeclaration(decl: "insert-newline-and-indent", forms: {}, reason:
      "Vim spells it `autoindent`, an OPTION — §6.1 lists `expandtab` and its " &
      "family among what a `.vimrc` import translates, and an option is not a " &
      "chord"),
    FiledDeclaration(decl: "delete-group-forward", forms: {}, reason:
      "no insert-mode key in Vim; `dw` is the operator composition"),
    FiledDeclaration(decl: "delete-line", forms: {}, reason:
      "**REACHED, AND DELIBERATELY NOT BOUND.** `dd` is " &
      "`begin-operator(delete-selection)` + `select-line` + the operator — the " &
      "composition §2.1 exists for. A key for the FUSED behaviour would put a " &
      "`delete-word-forward`-shaped entry back into the product through the " &
      "keymap after the vocabulary refused it"),
    FiledDeclaration(decl: "delete-trailing-whitespace", forms: {}, reason:
      "a `:%s///` idiom in Vim, not a chord"),
    FiledDeclaration(decl: "swap-line-up", forms: {}, reason:
      "`unimpaired`'s `[e`/`]e` is a plugin"),
    FiledDeclaration(decl: "swap-line-down", forms: {}, reason: "as `swap-line-up`"),
    FiledDeclaration(decl: "copy-line-up", forms: {}, reason:
      "Vim composes it as `yyP`, three operations"),
    FiledDeclaration(decl: "copy-line-down", forms: {}, reason: "as `copy-line-up`"),
    FiledDeclaration(decl: "split-line", forms: {}, reason:
      "Vim composes it as `i<CR><Esc>`"),
    FiledDeclaration(decl: "transpose-chars", forms: {}, reason:
      "Vim composes it as `xp`, two operations"),
    FiledDeclaration(decl: "select-all", forms: {}, reason:
      "Vim composes it as `ggVG`, four operations — `delete-line`'s reason"),
    FiledDeclaration(decl: "select-parent-syntax", forms: {}, reason:
      "needs a parse (§5.1)"),
    FiledDeclaration(decl: "simplify-selection", forms: {}, reason:
      "Kakoune's multi-selection vocabulary; Vim has ONE selection, so there " &
      "is nothing to simplify"),
    FiledDeclaration(decl: "collapse-to-cursors", forms: {}, reason: "as `simplify-selection`"),
    FiledDeclaration(decl: "flip-selections", forms: {}, reason: "as `simplify-selection`"),
    FiledDeclaration(decl: "keep-primary-selection", forms: {}, reason: "as `simplify-selection`"),
    FiledDeclaration(decl: "add-cursor-above", forms: {}, reason:
      "multi-cursor is `vim-multiple-cursors`, a plugin"),
    FiledDeclaration(decl: "add-cursor-below", forms: {}, reason: "as `add-cursor-above`"),
    FiledDeclaration(decl: "add-cursor-at-next-match", forms: {}, reason: "as `add-cursor-above`"),
    FiledDeclaration(decl: "add-cursor-at-each-line-of-selection", forms: {}, reason:
      "as `add-cursor-above`"),
    FiledDeclaration(decl: "remove-primary-cursor", forms: {}, reason: "as `add-cursor-above`"),
    FiledDeclaration(decl: "rotate-primary-cursor", forms: {}, reason: "as `add-cursor-above`"),
    FiledDeclaration(decl: "undo-selection", forms: {}, reason:
      "Vim has no selection history; `gv` restores the LAST visual selection " &
      "and is not a stack"),
    FiledDeclaration(decl: "redo-selection", forms: {}, reason: "as `undo-selection`"),
    FiledDeclaration(decl: "save-as", forms: {}, reason:
      "`:w path` — the command line, as `line-number`"),
    FiledDeclaration(decl: "save-all", forms: {}, reason: "`:wa` — as `save-as`"),
    FiledDeclaration(decl: "reload-from-disk", forms: {}, reason: "`:e!` — as `save-as`"),
    FiledDeclaration(decl: "toggle-breakpoint", forms: {}, reason:
      "A DEBUGGER SURFACE. §4.4: *'the product's own bindings for the " &
      "debugger are not re-decided by them'* — `F9` is CodeTracer-TUI.md " &
      "§4.2's and a keymap model does not take it"),
    FiledDeclaration(decl: "toggle-tracepoint", forms: {}, reason: "as `toggle-breakpoint`"),
    FiledDeclaration(decl: "toggle-flow-overlay", forms: {}, reason: "as `toggle-breakpoint`"),
    FiledDeclaration(decl: "jump-to-value-origin", forms: {}, reason: "as `toggle-breakpoint`"),
  ]

let VimKeymapTable = buildVimKeymap()

proc vimKeymap*(): KeymapDefinition =
  ## **THE VIM MODEL.** Called by name, so a `DIFF-4` arm that made one side
  ## call the other is visible in the source as well as in the answer
  ## (Verification-Harness-Traps §30a).
  KeymapDefinition(model: kmVim, keymap: VimKeymapTable, filed: VimFiled)
