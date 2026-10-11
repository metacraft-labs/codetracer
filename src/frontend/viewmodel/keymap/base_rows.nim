## base_rows.nim — the SHAPE of a base keymap written as data, and the one
## function that turns such a table into resolver bindings.
##
## Owns: `BaseRow` (one row of a data base: chord sequence, operation, `when`,
## platforms), `DeferredRow` (a row its specification lists whose operation
## lives in a pane table PLAT-64's router has not delivered — named and counted,
## never dropped), and `definitionOf`, which builds a `KeymapDefinition` from a
## base's rows.
##
## Refuses to own: any base's rows (`cua_keymap.nim`, `emacs_keymap.nim` hold
## nothing but data — Base-Keymaps-And-Layer-Stack.md §8 item 3: *"no
## procedure bodies, no closures and no `case` over keys"*), and resolution
## (`editing_keymap.resolve` — the one resolver).
##
## ## THE CHORDS ARE WRITTEN AS THE SPECIFICATION WRITES THEM
##
## A row's `chords` is the text of CUA-Keymap.md's (or Emacs-Keymap.md's) cell,
## VS Code's notation, and `key_names.normalizeChordSequence` — the function a
## user's configuration will go through — turns it into canonical names here.
## So the table is comparable with its oracle by eye and by program, and a
## spelling the normaliser cannot read is a build-time failure rather than a
## row that silently binds nothing (`definitionOf` raises, and every suite that
## loads a base fails by name).

import std/[algorithm, strutils]

import ../editor/operations
import ./editing_keymap
import ./when_expr

const
  EditorOperationPrefix* = "editor."
    ## The editor table's namespace (Input-Routing §3.1). Its operations are
    ## the editing vocabulary's (Editing-Operations §2.2), spelled without it.

  PaneOperation* = "an editor-PANE operation — it acts on the pane's " &
    "viewport or settings, not on EditorState — dispatched by PLAT-64's " &
    "router; PLAT-68 Phase B binds it"
  OverlayOperation* = "an operation of the find widget or the palette, " &
    "a pushed layer of PLAT-68 Phase B over PLAT-64's router"

type
  BaseRow* = object
    chords*: string
      ## A chord sequence as the specification writes it: `Ctrl+K Ctrl+C`.
    operation*: string
      ## `editor.<vocabulary name>`, with a literal argument in parentheses
      ## when the operation takes one.
    whenText*: string
      ## The row's `when`, spelled out (`writable` expanded); `""` is always.
    platforms*: set[PlatformKind]
      ## VS Code's platform override; empty is every platform.

  DeferredRow* = object
    ## A specified row this phase does not bind, with the reason. The oracle
    ## counts these beside the bound rows, so a specified row is either bound
    ## or deferred — never missing.
    chords*: string
    operation*: string
    whenText*: string
    reason*: string

  BaseRowError* = object of CatchableError

proc vocabularyName*(operation: string): string =
  ## `editor.move-char-left` → `move-char-left`.
  if operation.startsWith(EditorOperationPrefix):
    operation[EditorOperationPrefix.len .. ^1]
  else:
    operation

proc bindingOf*(base: BaseKeymap; row: BaseRow): EditingBinding =
  ## One data row → one resolver binding. RAISES on a chord the normaliser
  ## cannot read, an operation the vocabulary does not have, and a `when` the
  ## grammar refuses — a base whose data is wrong does not load.
  let chords = normalizeChordSequence(row.chords)
  if chords.len == 0:
    raise newException(BaseRowError, $base & ": unreadable chord '" &
                       row.chords & "'")
  let name = vocabularyName(row.operation)
  if operationNamed(name) < 0:
    raise newException(BaseRowError, $base & ": '" & row.operation &
                       "' is not an editing operation")
  let parsed = parseWhen(row.whenText)
  if not parsed.ok:
    raise newException(BaseRowError, $base & ": when '" & row.whenText &
                       "' of " & row.chords & ": " & parsed.message)
  EditingBinding(
    model: base,
    scope: BindingScope(modes: {}, products: {}, panes: {epEditor},
                        whenText: row.whenText, cond: parsed.expr,
                        platforms: row.platforms),
    chords: chords.splitWhitespace(), operation: name, args: OpArgs(),
    spelling: row.chords)

proc filedFor(base: BaseKeymap; bound: seq[string]): seq[FiledDeclaration] =
  ## KL-2 for a data base: every declaration the base binds no form of is
  ## FILED, generated from the vocabulary minus the bound set, so the two
  ## cannot drift. A declaration some of whose forms are bound is filed per
  ## form. One reason per base — the base's own source of truth binds no
  ## default chord to it — because that is the one decision being recorded.
  let reason = case base
    of bkCua: "VS Code 1.105.0 binds no default chord to this operation " &
              "(CUA-Keymap.md §6 lists the defaults not taken)"
    of bkEmacs: "GNU Emacs binds no default key to this operation " &
                "(Emacs-Keymap.md §4 lists the commands not taken)"
    of bkVim, bkKakoune: "the modal bases file their own"
  result = @[]
  let vocab = vocabulary()
  var seen: seq[string] = @[]
  for op in operations():
    if op.name in bound: continue
    let decl = vocab[op.decl].name
    var anyBound = false
    for other in operations():
      if vocab[other.decl].name == decl and other.name in bound:
        anyBound = true
    if anyBound:
      result.add FiledDeclaration(decl: decl, forms: {op.form}, reason: reason)
    elif decl notin seen:
      seen.add decl
      result.add FiledDeclaration(decl: decl, forms: {}, reason: reason)

proc overlapping(a, b: set[PlatformKind]): bool =
  a == {} or b == {} or (a * b) != {}

func isPrefixOf(a, b: seq[string]): bool =
  ## `a` equals `b` or is a proper prefix of it — without slicing, because
  ## this runs over every pair of rows when a base loads.
  if a.len > b.len: return false
  for i in 0 ..< a.len:
    if a[i] != b[i]: return false
  true

proc conflictsOf(bindings: openArray[EditingBinding]): seq[string] =
  ## Base-Keymaps §5.6: two rows of one base whose chord sequences are equal,
  ## or one a proper prefix of the other, on overlapping platforms, under
  ## `when`s that can BOTH hold. Decided by `when_expr.canBothHold` —
  ## enumeration over the closed context-key domains, so exact. A conflict is
  ## REPORTED, never resolved by row order: `definitionOf` refuses the base.
  result = @[]
  for i in 0 ..< bindings.len:
    for j in 0 ..< bindings.len:
      if i == j: continue
      template a: untyped = bindings[i]
      template b: untyped = bindings[j]
      if not overlapping(a.scope.platforms, b.scope.platforms): continue
      if not isPrefixOf(a.chords, b.chords): continue
      if a.chords.len == b.chords.len and i > j: continue
      if not canBothHold(a.scope.cond, b.scope.cond): continue
      if a.chords.len == b.chords.len:
        result.add "duplicate " & a.chords.join(" ") & ": " & a.operation &
                   " / " & b.operation
      else:
        result.add "prefix " & a.chords.join(" ") & " (" & a.operation &
                   ") of " & b.chords.join(" ") & " (" & b.operation & ")"

proc deferredClashes*(base: BaseKeymap; rows: openArray[BaseRow];
                      deferred: openArray[DeferredRow]): seq[string] =
  ## A DEFERRED row is a promise about Phase B: its chord is kept free for the
  ## operation it names. One whose chord a bound row of the same base already
  ## takes is a promise that cannot be kept, so it is reported here — and its
  ## operation must not be bound either, or it was not deferred at all.
  result = @[]
  var bound: seq[string] = @[]
  for r in rows:
    bound.add normalizeChordSequence(r.chords)
  for d in deferred:
    let chords = normalizeChordSequence(d.chords)
    if chords.len == 0:
      result.add "deferred " & d.chords & ": unreadable chord"
    elif chords in bound:
      result.add "deferred " & d.chords & " (" & d.operation &
                 ") is bound by a row of the same base"
    for r in rows:
      if r.operation == d.operation:
        result.add "deferred " & d.operation & " is also bound (" &
                   r.chords & ")"

proc definitionOf*(base: BaseKeymap; rows: openArray[BaseRow];
                   deferred: openArray[DeferredRow] = []): KeymapDefinition =
  ## A data base, as the resolver and the coverage law read it. RAISES on a
  ## conflict between two rows (`conflictsOf`) or a deferred row a bound row
  ## contradicts (`deferredClashes`): a base that does not hold together does
  ## not load, and every suite that loads it fails by name.
  var bindings: seq[EditingBinding] = @[]
  var bound: seq[string] = @[]
  for name in LayerReachedOperations: bound.add name
  for row in rows:
    let b = bindingOf(base, row)
    bindings.add b
    if b.operation notin bound: bound.add b.operation
  let problems = conflictsOf(bindings) & deferredClashes(base, rows, deferred)
  if problems.len > 0:
    raise newException(BaseRowError, $base & ": " & problems.join("; "))
  bound.sort()
  KeymapDefinition(model: base, keymap: EditingKeymap(bindings: bindings),
                   filed: filedFor(base, bound))
