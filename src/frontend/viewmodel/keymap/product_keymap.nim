## product_keymap.nim — PLAT-31: THE PRODUCT DEFAULT, and it does not move.
##
## Owns: the `KeymapDefinition` a user who has chosen nothing gets.
##
## =========================================================================
## §4.4's LAST SENTENCE, MECHANISED
## =========================================================================
##
## *"The default does not move. A user who has chosen nothing keeps the chords
## they have; Vim and Kakoune are opt-in."*
##
## The chords they have are `src/common/editing_key_bindings.TuiEditBindings`
## — the fourteen rows PLAT-30 extracted when it retired `applyEditKey`'s
## `case`, each already naming the §2.2 operation it performs. **This module
## LIFTS that table rather than transcribing it**, so "the default does not
## move" is a property of one list with two readers instead of a claim about
## two lists that agree today. `editing_key_bindings.nim`'s own header
## predicted the shape: *"when PLAT-31's resolver lands, these rows become
## default bindings in its table"*.
##
## What it does NOT do is delete that file. The terminal still dispatches
## through it against a `TextAreaWidget` (PLAT-30 recorded that residual and
## PLAT-34's `DIFF-1` is where the substrate is compared), and
## `test_edit_binding_vocabulary.nim` grades that path. Two readers of one
## table is the state this milestone leaves; one reader of one table is what
## the substrate migration leaves.
##
## =========================================================================
## THE FOURTEENTH ROW IS NOT A BINDING AND THAT IS THE INTERESTING PART
## =========================================================================
##
## `TuiEditBindings`'s last row has the empty key and names `insert-text` —
## `applyEditKey`'s `else` arm, *"and it fires only when the key stands for a
## character"*. In the resolver that is not a binding at all: it is
## §4.1's CHARACTER outcome, decided by `key_names.keyCharacter` under the
## text-entry scope. So thirteen rows become bindings, the fourteenth becomes
## the arm `LayerReachedOperations` names, and the suite asserts exactly that
## split — a fourteenth BINDING would mean the `else` arm had been turned into
## a key, which is the defect `M13` performs on the table one layer down.

import std/strutils

import ./editing_keymap

import ../../../common/editing_key_bindings

export editing_keymap
export editing_key_bindings

const
  ProductDefaultModes* = {emInsert}
    ## **ONE MODE, AND IT IS `insert`.** The terminal's Edit mode has no modal
    ## editing at all — `modal_state.nim`'s NORMAL/COMMAND/SEARCH/INSPECT are
    ## navigation modes over PANES (the status table in §'s Implementation
    ## Status says so) — so every one of the fourteen behaviours is what a key
    ## does while the user is typing into a buffer. Scoping them to `emInsert`
    ## is what makes that true in the resolver rather than true by there being
    ## no other mode.

proc buildProductKeymap(): EditingKeymap =
  var r: seq[EditingBinding] = @[]
  for row in TuiEditBindings:
    if row.key == DefaultEditKey: continue   # the `else` arm — see the header
    r.add EditingBinding(
      model: kmProductDefault,
      scope: BindingScope(modes: ProductDefaultModes, products: {},
                          panes: {epEditor}),
      chords: @[row.key], operation: row.operation, args: OpArgs(),
      spelling: row.key)
  EditingKeymap(bindings: r)

proc buildProductFiled(): seq[FiledDeclaration] =
  ## Everything the default does not bind, filed against ONE sentence.
  ##
  ## It is generated rather than written out, and that is the honest shape: the
  ## claim is not fifty separate decisions, it is a single one — *the default
  ## is the fourteen behaviours the product shipped* — and writing fifty rows
  ## would dress one decision up as fifty.
  ##
  ## Generated from `operations()` MINUS what the lift binds, so the two cannot
  ## drift: a fifteenth row in `TuiEditBindings` leaves this list one shorter
  ## on the next compile, with no edit here.
  let km = buildProductKeymap()
  var bound: seq[string] = @[]
  for b in km.bindings:
    if b.operation notin bound: bound.add b.operation
  for name in LayerReachedOperations:
    if name notin bound: bound.add name
  result = @[]
  var seen: seq[string] = @[]
  let vocab = vocabulary()
  for op in operations():
    let decl = vocab[op.decl].name
    if op.name in bound: continue
    var forms: set[OpForm] = {}
    # A declaration some of whose forms ARE bound is filed per form; one that
    # is wholly unbound is filed whole. `move-char-left` is bound and
    # `extend-char-left` is not, which is the case that needs the distinction.
    var anyBound = false
    for other in operations():
      if vocab[other.decl].name == decl and other.name in bound: anyBound = true
    if anyBound:
      forms = {op.form}
      result.add FiledDeclaration(decl: decl, forms: forms, reason:
        "§4.4: *'the default does not move'*. The product default is the " &
        "fourteen behaviours `applyEditKey` shipped; this FORM of a bound " &
        "declaration is not one of them, and Vim or Kakoune is where a user " &
        "who wants it opts in")
    else:
      if decl in seen: continue
      seen.add decl
      result.add FiledDeclaration(decl: decl, forms: {}, reason:
        "§4.4: *'the default does not move. A user who has chosen nothing " &
        "keeps the chords they have; Vim and Kakoune are opt-in.'* The " &
        "product default is the fourteen behaviours `applyEditKey` shipped " &
        "and nothing else")

let
  ProductKeymapTable = buildProductKeymap()
  ProductFiledTable = buildProductFiled()

proc productKeymap*(): KeymapDefinition =
  ## **THE DEFAULT.** Lifted from `TuiEditBindings`, never transcribed.
  KeymapDefinition(model: kmProductDefault, keymap: ProductKeymapTable,
                   filed: ProductFiledTable)
