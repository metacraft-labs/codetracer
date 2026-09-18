## editing_key_bindings.nim — PLAT-30: what `edit_binding.applyEditKey` WAS,
## re-expressed as bindings.
##
## Owns: the fourteen behaviours the terminal's editing dispatch implements,
## as DATA, each naming the operation of
## `codetracer-specs/GUI/Editing-Operations-And-Keymaps.md` §2.2 it performs.
##
## ## WHY THIS FILE EXISTS AND WHY IT IS IN `src/common/`
##
## `applyEditKey` was *"thirteen `of` arms over key names plus an `else` that
## inserts the character, fourteen behaviours, and the entire editing path
## today"* — which is the shape CTUI-9 rejects, stated in
## Editing-Operations-And-Keymaps.md §1: *"`applyEditKey` is a `case` over key
## names inside the buffer binding, which is exactly the shape CTUI-9
## rejects."*
##
## The `case` is gone. What replaces it is this table plus a dispatch over
## `EditBehaviour`, and the difference is not cosmetic — it is the three
## questions CTUI-9 says a `case` cannot be asked:
##
##   * is a key bound twice? — `duplicateEditKeys()`
##   * does every behaviour have a binding? — `unboundBehaviours()`
##   * does every binding name a published operation? — asserted by
##     `test_editor_vocabulary_oracle.nim` against the 224, and the reason this
##     table is in `src/common/` rather than inside `tui/app/`: the ViewModel's
##     suite can read it and `tui/app`'s layer rule is untouched, because
##     nothing here imports `isonim_tui` or `viewmodel/`.
##
## ## THIS IS NOT THE KEYMAP LAYER, AND SAYING SO IS THE POINT
##
## PLAT-31 owns the resolver, the scopes, and the Vim and Kakoune keymaps.
## What PLAT-30 owes is that the product's one existing editing path stops
## being a second vocabulary beside the published one. **This table is the
## join**: fourteen rows, each naming one of the 224, so the terminal's editing
## path is expressed in the vocabulary's own names rather than in a private
## enum. When PLAT-31's resolver lands, these rows become default bindings in
## its table and this file goes away; until then they are the evidence that the
## fourteen behaviours survived.
##
## ## THE TWO DIVERGENCES, FILED RATHER THAN SMOOTHED OVER
##
##   1. **`Tab` fuses two published operations.** `isonim-tui`'s
##      `TextAreaWidget.indent` inserts `tabSize` spaces at the cursor when
##      there is no multi-line selection and indents every selected line when
##      there is — which is `insert-tab` and `indent-selection` behind one key.
##      The row names `indent-selection`, because that is the behaviour the key
##      has whenever a selection exists, and the fusion is what PLAT-31's
##      editing-mode scope resolves: `Tab` is `insert-tab` in insert mode and
##      `indent-selection` in visual mode.
##   2. **`Home` is not two-stage here.** The published `line-start-smart` goes
##      to the first non-blank and then to column 0; the widget's
##      `moveLineStart` goes to column 0. The row names `move-line-start`,
##      which is what it does.
##
## Both are named in the rows' `divergence` field rather than in prose alone,
## so a reader of the table sees them and a check can count them.

type
  EditBehaviour* = enum
    ## The fourteen. **Names the BEHAVIOUR, not the key** — which is what makes
    ## the dispatch a `case` over this enum rather than over `"Left"`.
    ebMoveCharLeft = "move-caret-left"
    ebMoveCharRight = "move-caret-right"
    ebMoveLineUp = "move-caret-up"
    ebMoveLineDown = "move-caret-down"
    ebMoveLineStart = "move-caret-line-start"
    ebMoveLineEnd = "move-caret-line-end"
    ebDeleteCharBackward = "delete-cluster-before"
    ebDeleteCharForward = "delete-cluster-after"
    ebInsertNewline = "split-the-line"
    ebIndentSelection = "indent"
    ebDedentSelection = "dedent"
    ebUndo = "undo"
    ebRedo = "redo"
    ebInsertText = "insert-the-character"

  EditEffect* = enum
    ## What the outcome enum in `edit_binding.nim` must report for this row.
    ## Carried here so the two cannot drift: a row that moved the caret must
    ## not mark the file dirty, which is the distinction `EditKeyOutcome`
    ## exists for.
    eeMoved = "moved"
    eeChanged = "changed"

  EditBindingRow* = object
    key*: string
      ## `keymap.keyName`'s canonical spelling. `""` is the DEFAULT row — the
      ## `else` arm — and it fires only when the key stands for a character.
    behaviour*: EditBehaviour
    operation*: string
      ## The published §2.2 operation this row performs. Checked against the
      ## 224 by the ViewModel's oracle suite.
    effect*: EditEffect
    divergence*: string
      ## `""` when the row's behaviour is exactly the named operation's.
      ## Otherwise what the substrate does instead — see the header's two.

const
  TuiEditBindings*: array[14, EditBindingRow] = [
    EditBindingRow(key: "Left", behaviour: ebMoveCharLeft,
                   operation: "move-char-left", effect: eeMoved,
                   divergence: ""),
    EditBindingRow(key: "Right", behaviour: ebMoveCharRight,
                   operation: "move-char-right", effect: eeMoved,
                   divergence: ""),
    EditBindingRow(key: "Up", behaviour: ebMoveLineUp,
                   operation: "move-line-up", effect: eeMoved,
                   divergence: ""),
    EditBindingRow(key: "Down", behaviour: ebMoveLineDown,
                   operation: "move-line-down", effect: eeMoved,
                   divergence: ""),
    EditBindingRow(key: "Home", behaviour: ebMoveLineStart,
                   operation: "move-line-start", effect: eeMoved,
                   divergence: "the published `line-start-smart` is two-stage; " &
                     "the widget's `moveLineStart` goes to column 0 and stops"),
    EditBindingRow(key: "End", behaviour: ebMoveLineEnd,
                   operation: "move-line-end", effect: eeMoved,
                   divergence: ""),
    EditBindingRow(key: "Backspace", behaviour: ebDeleteCharBackward,
                   operation: "delete-char-backward", effect: eeChanged,
                   divergence: ""),
    EditBindingRow(key: "Delete", behaviour: ebDeleteCharForward,
                   operation: "delete-char-forward", effect: eeChanged,
                   divergence: ""),
    EditBindingRow(key: "Enter", behaviour: ebInsertNewline,
                   operation: "insert-newline", effect: eeChanged,
                   divergence: ""),
    EditBindingRow(key: "Tab", behaviour: ebIndentSelection,
                   operation: "indent-selection", effect: eeChanged,
                   divergence: "the widget fuses `insert-tab` into this key " &
                     "when there is no multi-line selection; PLAT-31's " &
                     "editing-mode scope is what separates them"),
    EditBindingRow(key: "Shift+Tab", behaviour: ebDedentSelection,
                   operation: "dedent-selection", effect: eeChanged,
                   divergence: ""),
    EditBindingRow(key: "Ctrl+z", behaviour: ebUndo,
                   operation: "undo", effect: eeChanged, divergence: ""),
    EditBindingRow(key: "Ctrl+y", behaviour: ebRedo,
                   operation: "redo", effect: eeChanged, divergence: ""),
    EditBindingRow(key: "", behaviour: ebInsertText,
                   operation: "insert-text", effect: eeChanged,
                   divergence: ""),
  ]

  EditBehaviourCount* = 14
    ## Asserted against `TuiEditBindings.len` AND against the enum's own span,
    ## so the three cannot drift apart.

  DefaultEditKey* = ""
    ## The `else` arm's key, named rather than spelled at the call sites.

func editBindingIndex*(key: string): int =
  ## The row bound to `key`, or -1. **A linear scan and not a `case`**: that is
  ## the whole change. The table can be asked questions; the `case` could not.
  for i, row in TuiEditBindings:
    if row.key.len > 0 and row.key == key: return i
  -1

func defaultEditBindingIndex*(): int =
  for i, row in TuiEditBindings:
    if row.key == DefaultEditKey: return i
  -1

func duplicateEditKeys*(): seq[string] =
  ## CTUI-9's first question. A key bound twice would resolve to whichever row
  ## the scan reached first, silently.
  result = @[]
  for i, a in TuiEditBindings:
    for j, b in TuiEditBindings:
      if i < j and a.key == b.key and a.key notin result:
        result.add a.key

func unboundBehaviours*(): seq[EditBehaviour] =
  ## CTUI-9's second question, in the direction that matters: a behaviour the
  ## enum declares and the table does not bind is a behaviour that vanished in
  ## the retirement.
  result = @[]
  for b in EditBehaviour:
    var found = false
    for row in TuiEditBindings:
      if row.behaviour == b: found = true
    if not found: result.add b

func declaredDivergences*(): seq[string] =
  ## The rows whose behaviour is not exactly the operation they name. **Two,
  ## and counted rather than described**, so a third arriving without a note is
  ## a red assertion instead of a paragraph nobody re-read.
  result = @[]
  for row in TuiEditBindings:
    if row.divergence.len > 0: result.add row.key
