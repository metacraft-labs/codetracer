## base_rows.nim — the SHAPE of a base keymap written as data, and the one
## function that turns such a table into resolver bindings.
##
## Owns: `BaseRow` (one row of a data base: chord sequence, operation, `when`,
## platforms, the table it is installed in), `definitionOf`, which builds a
## `KeymapDefinition` from a base's rows and refuses one that does not hold
## together, and a base's coverage of the operation catalogue (KL-2).
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

import std/[algorithm, sets, strutils, tables]

import ../editor/operations
import ./editing_keymap
import ./operation_catalogue
import ./scope_path
import ./when_expr

export operation_catalogue, scope_path

const
  EditorOperationPrefix* = "editor."
    ## The editor table's namespace (Input-Routing §3.1). Its operations are
    ## the editing vocabulary's (Editing-Operations §2.2), spelled without it.

type
  BaseRow* = object
    chords*: string
      ## A chord sequence as the specification writes it: `Ctrl+K Ctrl+C`.
    operation*: string
      ## `editor.<vocabulary name>` or a catalogued name
      ## (`debugger.step-over`), with a literal argument in parentheses when
      ## the operation takes one (`layout.focus-pane-by-index(3)`).
    whenText*: string
      ## The row's `when`, spelled out (`writable` expanded); `""` is always.
    platforms*: set[PlatformKind]
      ## VS Code's platform override; empty is every platform.
    table*: string
      ## The table the row is installed in (`scope_path`'s names, or a
      ## pushed layer's): "" is the editor table — every row of
      ## CUA-Keymap.md §3.1–§3.4.
    navModes*: set[NavigationMode]
      ## The terminal's navigation modes the row holds in, for the modal
      ## bases' navigation table (§5.5); empty is every mode.

  BaseRowError* = object of CatchableError

proc vocabularyName*(operation: string): string =
  ## `editor.move-char-left` → `move-char-left`; a catalogued operation
  ## (`editor.scroll-line-up`, `debugger.step-over`) keeps its namespace.
  if operation.startsWith(EditorOperationPrefix) and
     not isCatalogued(operation):
    operation[EditorOperationPrefix.len .. ^1]
  else:
    operation

proc operationProblem*(operation: string): string =
  ## Why `operation` (with its argument, `name(arg)`) names nothing a
  ## binding can run, or "" — the one check the base data and the user's
  ## file both go through.
  let (name, arg) = splitOperation(operation)
  if isCatalogued(name):
    return argumentProblem(name, arg)
  if arg.len > 0:
    return "'" & name & "' takes no argument here"
  if operationNamed(vocabularyName(name)) < 0:
    return "'" & name & "' is not an operation"
  ""

proc bindingOf*(base: BaseKeymap; row: BaseRow): EditingBinding =
  ## One data row → one resolver binding. RAISES on a chord the normaliser
  ## cannot read, an operation that names nothing, and a `when` the grammar
  ## refuses — a base whose data is wrong does not load.
  let chords = normalizeChordSequence(row.chords)
  if chords.len == 0:
    raise newException(BaseRowError, $base & ": unreadable chord '" &
                       row.chords & "'")
  let problem = operationProblem(row.operation)
  if problem.len > 0:
    raise newException(BaseRowError, $base & ": " & problem)
  let (name, arg) = splitOperation(row.operation)
  let parsed = parseWhen(row.whenText)
  if not parsed.ok:
    raise newException(BaseRowError, $base & ": when '" & row.whenText &
                       "' of " & row.chords & ": " & parsed.message)
  let table = if row.table.len == 0: EditorTable else: row.table
  EditingBinding(
    model: base,
    scope: BindingScope(modes: {}, navModes: row.navModes, products: {},
                        panes: (if table == EditorTable: {epEditor} else: {}),
                        whenText: row.whenText, cond: parsed.expr,
                        platforms: row.platforms),
    table: table,
    chords: chords.splitWhitespace(), operation: vocabularyName(name),
    args: OpArgs(), argument: arg, spelling: row.chords)

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
  # Sets, built once: this runs when a base loads, at start-up, and the
  # nested scan over the vocabulary it replaced cost the Emacs base ~70 ms.
  let vocab = vocabulary()
  let ops = operations()
  let boundSet = bound.toHashSet()
  var boundDecls = initHashSet[string]()
  for op in ops:
    if op.name in boundSet: boundDecls.incl vocab[op.decl].name
  var seen = initHashSet[string]()
  for op in ops:
    if op.name in boundSet: continue
    let decl = vocab[op.decl].name
    let anyBound = decl in boundDecls
    if anyBound:
      result.add FiledDeclaration(decl: decl, forms: {op.form}, reason: reason)
    elif decl notin seen:
      seen.incl decl
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
  ## Per TABLE: two rows in different tables never conflict — the inner
  ## table on the scope path is consulted first, and that is the rule, not
  ## an accident of order.
  ## Base-Keymaps §5.6: two rows of one base whose chord sequences are equal,
  ## or one a proper prefix of the other, on overlapping platforms, under
  ## `when`s that can BOTH hold. Decided by `when_expr.canBothHold` —
  ## enumeration over the closed context-key domains, so exact. A conflict is
  ## REPORTED, never resolved by row order: `definitionOf` refuses the base.
  result = @[]
  # Only rows that share their FIRST chord can be equal or prefixes of one
  # another: pairs are drawn within those groups (start-up cost — this runs
  # when a base loads).
  # `canBothHold` is exact (it enumerates the closed context-key domains), and
  # the same pair of `when` texts recurs across many rows: decided once.
  var bothHold = initTable[(string, string), bool]()
  var byFirst = initTable[string, seq[int]]()
  for i, b in bindings:
    byFirst.mgetOrPut(if b.chords.len > 0: b.chords[0] else: "", @[]).add i
  for i in 0 ..< bindings.len:
    let first = if bindings[i].chords.len > 0: bindings[i].chords[0] else: ""
    for j in byFirst[first]:
      if i == j: continue
      template a: untyped = bindings[i]
      template b: untyped = bindings[j]
      if tableOf(a) != tableOf(b): continue
      if a.scope.navModes != {} and b.scope.navModes != {} and
         (a.scope.navModes * b.scope.navModes) == {}: continue
      if not overlapping(a.scope.platforms, b.scope.platforms): continue
      if not isPrefixOf(a.chords, b.chords): continue
      if a.chords.len == b.chords.len and i > j: continue
      let pair = (a.scope.whenText, b.scope.whenText)
      if pair notin bothHold:
        bothHold[pair] = canBothHold(a.scope.cond, b.scope.cond)
      if not bothHold[pair]: continue
      if a.chords.len == b.chords.len:
        result.add "duplicate " & a.chords.join(" ") & ": " & a.operation &
                   " / " & b.operation
      else:
        result.add "prefix " & a.chords.join(" ") & " (" & a.operation &
                   ") of " & b.chords.join(" ") & " (" & b.operation & ")"

proc definitionOf*(base: BaseKeymap; rows: openArray[BaseRow]): KeymapDefinition =
  ## A data base, as the resolver and the coverage law read it. RAISES on a
  ## conflict between two rows (`conflictsOf`): a base that does not hold
  ## together does not load, and every suite that loads it fails by name.
  var bindings: seq[EditingBinding] = @[]
  var bound: seq[string] = @[]
  for name in LayerReachedOperations: bound.add name
  for row in rows:
    let b = bindingOf(base, row)
    bindings.add b
    if tableOf(b) == EditorTable and b.operation notin bound:
      bound.add b.operation
  let problems = conflictsOf(bindings)
  if problems.len > 0:
    raise newException(BaseRowError, $base & ": " & problems.join("; "))
  bound.sort()
  KeymapDefinition(model: base, keymap: EditingKeymap(bindings: bindings),
                   filed: filedFor(base, bound))
