## editing_keymap.nim — PLAT-31: THE KEYMAP LAYER.
##
## Owns: the pure resolver of
## `codetracer-specs/GUI/Editing-Operations-And-Keymaps.md` §4 — *(chord
## sequence, editor state, scope) → an operation, a pending prefix, a character
## to insert, or nothing* — the trie it resolves through, the conflict
## detection over it, the configuration format that layers over it, and the one
## function that EXECUTES a resolution against an `EditorState`.
##
## =========================================================================
## NOTHING IN THE EDITING CORE KNOWS ABOUT KEYS, AND THIS IS THE OTHER SIDE
## =========================================================================
##
## §1: *"An external keymap layer reads input, resolves it against a loaded
## configuration, and executes a NAMED OPERATION over the ViewModel."* This
## module is that layer. It sits BESIDE `viewmodel/editor/` and not inside it,
## which is not a filing convention:
## `ci/test/editor-import-closure.sh` walks the transitive import closure of
## `src/frontend/viewmodel/editor/` and PLAT-31 added check 7 to it — **no
## module of this package may appear in that closure**. The dependency runs one
## way, mechanically, and the mechanism is the one PLAT-29 already built rather
## than a second scanner: writing a new one would reopen all six routes past a
## text scan that `ci/lib/nim-imports.sh` closes.
##
## **THE PLANTED IMPORT THAT PROVES IT REDDENS IS IN
## `tests/unit/test_editor_async_closure.nim`** — route `rtKeymapImport` — and
## not in `test_editor_keymap_laws.nim`, which is where it would more naturally
## have gone. The reason is that grading a shell gate means SPAWNING one, and
## that suite is native-only for exactly that reason while the laws suite runs
## on C, JS and wasm32. A case asserting *"the gate refused this tree"* is green,
## for free, on a target that could not have run the gate at all.
##
## What the laws suite carries instead is the half that DOES run everywhere: a
## scan asserting that no module of the editing core names a module of this
## package, and that this module names the editing core — so the check is about
## a DIRECTION rather than about two modules that happen not to speak.
##
## =========================================================================
## THE TRIE, AND WHY IT IS A TRIE
## =========================================================================
##
## A keymap is DATA (§4.2): a `seq[EditingBinding]`. A binding is a chord
## SEQUENCE, so resolution is a prefix walk, and `buildTrie` turns the seq into
## one node per distinct prefix. Two facts about that shape are the reason it is
## worth having rather than the linear `matchExact` + `hasPrefix` pair
## `tui/app/input/keymap.nim` uses:
##
##   * **A duplicate is a node that already carries a binding.** The detector is
##     the insert, not a second sweep.
##   * **A prefix conflict is a node that carries a binding AND has children.**
##     *"No chord bound twice in a scope, no chord a proper prefix of another in
##     the same scope"* is then one traversal over the structure, rather than an
##     O(n²) comparison over a list, and — the part that matters more — it is
##     the SAME structure resolution walks, so a conflict the detector cannot
##     see is a conflict resolution cannot hit.
##
## **NO TIMING FIGURE IS CLAIMED FOR THE TRIE OVER THE LINEAR SCAN, BECAUSE
## NONE WAS TAKEN.** Verification-Harness-Traps §36b is explicit that *"the
## winner is gated, the losers are prose"* and that a rejected alternative's
## number rots precisely because nothing re-takes it. The argument above is
## structural and needs no number; the performance argument would need one and
## does not have one, so it is not made.
##
## **ONE TRIE PER SCOPE, BUILT FROM THE BINDINGS ADMISSIBLE IN IT.** The scope
## (§4.3) is five dimensions and the product of their cardinalities is 84 tries;
## building them all eagerly would be a cache, and a cache is a second thing to
## invalidate. `trieFor(km, scope)` filters and builds, and a front-end calls it
## when the scope changes. That also makes the conflict rule exact: *"no chord
## bound twice IN A SCOPE"* is a property of the trie the scope produces, so the
## detector is run per scope and has nothing to assume.
##
## =========================================================================
## MODAL STATE LIVES IN THE EDITOR (§3) AND THIS MODULE HOLDS NONE OF IT
## =========================================================================
##
## Counts, the pending register, the operator-pending state, the recording
## macro, the last change and the mode are fields of `EditorState`; PLAT-30 put
## them there and this milestone only READS them. The seventh item on §3's list
## — *"the pending-chord buffer"* — was the one PLAT-30 deliberately left out
## (`editor_state.nim`: *"the chord buffer belongs to PLAT-31's resolver, which
## does not exist, and a field nothing writes is a field that looks like
## coverage"*). It is `EditorState.pending` now, for §3's own second reason:
## *"a pending `d`, a pending count `12`, a recording macro and the active
## register are all things the STATUS LINE shows"*, and a keymap-private field
## would have to be surfaced through a second channel per front-end.
##
## So this module has **no mutable module state at all**. `resolve` is a
## function of `(trie, state, scope, key, nowMs)`; the new pending buffer is
## part of its RESULT rather than a write, and `applyResolution` is what puts it
## back on the state.
##
## =========================================================================
## EVERY TRANSITION THIS LAYER PERFORMS IS ONE OF PLAT-30's 224
## =========================================================================
##
## `applyResolution` composes a chord's effect out of NAMED OPERATIONS and
## assigns no `EditorState` field of its own except the pending-chord buffer the
## resolver just computed. Concretely, Vim's `dw` is
##
##     begin-operator(delete-selection)   <- the `d` chord
##     select-group-right                 <- the `w` chord, in operator-pending scope
##     delete-selection                   <- the discharge
##     cancel-operator                    <- the transients cleared
##
## and Kakoune's `wd` is
##
##     select-group-right
##     delete-selection
##
## — the same two operations in a different order (§2.1), reached by two
## different paths, ending at the same document. That is `DIFF-4`'s subject and
## it is why the compared artefact is the OPERATION SEQUENCE and not only the
## document: the documents agree trivially, the sequences do not.
##
## The discharge uses the published `cancel-operator` rather than a private
## assignment for a reason that is checkable rather than tasteful: it makes
## *"the keymap layer's whole effect on the editor is a sequence of the 224"*
## true by construction, so the recorded sequence a `DIFF-4` case compares IS
## the effect rather than a log beside it. `test_editor_keymap_laws.nim` scans
## this module's body for a field assignment on the state and requires the set
## to be exactly the pending buffer.

import std/[algorithm, strutils, tables]

import ../editor/operations
import ../viewmodels/product_mode

import ../../../common/key_names

export operations
export key_names
# `ProductMode` from the module that OWNS it (PLAT-16), not a second
# two-member enum of this module's own. §4.3's first scope dimension is
# "the existing `ActionScope`", and the existing one is this.
export product_mode

type
  KeymapModel* = enum
    ## §4.2: *"a keymap MODEL (Vim, Kakoune, or the product default) is a set of
    ## defaults for that table"*. The fifth scope dimension, and the one the
    ## differential axis is about.
    kmProductDefault = "default"
    kmVim = "vim"
    kmKakoune = "kakoune"

  EditingPane* = enum
    ## §4.3's second dimension: *"the editor has focus, or another pane does"*.
    ##
    ## TWO MEMBERS AND NOT A PANE ENUM. The question a binding's scope asks is
    ## not *which* pane has focus — it is whether the EDITOR does, because a
    ## chord bound in editor scope must not fire while the call-stack pane owns
    ## the keyboard. A richer enum here would be a second pane vocabulary
    ## beside the front-ends' own, and the resolver has no use for its extra
    ## members.
    epEditor = "editor"
    epOtherPane = "other-pane"

  EditingScope* = object
    ## The five dimensions, as one value. §4.3 plus §4.2's model.
    ##
    ## `textEntry` is supplied by the caller rather than derived: the terminal
    ## reads it off `modal_state.isTextEntry` and a web front-end off whatever
    ## its focused widget says. What this module owns is what the flag MEANS,
    ## which is `keyCharacter` and nothing else.
    model*: KeymapModel
    product*: ProductMode
    pane*: EditingPane
    mode*: EditingMode
    textEntry*: bool

  BindingScope* = object
    ## The scope a BINDING claims. An empty set means "every value of this
    ## dimension", which is how the common case (a binding that means the same
    ## thing in Debug and in Edit) stays one row.
    modes*: set[EditingMode]
    products*: set[ProductMode]
    panes*: set[EditingPane]

  EditingBinding* = object
    ## One row. `operation` is a name from PLAT-30's 224 and is checked against
    ## it — never an enum of this module's own, which is the whole point of
    ## there being a vocabulary.
    model*: KeymapModel
    scope*: BindingScope
    chords*: seq[string]
    operation*: string
    args*: OpArgs
    spelling*: string
      ## What a help screen shows. `chords.join(" ")` unless the row says
      ## otherwise, kept for `tui/app/input/keymap.nim`'s stated reason: the
      ## thing a user is told and the thing the resolver matches are two facts.

  EditingKeymap* = object
    bindings*: seq[EditingBinding]

  TrieNode* = object
    ## `children` maps a chord to a node index. `binding` is an index into the
    ## keymap's `bindings`, or -1.
    chord*: string
    children*: Table[string, int]
    binding*: int

  EditingTrie* = object
    nodes*: seq[TrieNode]
      ## Node 0 is the root and carries no chord.
    bindings*: seq[EditingBinding]
      ## The rows admissible in the scope this trie was built for.
    duplicates*: seq[string]
      ## Chord sequences claimed by two rows. Populated at BUILD time: the
      ## second row to reach a node that already carries a binding is the
      ## duplicate, and it is recorded rather than silently overwriting.
    prefixed*: seq[string]
      ## Chord sequences that are a proper prefix of another in the same scope.
      ## A node with a binding AND children.

  EditingResolutionKind* = enum
    ## **THE CLOSED SET OF FOUR** (§4.1), spelled as an enum so a fold over it
    ## is total and a fifth outcome cannot arrive as a special case of one of
    ## these.
    erNothing = "nothing"
    erOperation = "operation"
    erPending = "pending"
    erCharacter = "character"

  EditingResolution* = object
    kind*: EditingResolutionKind
    operation*: string
    args*: OpArgs
    character*: string
      ## What a text field should INSERT. `keyCharacter`'s answer, never the
      ## key NAME — a caller that inserted the name would type "Space".
    spelling*: string
    pending*: PendingChords
      ## The buffer AFTER this key. The resolver is pure, so the new buffer is
      ## part of the answer rather than a write to the state.
    timedOut*: bool
      ## The previous prefix expired before this key arrived. Distinct from
      ## "the prefix was abandoned", for `tui/app/input/keymap.nim`'s reason:
      ## a status line should be able to say WHY the prefix went away.

  FiledDeclaration* = object
    ## §4.4: *"Every keymap must bind every operation it claims to cover"*, and
    ## *"for the Vim and Kakoune keymaps the claim is narrower and must be
    ## stated exactly"*.
    ##
    ## This is how it is stated exactly. A model does not claim the whole
    ## vocabulary; what it does not claim is written down HERE, one row per
    ## DECLARATION with the reason, and the suite asserts
    ## `covered + filed == 224` as an equality with the two sets disjoint. So
    ## an operation that stopped having a binding is not merely uncovered — it
    ## is uncovered AND unfiled, which is a red gate rather than a silence.
    ##
    ## Per declaration rather than per operation because the forms are
    ## generated: *"Vim has no syntax motion"* is one fact about `syntax-left`
    ## and would otherwise be three identical rows.
    ##
    ## **`forms` IS NOT A CONVENIENCE AND IT CARRIES A REAL DIFFERENCE BETWEEN
    ## THE TWO MODELS.** An empty set files every generated form. A non-empty
    ## one files only those — which is what Kakoune needs, because *a motion
    ## there IS a selection*: `w` has a `select-` form and an `extend-` form
    ## and no collapsing `move-` form at all, so `move-group-right` is filed
    ## while its two siblings are bound. Without this field that fact would
    ## have to be expressed either by inventing a chord Kakoune does not have
    ## or by filing two operations that ARE reachable, and both are worse than
    ## a set.
    decl*: string
    forms*: set[OpForm]
    reason*: string

  KeymapDefinition* = object
    ## A model's bindings AND the claim they are graded against, as one value,
    ## so neither can be read without the other.
    model*: KeymapModel
    keymap*: EditingKeymap
    filed*: seq[FiledDeclaration]

  EditingKeymapErrorKind* = enum
    ekSyntax = "syntax"
    ekUnknownScope = "unknown-scope"
    ekUnknownOperation = "unknown-operation"
    ekEmptyChords = "empty-chords"
    ekBadArgument = "bad-argument"

  EditingKeymapError* = object
    ## A configuration line that could not be applied. REPORTED, with its
    ## number and its text — `.cttui-keys`'s own rule, which this format
    ## extends rather than replaces: *"a keymap that ignores what it cannot
    ## parse is a keymap that tells the user their binding works."*
    kind*: EditingKeymapErrorKind
    line*: int
    text*: string
    message*: string

  EditingKeymapLoad* = object
    keymap*: EditingKeymap
    errors*: seq[EditingKeymapError]

const
  EditingPendingTimeoutMs* = PendingTimeoutMsDefault
    ## Read from `editor_state.nim` rather than re-spelled. Vim's own
    ## `timeoutlen`, and the same value `tui/app/input/keymap.nim` uses for the
    ## debugger's prefixes — two prefixes with two timeouts would be a product
    ## that waits different lengths for `Ctrl+w` and for `g`.

  CommandBuildingOperations* = [
    ## **THE OPERATIONS THAT DO NOT COMPLETE A COMMAND**, and therefore do not
    ## clear the transient modal registers. Each one is a user part-way through
    ## typing something: a digit of a count, an operator waiting for its range,
    ## a register waiting to be used.
    ##
    ## Named as data, with its cardinality AND every member's publication
    ## asserted by `test_editor_keymap_laws.nim`, because the alternative — an
    ## `if` in `applyResolution` with three string literals in it — is a rule
    ## nothing can ask a question about.
    "push-count-digit",
    "begin-operator",
    "set-register",
  ]

  EditingKeymapErrorKindCount* = 5
    ## Asserted against the enum's span by the suite. Five kinds, five planted
    ## lines: a reason set whose members are not each demonstrated is a reason
    ## set with arms nobody has seen fire.

# ===========================================================================
# THE SCOPE
# ===========================================================================

func admits*(bs: BindingScope; scope: EditingScope): bool =
  ## Whether a binding claiming `bs` is live in `scope`. An empty set is
  ## "every value", which is what keeps the common row one row.
  (bs.modes == {} or scope.mode in bs.modes) and
    (bs.products == {} or scope.product in bs.products) and
    (bs.panes == {} or scope.pane in bs.panes)

# **`anyScope()` AND `inModes()` WERE HERE AND ARE DELETED.** They were
# convenience constructors for a `BindingScope` that nothing ever called: both
# keymaps build their rows through their own `eb` helper and the loader builds
# the object inline. `ci/test/frontend-reachability.sh` reported both in the
# `nothing` bucket — not "reached only by tests", but reached by nothing at all
# — and the right answer to that bucket is deletion rather than a raised
# ceiling. A public helper nobody calls is the shape this campaign keeps
# finding as coverage: it looks like API, it compiles, and no case can tell
# whether it works.

# ===========================================================================
# THE TRIE
# ===========================================================================

proc newTrie(): EditingTrie =
  EditingTrie(nodes: @[TrieNode(chord: "", children: initTable[string, int](),
                                binding: -1)],
              bindings: @[], duplicates: @[], prefixed: @[])

proc insert(t: var EditingTrie; index: int) =
  ## Walk the chords, creating nodes, and claim the terminal one.
  ##
  ## **THE DUPLICATE DETECTOR IS THIS FUNCTION.** A second row reaching a node
  ## that already carries a binding is recorded in `duplicates` and does NOT
  ## overwrite: a table that silently overwrote would resolve to whichever row
  ## was inserted last, which is §2.4's `move-line-up` defect one layer up.
  let b = t.bindings[index]
  var cur = 0
  for chord in b.chords:
    if not t.nodes[cur].children.hasKey(chord):
      t.nodes.add TrieNode(chord: chord, children: initTable[string, int](),
                           binding: -1)
      t.nodes[cur].children[chord] = t.nodes.len - 1
    cur = t.nodes[cur].children[chord]
  if t.nodes[cur].binding >= 0:
    let seqText = b.chords.join(" ")
    if seqText notin t.duplicates: t.duplicates.add seqText
  else:
    t.nodes[cur].binding = index

proc findPrefixConflicts(t: var EditingTrie) =
  ## A node that carries a binding AND has children: the shorter sequence can
  ## never be typed, because the resolver is still waiting for the longer one.
  for node in t.nodes:
    if node.binding >= 0 and node.children.len > 0:
      let seqText = t.bindings[node.binding].chords.join(" ")
      if seqText notin t.prefixed: t.prefixed.add seqText

proc trieFor*(km: EditingKeymap; scope: EditingScope): EditingTrie =
  ## The trie of every binding of `scope.model` admissible in `scope`.
  ##
  ## The MODEL filter is here rather than in `admits` because it is not a
  ## binding-scope dimension the way the other three are: a row belongs to
  ## exactly one model and a keymap file holds rows for several.
  result = newTrie()
  for b in km.bindings:
    if b.model != scope.model: continue
    if not b.scope.admits(scope): continue
    result.bindings.add b
    result.insert(result.bindings.len - 1)
  result.findPrefixConflicts()

func nodeAfter(t: EditingTrie; chords: seq[string]): int =
  ## The node `chords` reaches, or -1.
  var cur = 0
  for c in chords:
    if not t.nodes[cur].children.hasKey(c): return -1
    cur = t.nodes[cur].children[c]
  cur

# ===========================================================================
# CONFLICT DETECTION — §4.2's "a chord it cannot claim must land visibly"
# ===========================================================================

proc conflictsIn*(km: EditingKeymap; scope: EditingScope): (seq[string], seq[string]) =
  ## `(duplicates, prefixed)` for one scope. Two shapes, both from the trie the
  ## resolver walks, which is what makes a clean report a statement about
  ## resolution rather than about a second list.
  let t = trieFor(km, scope)
  (t.duplicates, t.prefixed)

# ===========================================================================
# THE RESOLVER — §4.1
# ===========================================================================

func nothingResolution(pending: PendingChords; timedOut: bool): EditingResolution =
  EditingResolution(kind: erNothing, operation: "", args: OpArgs(),
                    character: "", spelling: "", pending: pending,
                    timedOut: timedOut)

proc resolve*(t: EditingTrie; st: EditorState; scope: EditingScope;
              key: string; nowMs: int64): EditingResolution =
  ## **A PURE FUNCTION FROM (CHORD SEQUENCE, EDITOR STATE, SCOPE) TO A
  ## RESOLUTION.** It reads no terminal, owns no buffer and performs no effect.
  ##
  ## `key` is a CANONICAL KEY NAME — `key_names.keyName`'s answer, produced by
  ## whoever read the bytes. This module never sees a byte.
  ##
  ## `nowMs` is a parameter for `tui/app/input/keymap.resolve`'s reason: the
  ## bounded timeout is then assertable at exactly its bound and at one past it
  ## without a sleep.
  var pending = st.pending
  var timedOut = false
  if pending.chords.len > 0 and nowMs - pending.startedMs > EditingPendingTimeoutMs:
    # CHECKED BEFORE THE KEY IS INTERPRETED, so a key that arrives late is read
    # on its own terms rather than as the second half of a prefix the user has
    # long forgotten.
    pending = PendingChords(chords: @[], startedMs: 0)
    timedOut = true

  if key.len == 0:
    # Not a key at all. A pending prefix SURVIVES it: a mouse report arriving
    # between `d` and `w` is not the user changing their mind.
    return nothingResolution(pending, timedOut)

  # THE TEXT-ENTRY SHADOW (§4.3), and it is `keyCharacter` — see
  # `key_names.nim`. It applies only at the START of a sequence: once `d` is
  # pending the user is spelling a command, and a `:` prompt is not open
  # inside one.
  if scope.textEntry and pending.chords.len == 0 and isTextKey(key):
    return EditingResolution(kind: erCharacter, operation: "", args: OpArgs(),
                             character: keyCharacter(key), spelling: key,
                             pending: PendingChords(chords: @[], startedMs: 0),
                             timedOut: timedOut)

  let candidate = pending.chords & @[key]
  let node = t.nodeAfter(candidate)
  if node < 0:
    # Nothing starts with this. A prefix that was open is dropped and the key
    # is NOT re-interpreted on its own.
    return nothingResolution(PendingChords(chords: @[], startedMs: 0), timedOut)

  if t.nodes[node].children.len > 0 and t.nodes[node].binding < 0:
    return EditingResolution(
      kind: erPending, operation: "", args: OpArgs(), character: "",
      spelling: candidate.join(" "),
      pending: PendingChords(chords: candidate,
                             startedMs: if pending.chords.len == 0: nowMs
                                        else: pending.startedMs),
      timedOut: timedOut)

  if t.nodes[node].binding >= 0:
    let b = t.bindings[t.nodes[node].binding]
    return EditingResolution(
      kind: erOperation, operation: b.operation, args: b.args, character: "",
      spelling: b.spelling,
      pending: PendingChords(chords: @[], startedMs: 0), timedOut: timedOut)

  # A node with neither a binding nor children cannot exist — `insert` only
  # creates a node on the way to a terminal one — so this is unreachable and
  # is spelled as the honest outcome rather than as a default.
  nothingResolution(PendingChords(chords: @[], startedMs: 0), timedOut)

# ===========================================================================
# EXECUTION — the layer's whole effect is a sequence of PLAT-30's 224
# ===========================================================================

proc repeatFormIndex(opIndex: int): int =
  ## The operation to use for the SECOND and later applications of a counted
  ## motion.
  ##
  ## For a `select-` form it is the `extend-` form of the same DECLARATION:
  ## `5w` in operator-pending must select five groups, and `select-group-right`
  ## applied five times selects only the fifth — the `select-` form spans from
  ## the OLD position, so each application resets the anchor. `extend-` keeps
  ## the anchor and moves the head, which is exactly the continuation.
  ##
  ## Derived from the vocabulary rather than by string surgery on the name: the
  ## sibling is the row of `operations()` with the same `decl` and the wanted
  ## `form`, so a rename in §2.2 cannot make this silently wrong.
  let ops = operations()
  let op = ops[opIndex]
  if op.form != ofSelect: return opIndex
  for i, cand in ops:
    if cand.decl == op.decl and cand.form == ofExtend: return i
  opIndex

proc applyResolution*(st: EditorState; res: EditingResolution;
                      settings: WrapSettings; nowMs: int64;
                      viewportRows = 20):
                     (EditorState, seq[string]) =
  ## Execute a resolution. Returns the new state and **the sequence of named
  ## operations that produced it** — which is `DIFF-4`'s compared artefact.
  ##
  ## THE ONLY FIELD THIS FUNCTION ASSIGNS IS `pending`. Everything else is an
  ## `applyOperation` call, which is what makes the returned sequence the whole
  ## of the effect rather than a log beside it. `test_editor_keymap_laws.nim`
  ## scans this body and asserts exactly that.
  ##
  ## ## `nowMs` IS REQUIRED, AND IT IS REQUIRED BECAUSE IT WAS DEFAULTED
  ##
  ## PLAT-34's inherited residual. Until this milestone the `applyOperation`
  ## call below took `applyOperation`'s own `nowMs: int64 = 0` default, so
  ## every operation reached through the keymap layer ran at time zero — and
  ## `history.mayGroup` asks `nowMs - h.prevTime >= NewGroupDelayMs`, which at
  ## `0 - 0` is `0 >= 500`, false, *group*. **Undo grouping could therefore
  ## never break on the keymap path**: thirty keystrokes minutes apart were one
  ## undo, and no case could see it because no case supplied a clock.
  ##
  ## The parameter is positional and **has no default**, which is the fix
  ## rather than a stylistic preference: a defaulted clock is
  ## indistinguishable, at every call site, from a clock somebody passed — and
  ## that is precisely how the residual survived a milestone whose own suite
  ## drove this function six times. `M14` in `run-plat31-keymap-mutations.py`
  ## restores the defect by dropping the argument here, and the grouping case
  ## in `test_editor_front_end_differential.nim` is where it dies.
  var state = st
  state.pending = res.pending
  var performed: seq[string] = @[]

  template run(name: string; args: OpArgs) =
    let r = applyOperation(state, name, args, settings, viewportRows, nowMs)
    performed.add name
    state = r.state

  case res.kind
  of erNothing, erPending:
    discard
  of erCharacter:
    run("insert-text", OpArgs(text: res.character))
  of erOperation:
    let idx = operationNamed(res.operation)
    if idx < 0:
      # A binding naming an operation the vocabulary does not have. The
      # published contract is that `applyOperation` RAISES on an unknown name,
      # and this layer does not soften that: a keymap-private operation is a
      # red gate, not a silent no-op.
      run(res.operation, res.args)
    else:
      let times = if res.operation in CommandBuildingOperations: 1
                  else: max(1, state.count)
      run(res.operation, res.args)
      if times > 1:
        let repeat = operations()[repeatFormIndex(idx)].name
        for _ in 1 ..< times:
          run(repeat, res.args)
      if res.operation notin CommandBuildingOperations:
        # THE OPERATOR-PENDING DISCHARGE. The motion has produced a selection
        # and the operator consumes it — §2.1's whole sentence, executed.
        if state.pendingOperator.len > 0 and
           state.pendingOperator != res.operation:
          run(state.pendingOperator, OpArgs())
        # …and the transients are cleared through the PUBLISHED operation
        # rather than by assignment. See the module header.
        if state.count != 0 or state.pendingOperator.len > 0:
          run("cancel-operator", OpArgs())
  (state, performed)

type
  KeyStep* = object
    ## What ONE key did, as a value.
    ##
    ## **THE RESOLUTION KIND IS PART OF THE ANSWER AND NOT ONLY THE STATE.** A
    ## front-end has to distinguish *"this key is not the editor's"* from
    ## *"this key did nothing to this document"* — the first is handed back to
    ## the product keymap, the second is swallowed — and those two are the
    ## SAME `(state, operations)` pair: `erNothing` executes no operation and a
    ## bound motion at the end of the document executes one that moves nothing.
    ## `edit_binding.EditKeyOutcome`'s three-valued answer has depended on that
    ## distinction since PLAT-16 and derived it from a `case` over key names;
    ## it reads this field now.
    state*: EditorState
    operations*: seq[string]
    kind*: EditingResolutionKind
    timedOut*: bool

proc resolveKey*(st: EditorState; km: EditingKeymap; scope: EditingScope;
                 key: string; nowMs: int64): EditingResolution =
  ## What `key` WOULD resolve to against `st`, with no effect — the first
  ## half of `applyKey`, which calls this. PLAT-43 needed the answer without
  ## the execution: a front-end deciding whether a key belongs to the editor
  ## at all must ask the same resolver that will then run it, or the two
  ## disagree about the key the moment a model binds something the front-end's
  ## own list does not name (Vim's `Esc`, Kakoune's `Ctrl+x`).
  ##
  ## The scope's EDITING MODE is re-read from the state here rather than taken
  ## from `scope`, so a caller cannot hand a stale mode in: a chord that
  ## entered insert mode changes which trie the NEXT chord resolves through,
  ## and that is the entire reason the mode is state rather than a resolver
  ## argument.
  var sc = scope
  sc.mode = st.mode
  resolve(trieFor(km, sc), st, sc, key, nowMs)

proc applyKey*(st: EditorState; km: EditingKeymap; scope: EditingScope;
               key: string; settings: WrapSettings; nowMs: int64;
               viewportRows = 20): KeyStep =
  ## **ONE KEY: RESOLVE, THEN EXECUTE.** The whole of what this layer does to
  ## an editor, for one canonical key name.
  ##
  ## `driveKeys` is a fold of this and `editing_core.applyKey` is one call to
  ## it, which is §30b applied before the second copy exists rather than after:
  ## PLAT-34 needed the resolution KIND that `driveKeys` discards, and the
  ## available shapes were to widen `driveKeys`' return (which moves a
  ## published signature every PLAT-31 case reads) or to write the same three
  ## steps again in the core. The third shape is this one — extract the step,
  ## fold it — and it is the only one in which the rule and its two callers
  ## cannot disagree.
  ##
  ## The resolution is `resolveKey`'s — see there for the mode re-read.
  let res = resolveKey(st, km, scope, key, nowMs)
  let (next, ops) = applyResolution(st, res, settings, nowMs, viewportRows)
  KeyStep(state: next, operations: ops, kind: res.kind, timedOut: res.timedOut)

proc driveKeys*(st: EditorState; km: EditingKeymap; scope: EditingScope;
                keys: seq[string]; settings: WrapSettings;
                viewportRows = 20; nowMs: int64 = 0):
               (EditorState, seq[string]) =
  ## Resolve and execute a whole key sequence — **a fold of `applyKey`**, which
  ## is where the mode re-read and the resolution now live.
  var state = st
  var performed: seq[string] = @[]
  for key in keys:
    let step = applyKey(state, km, scope, key, settings, nowMs, viewportRows)
    state = step.state
    performed.add step.operations
  (state, performed)

# ===========================================================================
# WHAT A KEYMAP REACHES, AND WHAT IT CLAIMS TO COVER
# ===========================================================================

const
  LayerReachedOperations* = [
    ## **THE TWO OPERATIONS THE LAYER ITSELF REACHES, UNDER EVERY MODEL AND BY
    ## NO BINDING.** A reachable set computed from the binding table alone
    ## would call both of them unreachable while `applyResolution` executes
    ## them on ordinary keystrokes — and `DIFF-4` asserts that every recorded
    ## sequence is a subset of the reachable set, so that gap would be a red
    ## gate about the instrument rather than about a keymap.
    ##
    ##   * `insert-text` is the CHARACTER arm (§4.1's third outcome).
    ##   * `cancel-operator` is the transient-clearing step: a count typed
    ##     under ANY model has to be cleared when the command it belongs to
    ##     completes, and the layer does it with the published operation rather
    ##     than by assignment. That is why the Kakoune model — which has no
    ##     operator-pending state at all and binds no key to it — still reaches
    ##     it.
    "insert-text",
    "cancel-operator",
  ]

proc reachableOperations*(km: EditingKeymap; model: KeymapModel): seq[string] =
  ## Every operation name `model` can produce, ascending and distinct. The set
  ## `DIFF-4`'s sharper half compares.
  result = @[]
  for name in LayerReachedOperations: result.add name
  for b in km.bindings:
    if b.model == model and b.operation notin result:
      result.add b.operation
  result.sort()

proc filedOperations*(def: KeymapDefinition): seq[string] =
  ## The filed DECLARATIONS expanded into the operations they generate — three
  ## for a motion, two for an object, one otherwise. Expanded from
  ## `operations()` rather than by spelling the prefixes, for
  ## `repeatFormIndex`'s reason: a form rule that changed in §2.2 would
  ## otherwise leave this expansion quietly wrong.
  result = @[]
  let vocab = vocabulary()
  for f in def.filed:
    for op in operations():
      if vocab[op.decl].name != f.decl: continue
      if f.forms != {} and op.form notin f.forms: continue
      if op.name notin result: result.add op.name
  result.sort()

proc coverageGaps*(def: KeymapDefinition): seq[string] =
  ## Every published operation that is neither bound nor filed. **The number
  ## that must be zero**, and the reason §4.4's claim is checkable rather than
  ## a promise: dropping a binding moves an operation into this list.
  let reachable = reachableOperations(def.keymap, def.model)
  let filed = filedOperations(def)
  result = @[]
  for op in operations():
    if op.name notin reachable and op.name notin filed:
      result.add op.name

proc coverageOverlaps*(def: KeymapDefinition): seq[string] =
  ## Every operation that is BOTH bound and filed. The other direction, and it
  ## is the one that would otherwise let a filed row excuse a binding that
  ## exists — `covered + filed == 224` is satisfied by a covered set and a
  ## filed set that overlap and a gap of the same size.
  let reachable = reachableOperations(def.keymap, def.model)
  result = @[]
  for name in filedOperations(def):
    if name in reachable: result.add name

proc unpublishedOperations*(km: EditingKeymap; model: KeymapModel): seq[string] =
  ## Every reachable operation that is NOT one of PLAT-30's 224. **A
  ## keymap-private operation is a red gate**, and this is what makes that
  ## statement mechanical rather than a promise.
  result = @[]
  for name in reachableOperations(km, model):
    if operationNamed(name) < 0: result.add name

# ===========================================================================
# THE CONFIGURATION FORMAT — `.cttui-keys` EXTENDED, not a second file
# ===========================================================================
#
# One binding per line, exactly `.cttui-keys`'s shape with a richer mode token:
#
#     # a comment
#     vim/normal            d w  = delete-selection
#     vim/operator-pending  w    = select-group-right
#     kakoune/normal        w    = select-group-right
#     vim/normal            x    = -             # unbind
#     vim/normal            g g  = line-number(1)
#
# The mode token is `<model>/<editing-mode>`; `<model>/*` means every editing
# mode. The right-hand side is an operation NAME from §2.2 with its published
# argument in parentheses, or `-` to unbind. A second file format was refused
# for the reason the milestone gives — the loader, the reporting rule and the
# unbind spelling already exist and would have been written twice.

proc parseModelName(s: string): (bool, KeymapModel) =
  for m in KeymapModel:
    if cmpIgnoreCase($m, s) == 0: return (true, m)
  (false, kmProductDefault)

proc parseEditingModeName(s: string): (bool, EditingMode) =
  for m in EditingMode:
    if cmpIgnoreCase($m, s) == 0: return (true, m)
  (false, emNormal)

proc argsFor(decl: Declaration; raw: string): (bool, OpArgs) =
  ## Turn a configuration line's parenthesised argument into `OpArgs`, by the
  ## declaration's own `ArgKind`. The kind decides which FIELD is filled, so a
  ## line that supplied the wrong shape is an error rather than a different
  ## operation.
  var a = OpArgs()
  case decl.arg
  of akNone:
    return (raw.len == 0, a)
  of akNumber:
    try: a.number = parseInt(raw)
    except ValueError: return (false, a)
  of akDigit:
    try: a.digit = parseInt(raw)
    except ValueError: return (false, a)
    if a.digit < 0 or a.digit > 9: return (false, a)
  of akMarkId:
    if raw.len == 0: return (false, a)
    a.id = raw
  of akText:
    a.text = raw
  of akChar:
    if raw.len == 0: return (false, a)
    a.ch = raw
  of akCommand:
    if raw.len == 0: return (false, a)
    a.command = raw
  of akOperator:
    if raw.len == 0: return (false, a)
    a.operator = raw
  (true, a)

proc unbind(km: var EditingKeymap; model: KeymapModel; modes: set[EditingMode];
            chords: seq[string]) =
  var kept: seq[EditingBinding] = @[]
  for b in km.bindings:
    if b.model == model and b.chords == chords and b.scope.modes == modes:
      continue
    kept.add b
  km.bindings = kept

proc loadEditingKeymap*(base: EditingKeymap; text: string): EditingKeymapLoad =
  ## Layer a configuration over `base`.
  ##
  ## **EVERY MALFORMED LINE IS REPORTED WITH ITS NUMBER AND ITS TEXT.** Nothing
  ## is skipped silently — `.cttui-keys`'s rule, inherited rather than
  ## re-decided, and the five error kinds are each reachable from a line a user
  ## could plausibly write.
  result = EditingKeymapLoad(keymap: base, errors: @[])
  var lineNo = 0
  for rawLine in text.splitLines():
    inc lineNo
    var line = rawLine
    let hash = line.find('#')
    if hash >= 0: line = line[0 ..< hash]
    line = line.strip()
    if line.len == 0: continue

    let eq = line.find('=')
    if eq < 0:
      result.errors.add EditingKeymapError(
        kind: ekSyntax, line: lineNo, text: rawLine,
        message: "expected '<model>/<mode> <chord…> = <operation>'; no '=' on the line")
      continue
    let lhs = line[0 ..< eq].strip()
    let rhs = line[eq + 1 .. ^1].strip()
    let fields = lhs.splitWhitespace()
    if fields.len < 2:
      result.errors.add EditingKeymapError(
        kind: ekEmptyChords, line: lineNo, text: rawLine,
        message: "expected a scope and at least one chord before '='")
      continue

    let slash = fields[0].find('/')
    if slash < 0:
      result.errors.add EditingKeymapError(
        kind: ekUnknownScope, line: lineNo, text: rawLine,
        message: "the scope is '<model>/<mode>'; '" & fields[0] &
          "' names no model")
      continue
    let (modelOk, model) = parseModelName(fields[0][0 ..< slash])
    if not modelOk:
      result.errors.add EditingKeymapError(
        kind: ekUnknownScope, line: lineNo, text: rawLine,
        message: "unknown keymap model '" & fields[0][0 ..< slash] & "'")
      continue
    let modeText = fields[0][slash + 1 .. ^1]
    var modes: set[EditingMode] = {}
    if modeText != "*":
      let (modeOk, mode) = parseEditingModeName(modeText)
      if not modeOk:
        result.errors.add EditingKeymapError(
          kind: ekUnknownScope, line: lineNo, text: rawLine,
          message: "unknown editing mode '" & modeText & "'")
        continue
      modes = {mode}

    let chords = fields[1 .. ^1]
    if rhs == "-":
      unbind(result.keymap, model, modes, chords)
      continue

    var name = rhs
    var rawArg = ""
    let open = rhs.find('(')
    if open >= 0:
      if not rhs.endsWith(')'):
        result.errors.add EditingKeymapError(
          kind: ekBadArgument, line: lineNo, text: rawLine,
          message: "an argument list opens with '(' and must close with ')'")
        continue
      name = rhs[0 ..< open]
      rawArg = rhs[open + 1 ..< rhs.len - 1]

    let opIndex = operationNamed(name)
    if opIndex < 0:
      result.errors.add EditingKeymapError(
        kind: ekUnknownOperation, line: lineNo, text: rawLine,
        message: "'" & name & "' is not one of the published editing operations")
      continue
    let decl = vocabulary()[operations()[opIndex].decl]
    let (argOk, args) = argsFor(decl, rawArg)
    if not argOk:
      result.errors.add EditingKeymapError(
        kind: ekBadArgument, line: lineNo, text: rawLine,
        message: "'" & name & "' takes an argument of kind '" & $decl.arg &
          "' and '" & rawArg & "' is not one")
      continue

    unbind(result.keymap, model, modes, chords)
    result.keymap.bindings.add EditingBinding(
      model: model, scope: BindingScope(modes: modes, products: {}, panes: {}),
      chords: chords, operation: name, args: args,
      spelling: chords.join(" "))

proc describeError*(e: EditingKeymapError): string =
  "keys:" & $e.line & ": " & e.message & " — in: " & e.text.strip()
