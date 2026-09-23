## test_editor_keymap_laws.nim — PLAT-31's laws: THE RESOLVER, ITS SCOPE, ITS
## CONFLICTS, AND THE CLAIMS THIS MILESTONE MAKES ABOUT ITS OWN SOURCE.
##
## `DIFF-4` is next door in `test_editor_keymap_differential.nim`. What is here
## is everything that is a property of ONE keymap rather than of two.
##
## =========================================================================
## PLAT-31 PUBLISHES NO `LAW-*` ROW, AND THAT IS WHY THE KILLERS ARE ARMS
## =========================================================================
##
## `Editor-Model-Conformance-Suite.md` §3 carries `LAW-A*` … `LAW-X*` and none
## of them is PLAT-31's; §8's table carries `DIFF-4` and §10 carries the floor.
## So `ci/test/editor-model-case-floor.sh` runs no law-table oracle for this
## milestone — exactly as it runs none for PLAT-30 — and the "published killer
## per law" this campaign asks for is discharged by
## `run-plat31-keymap-mutations.py`, one arm per published claim, each naming
## the case that dies.
##
## =========================================================================
## FOUR OUTCOMES x FIVE DIMENSIONS IS A REACHABILITY *PROFILE*, NOT A TICK
## =========================================================================
##
## The milestone asks that *"every arm is reached in every scope"*. Read
## literally that is false and has to be: `erCharacter` is the text-entry
## shadow, so it is unreachable at `textEntry = false` BY CONSTRUCTION, and a
## suite that asserted otherwise would be asserting against the one dimension
## whose whole job is to gate it.
##
## So each of the twenty cases computes, for one outcome and one dimension, the
## SET of that dimension's values at which the outcome is reachable, and
## compares it to a declared set **with a reason attached**. That is an
## equality rather than a tick, both directions are in it, and every exception
## is visible as data instead of as a missing case. An outcome that stopped
## being reachable anywhere, and an outcome that started firing in a scope that
## is supposed to gate it, both land as a set difference.
##
## The reachability is computed from the TRIE the resolver walks — the root's
## own children, driven through `resolve` — rather than from the binding list,
## because a binding admissible in a scope whose chord the trie cannot reach is
## not a reachable outcome, and the difference between those two is the bug
## class §4.2's conflict rule exists for.
##
## =========================================================================
## THREE OF THESE CASES ASSERT A FACT ABOUT SOURCE TEXT, AND THEY SAY WHY
## =========================================================================
##
## A source scan is a weak instrument and this campaign has said so repeatedly.
## Each of the three below is here because the claim it checks is **a claim
## about the source** and is not observable in any answer:
##
##   1. `applyResolution` assigns exactly one `EditorState` field. The claim is
##      *"the keymap layer's whole effect on the editor is a sequence of the
##      224"*, and a private assignment beside the operations produces the same
##      states while making the recorded sequence a log rather than the effect.
##   2. Both goal-producing sites read a `DisplayPos.column`. This is the
##      residual PLAT-27 recorded and PLAT-30 closed; `wrap.displayGoalOf`'s
##      header now asserts it as a SOURCE fact and says so, and a header that
##      claims a check exists had better be the same commit as the check.
##   3. The differential's two arms name the two constructors. See
##      `test_editor_keymap_differential.nim` — the scan lives there, next to
##      the body it is about.

import std/[algorithm, sequtils, sets, strutils, tables, unittest]

import ../../keymap/vim_keymap
import ../../keymap/kakoune_keymap
import ../../keymap/product_keymap

# For `DisplayWrapA` alone. This suite asserts nothing about text and draws no
# documents from the corpus — that is `DIFF-4`'s job next door — but the wrap
# column an operation is executed at is a real parameter, and reading the
# generator's declared one rather than spelling a number here keeps it the
# same column every other editor suite measures at.
import ../generators/vocabulary_generator

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a static assertion count when a suite dies before printing.
const ExpectedAssertions = 19311

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  ProbeDoc = "alpha beta gamma\n  indented line\nthird (line) here\n"
    ## A document with a word, an indent and a bracket pair, so a chord that
    ## resolves has somewhere to act. The DIFFERENTIAL draws its documents from
    ## the corpus; this suite is about resolution rather than about text, and
    ## §5's eighteen documents would be eighteen copies of one answer here.

  UnboundKey = "Shift+F7"
    ## A canonical key name `keyName` can produce and **no model binds**. Used
    ## as the `erNothing` probe. Asserted unbound in every scope by
    ## `probeKeyIsUnbound`, because a probe that silently became bound would
    ## turn every `erNothing` case into a case about a different outcome.

  ExpectedErrorKinds = 5
    ## `EditingKeymapErrorKindCount`, re-derived here from the enum's span so
    ## the constant and the enum are compared rather than the constant being
    ## read twice.

let
  vim = vimKeymap()
  kak = kakouneKeymap()
  prod = productKeymap()
  settings = wrapSettings(DisplayWrapA)

proc allModels(): seq[KeymapDefinition] = @[vim, kak, prod]

proc keymapOf(m: KeymapModel): EditingKeymap =
  case m
  of kmVim: vim.keymap
  of kmKakoune: kak.keymap
  of kmProductDefault: prod.keymap

proc defOf(m: KeymapModel): KeymapDefinition =
  case m
  of kmVim: vim
  of kmKakoune: kak
  of kmProductDefault: prod

proc everyScope(): seq[EditingScope] =
  ## THE WHOLE PRODUCT: 3 models x 2 products x 2 panes x 7 editing modes x 2
  ## text-entry values = 168. Enumerated rather than sampled — the cardinality
  ## is asserted below, because a nested loop that lost a dimension is a sweep
  ## that silently halved itself.
  result = @[]
  for model in KeymapModel:
    for product in ProductMode:
      for pane in EditingPane:
        for mode in EditingMode:
          for textEntry in [false, true]:
            result.add EditingScope(model: model, product: product, pane: pane,
                                    mode: mode, textEntry: textEntry)

proc outcomesIn(scope: EditingScope): set[EditingResolutionKind] =
  ## Which of the four outcomes `resolve` can produce in this scope.
  ##
  ## Driven through `resolve` against the trie the scope builds — never read
  ## off the binding table. A binding admissible in a scope is not the same
  ## thing as an outcome the resolver can reach, and telling those two apart is
  ## what the trie is for.
  result = {}
  let t = trieFor(keymapOf(scope.model), scope)
  let st = initEditorState(ProbeDoc)
  result.incl resolve(t, st, scope, UnboundKey, 0).kind
  result.incl resolve(t, st, scope, "a", 0).kind
  for chord in t.nodes[0].children.keys:
    result.incl resolve(t, st, scope, chord, 0).kind

# ---------------------------------------------------------------------------
# THE DECLARED REACHABILITY PROFILE — twenty rows, each with its reason
# ---------------------------------------------------------------------------

type ScopeDimension = enum
  sdModel = "model"
  sdProduct = "product mode"
  sdPane = "pane"
  sdMode = "editing mode"
  sdTextEntry = "text entry"

proc valuesOf(d: ScopeDimension): seq[string] =
  case d
  of sdModel: KeymapModel.toSeq.mapIt($it)
  of sdProduct: ProductMode.toSeq.mapIt($it)
  of sdPane: EditingPane.toSeq.mapIt($it)
  of sdMode: EditingMode.toSeq.mapIt($it)
  of sdTextEntry: @["false", "true"]

proc valueIn(s: EditingScope; d: ScopeDimension): string =
  case d
  of sdModel: $s.model
  of sdProduct: $s.product
  of sdPane: $s.pane
  of sdMode: $s.mode
  of sdTextEntry: (if s.textEntry: "true" else: "false")

proc reachAt(outcome: EditingResolutionKind; d: ScopeDimension): seq[string] =
  ## The values of `d` at which `outcome` is reachable in SOME scope. Ascending
  ## and distinct, so the comparison below is an equality between two sorted
  ## lists rather than a subset test in a helpful direction.
  var seen = initHashSet[string]()
  for s in everyScope():
    if outcome in outcomesIn(s): seen.incl valueIn(s, d)
  result = seen.toSeq()
  result.sort()

proc sorted(xs: seq[string]): seq[string] =
  result = xs
  result.sort()

const
  ModesWithAPrefix = ["normal", "visual", "visual-line", "visual-block",
                      "operator-pending"]
    ## **THE FIVE EDITING MODES IN WHICH SOME MODEL HAS A MULTI-CHORD
    ## SEQUENCE**, and therefore the five in which `erPending` is reachable.
    ##
    ## `insert` and `replace` are absent and the absence is the interesting
    ## half: every insert-mode row in both models is a single chord (`Enter`,
    ## `Tab`, `Backspace`, `Delete`, `Ctrl+w`, `Ctrl+u`, `Esc`), and Vim's
    ## replace mode binds three of those and nothing else. A prefix arriving in
    ## insert mode would mean a chord that swallows a keystroke while the user
    ## is typing text, which is the defect this row would catch.

  EditorOnly = ["editor"]
    ## `erOperation` and `erPending` reach NO value of the pane dimension but
    ## this one, because every row of all three models claims
    ## `panes: {epEditor}`. **That is §4.3's second dimension doing its whole
    ## job**: a chord bound in editor scope must not fire while the call-stack
    ## pane owns the keyboard, and this is that sentence as an equality.

  TextEntryOnly = ["true"]
    ## `erCharacter` and nothing else. The shadow is the one outcome a scope
    ## dimension gates completely, which is why the profile is a set and not a
    ## tick — see the header.

  ModalModels = ["vim", "kakoune"]
    ## `erPending` reaches neither value of… no: it reaches two of the three
    ## MODELS. The product default is `TuiEditBindings` lifted, thirteen rows
    ## of ONE chord each (`product_keymap.nim`), so it has no prefix to be
    ## pending on. A pending prefix appearing under the default would mean the
    ## lift had grown a multi-chord row, and §4.4's *"the default does not
    ## move"* is exactly the claim that cannot happen silently.

suite "PLAT-31: the scope, and the population the sweep runs over":
  test "the scope is five dimensions and the sweep enumerates their whole product":
    ck everyScope().len == 168
    ck KeymapModel.toSeq.len == 3
    ck ProductMode.toSeq.len == 2
    ck EditingPane.toSeq.len == 2
    ck EditingMode.toSeq.len == 7
    # 3 * 2 * 2 * 7 * 2, spelled as the product so a dimension that changed
    # cardinality moves this line rather than being absorbed into 168.
    ck 3 * 2 * 2 * 7 * 2 == everyScope().len
    var distinctScopes = initHashSet[string]()
    for s in everyScope():
      distinctScopes.incl($s.model & "/" & $s.product & "/" & $s.pane & "/" &
                          $s.mode & "/" & $s.textEntry)
    ck distinctScopes.len == 168

  test "the `erNothing` probe key is bound by no model in any scope":
    # A PROBE THAT SILENTLY BECAME BOUND turns twenty cases into cases about a
    # different outcome, and nothing would say so. Asserted first, in its own
    # case, for the reason §25 gives about a synthesiser that drops a modifier.
    # `CSI 18 ; 2 ~` — xterm's F7 with the Shift modifier. Asserted from the
    # BYTES rather than written as a name, so the probe is a key a terminal
    # can really deliver: a probe spelled `Ctrl+i` or `Alt+w` would be a chord
    # no decoder produces, and "unbound" would then be true for the wrong
    # reason. (`CSI 1 ; 2 S` was tried first and is `Shift+F4`, which is what
    # said so.)
    ck keyName("\x1b[18;2~") == UnboundKey
    for s in everyScope():
      let t = trieFor(keymapOf(s.model), s)
      ck not t.nodes[0].children.hasKey(UnboundKey)

  test "every scope builds a trie whose root carries no chord and no binding":
    for s in everyScope():
      let t = trieFor(keymapOf(s.model), s)
      ck t.nodes[0].chord == ""
      ck t.nodes[0].binding == -1

# ---------------------------------------------------------------------------
# 4 OUTCOMES x 5 DIMENSIONS = 20
# ---------------------------------------------------------------------------

suite "PLAT-31: the resolver's four outcomes, profiled across five dimensions":
  test "outcome `nothing` x model":
    ck reachAt(erNothing, sdModel) == sorted(valuesOf(sdModel))
  test "outcome `nothing` x product mode":
    ck reachAt(erNothing, sdProduct) == sorted(valuesOf(sdProduct))
  test "outcome `nothing` x pane":
    ck reachAt(erNothing, sdPane) == sorted(valuesOf(sdPane))
  test "outcome `nothing` x editing mode":
    ck reachAt(erNothing, sdMode) == sorted(valuesOf(sdMode))
  test "outcome `nothing` x text entry":
    ck reachAt(erNothing, sdTextEntry) == sorted(valuesOf(sdTextEntry))

  test "outcome `operation` x model":
    ck reachAt(erOperation, sdModel) == sorted(valuesOf(sdModel))
  test "outcome `operation` x product mode":
    ck reachAt(erOperation, sdProduct) == sorted(valuesOf(sdProduct))
  test "outcome `operation` x pane":
    # NOT both panes — see `EditorOnly`.
    ck reachAt(erOperation, sdPane) == sorted(@EditorOnly)
  test "outcome `operation` x editing mode":
    ck reachAt(erOperation, sdMode) == sorted(valuesOf(sdMode))
  test "outcome `operation` x text entry":
    # BOTH, and that is the shadow's exact width: it takes the TEXT keys and
    # leaves `Esc`, the arrows and the control chords resolving as usual.
    ck reachAt(erOperation, sdTextEntry) == sorted(valuesOf(sdTextEntry))

  test "outcome `pending` x model":
    ck reachAt(erPending, sdModel) == sorted(@ModalModels)
  test "outcome `pending` x product mode":
    ck reachAt(erPending, sdProduct) == sorted(valuesOf(sdProduct))
  test "outcome `pending` x pane":
    ck reachAt(erPending, sdPane) == sorted(@EditorOnly)
  test "outcome `pending` x editing mode":
    ck reachAt(erPending, sdMode) == sorted(@ModesWithAPrefix)
  test "outcome `pending` x text entry":
    # BOTH — and it is one key that makes the `true` half true. Kakoune's view
    # family is prefixed with `Ctrl+v`, which is not a text key, so a prefix
    # survives the shadow. Every Vim prefix (`g`, `z`, `'`, `"`, `q`, `@`, `r`)
    # is a text key and is shadowed, so Vim alone would not reach this.
    ck reachAt(erPending, sdTextEntry) == sorted(valuesOf(sdTextEntry))

  test "outcome `character` x model":
    ck reachAt(erCharacter, sdModel) == sorted(valuesOf(sdModel))
  test "outcome `character` x product mode":
    ck reachAt(erCharacter, sdProduct) == sorted(valuesOf(sdProduct))
  test "outcome `character` x pane":
    # BOTH PANES, and this is the asymmetry worth reading: the shadow is
    # decided BEFORE the trie is consulted, so a text field in the call-stack
    # pane still receives its characters while no editing chord fires there.
    ck reachAt(erCharacter, sdPane) == sorted(valuesOf(sdPane))
  test "outcome `character` x editing mode":
    ck reachAt(erCharacter, sdMode) == sorted(valuesOf(sdMode))
  test "outcome `character` x text entry":
    ck reachAt(erCharacter, sdTextEntry) == sorted(@TextEntryOnly)

# ---------------------------------------------------------------------------
# THE TEXT-ENTRY SHADOW — 12, and `Space` is in it BY NAME
# ---------------------------------------------------------------------------

suite "PLAT-31: the text-entry shadow, and the one key it is about":
  test "`Space` — `keyCharacter` and `isPrintableKey` disagree, by name":
    # THE MILESTONE ASKS FOR THIS KEY SPECIFICALLY. A rule whose one known
    # counterexample is not in the suite is a rule tested on the cases that
    # never failed.
    ck keyCharacter("Space") == " "
    ck not isPrintableKey("Space")
    ck isTextKey("Space")

  test "`Space` is the ONLY canonical name the two predicates disagree about":
    # The claim "the difference between them is exactly one key" as an
    # equality, swept over every name `keyName` can produce from a single byte
    # and from the escape sequences it decodes.
    var disagree: seq[string] = @[]
    for b in 0 .. 255:
      let name = keyName($char(b))
      if name.len == 0: continue
      if isPrintableKey(name) != isTextKey(name): disagree.add name
    for token in ["\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D", "\x1b[Z", "\x1bOP",
                  "\x1bOQ", "\x1bOR", "\x1bOS", "\x1b[2~", "\x1b[3~",
                  "\x1b[5~", "\x1b[6~", "\x1b[15~", "\x1b[24~", "\x1b[1;5A",
                  "\x1b[1;2P"]:
      let name = keyName(token)
      if name.len == 0: continue
      if isPrintableKey(name) != isTextKey(name): disagree.add name
    ck disagree.deduplicate() == @["Space"]

  test "`keyName` answers `Space` for the byte, which is where the trap starts":
    ck keyName(" ") == "Space"
    ck keyName(" ").len == 5

  test "under text entry, `Space` resolves to the CHARACTER and not the name":
    for def in allModels():
      let s = EditingScope(model: def.model, product: pmEdit, pane: epEditor,
                           mode: emInsert, textEntry: true)
      let r = resolve(trieFor(def.keymap, s), initEditorState(ProbeDoc), s,
                      "Space", 0)
      ck r.kind == erCharacter
      # THE CHARACTER, NOT THE KEY NAME. A caller that inserted the name would
      # type "Space" into the document — the `:goto 4500` defect, one layer up.
      ck r.character == " "
      ck r.character != "Space"

  test "with text entry OFF, `Space` is not shadowed":
    for def in allModels():
      let s = EditingScope(model: def.model, product: pmEdit, pane: epEditor,
                           mode: emInsert, textEntry: false)
      let r = resolve(trieFor(def.keymap, s), initEditorState(ProbeDoc), s,
                      "Space", 0)
      ck r.kind != erCharacter

  test "a printable letter is shadowed under text entry, in every model":
    for def in allModels():
      for mode in EditingMode:
        let s = EditingScope(model: def.model, product: pmEdit, pane: epEditor,
                             mode: mode, textEntry: true)
        let r = resolve(trieFor(def.keymap, s), initEditorState(ProbeDoc), s,
                        "k", 0)
        ck r.kind == erCharacter
        ck r.character == "k"

  test "a NON-text key is not shadowed and resolves as the trie says":
    let s = EditingScope(model: kmVim, product: pmEdit, pane: epEditor,
                         mode: emInsert, textEntry: true)
    let r = resolve(trieFor(vim.keymap, s), initEditorState(ProbeDoc), s,
                    "Esc", 0)
    ck r.kind == erOperation
    ck r.operation == "enter-normal"

  test "the shadow applies only at the START of a sequence":
    # Once `g` is pending the user is spelling a command, and a `:` prompt is
    # not open inside one. Without this rule a two-chord sequence could never
    # be completed in a text field.
    let s = EditingScope(model: kmVim, product: pmEdit, pane: epEditor,
                         mode: emNormal, textEntry: true)
    var st = initEditorState(ProbeDoc)
    st.pending = PendingChords(chords: @["g"], startedMs: 0)
    let r = resolve(trieFor(vim.keymap, s), st, s, "g", 0)
    ck r.kind == erOperation
    ck r.operation == "move-doc-start"

  test "a shadowed key leaves the pending buffer empty":
    let s = EditingScope(model: kmVim, product: pmEdit, pane: epEditor,
                         mode: emNormal, textEntry: true)
    let r = resolve(trieFor(vim.keymap, s), initEditorState(ProbeDoc), s,
                    "q", 0)
    ck r.kind == erCharacter
    ck r.pending.chords.len == 0
    ck r.pending.startedMs == 0

  test "the shadow is a property of the SCOPE and not of the model":
    # All three models answer identically for the same key in the same scope,
    # because the rule is decided before the trie is consulted.
    for key in ["a", "Space", "Z", "0", "~"]:
      var kinds = initHashSet[string]()
      for def in allModels():
        let s = EditingScope(model: def.model, product: pmEdit, pane: epEditor,
                             mode: emNormal, textEntry: true)
        kinds.incl $resolve(trieFor(def.keymap, s), initEditorState(ProbeDoc),
                            s, key, 0).kind
      ck kinds.len == 1
      ck "character" in kinds

  test "executing a character resolution runs `insert-text` and nothing else":
    let s = EditingScope(model: kmVim, product: pmEdit, pane: epEditor,
                         mode: emInsert, textEntry: true)
    let st = initEditorState("ab")
    let r = resolve(trieFor(vim.keymap, s), st, s, "Space", 0)
    let (after, ops) = applyResolution(st, r, settings, 0)
    ck ops == @["insert-text"]
    ck after.doc == " ab"

  test "a key that is not a key at all leaves a pending prefix standing":
    # A mouse report arriving between `d` and `w` is not the user changing
    # their mind.
    let s = EditingScope(model: kmVim, product: pmEdit, pane: epEditor,
                         mode: emNormal, textEntry: false)
    var st = initEditorState(ProbeDoc)
    st.pending = PendingChords(chords: @["g"], startedMs: 0)
    ck keyName("\x1b[<0;1;1M") == ""
    let r = resolve(trieFor(vim.keymap, s), st, s, "", 0)
    ck r.kind == erNothing
    ck r.pending.chords == @["g"]

# ---------------------------------------------------------------------------
# THE PENDING TIMEOUT, AT ITS BOUND — 4
# ---------------------------------------------------------------------------

suite "PLAT-31: the pending prefix times out, asserted AT its bound":
  setup:
    let s = EditingScope(model: kmVim, product: pmEdit, pane: epEditor,
                         mode: emNormal, textEntry: false)
    let t = trieFor(vim.keymap, s)
    var pendingG = initEditorState(ProbeDoc)
    pendingG.pending = PendingChords(chords: @["g"], startedMs: 0)

  test "one millisecond INSIDE the bound: the prefix survives":
    let r = resolve(t, pendingG, s, "g", EditingPendingTimeoutMs - 1)
    ck not r.timedOut
    ck r.kind == erOperation
    ck r.operation == "move-doc-start"

  test "AT the bound exactly: the prefix survives":
    # The boundary itself, which is the value a `>=` would move and a `>` would
    # not. Asserted at exactly the published number rather than somewhere
    # plausible — which is why `PendingTimeoutMsDefault` is a named constant.
    let r = resolve(t, pendingG, s, "g", EditingPendingTimeoutMs)
    ck not r.timedOut
    ck r.kind == erOperation
    ck r.operation == "move-doc-start"

  test "one millisecond PAST the bound: the prefix is dropped and said so":
    let r = resolve(t, pendingG, s, "g", EditingPendingTimeoutMs + 1)
    ck r.timedOut
    # …and `g` is then read on its own terms rather than as the second half of
    # a prefix the user has long forgotten: it opens a FRESH prefix.
    ck r.kind == erPending
    ck r.pending.chords == @["g"]
    ck r.pending.startedMs == EditingPendingTimeoutMs + 1

  test "a timed-out prefix is distinct from an abandoned one":
    # Both clear the buffer; only one sets `timedOut`, so a status line can say
    # WHY the prefix went away.
    let abandoned = resolve(t, pendingG, s, UnboundKey, 0)
    ck abandoned.kind == erNothing
    ck abandoned.pending.chords.len == 0
    ck not abandoned.timedOut
    let expired = resolve(t, pendingG, s, UnboundKey,
                          EditingPendingTimeoutMs + 1)
    ck expired.kind == erNothing
    ck expired.pending.chords.len == 0
    ck expired.timedOut

# ---------------------------------------------------------------------------
# CONFLICT DETECTION ON PLANTED CONFLICTS — 2 shapes x 4 scopes = 8
# ---------------------------------------------------------------------------

const
  ConflictScopes = [
    ## Four scopes, named, each from a different model or mode, so the eight
    ## cases below are eight different tries rather than one trie eight times.
    (kmVim, emNormal), (kmVim, emOperatorPending),
    (kmKakoune, emNormal), (kmProductDefault, emInsert),
  ]

proc scopeFor(model: KeymapModel; mode: EditingMode): EditingScope =
  EditingScope(model: model, product: pmEdit, pane: epEditor, mode: mode,
               textEntry: false)

proc aTerminalChordIn(scope: EditingScope): seq[string] =
  ## A chord sequence that IS bound in this scope — read out of the trie, so
  ## the planted conflict is planted against a row that really exists. A
  ## hard-coded chord would rot into "planted against nothing", which is a
  ## detector asserted on an empty keymap.
  let t = trieFor(keymapOf(scope.model), scope)
  for chord, idx in t.nodes[0].children:
    if t.nodes[idx].binding >= 0 and t.nodes[idx].children.len == 0:
      return @[chord]
  @[]

suite "PLAT-31: conflict detection, on PLANTED conflicts, in four scopes":
  test "the clean keymaps report NOTHING, in every one of the 168 scopes":
    # THE NEGATIVE HALF, and it has to come first: a detector that finds
    # nothing passes on an empty keymap, so the planted cases below are only
    # evidence if the unplanted sweep is silent.
    for s in everyScope():
      let (dups, pref) = conflictsIn(keymapOf(s.model), s)
      ck dups.len == 0
      ck pref.len == 0

  for (model, mode) in ConflictScopes:
    let label = $model & "/" & $mode

    test "a planted DUPLICATE is named, in " & label:
      let s = scopeFor(model, mode)
      let chords = aTerminalChordIn(s)
      ck chords.len == 1
      var planted = keymapOf(model)
      planted.bindings.add EditingBinding(
        model: model, scope: BindingScope(modes: {mode}, products: {},
                                          panes: {epEditor}),
        chords: chords, operation: "undo", args: OpArgs(),
        spelling: chords.join(" "))
      let (dups, pref) = conflictsIn(planted, s)
      ck dups == @[chords.join(" ")]
      ck pref.len == 0
      # AND THE FIRST ROW STILL WINS. A table that silently overwrote would
      # resolve to whichever row was inserted last, which is §2.4's
      # `move-line-up` defect one layer up.
      let clean = trieFor(keymapOf(model), s)
      let after = trieFor(planted, s)
      let cleanOp = clean.bindings[clean.nodes[clean.nodes[0]
                      .children[chords[0]]].binding].operation
      let afterOp = after.bindings[after.nodes[after.nodes[0]
                      .children[chords[0]]].binding].operation
      ck cleanOp == afterOp

    test "a planted PREFIX is named, in " & label:
      let s = scopeFor(model, mode)
      let chords = aTerminalChordIn(s)
      ck chords.len == 1
      var planted = keymapOf(model)
      planted.bindings.add EditingBinding(
        model: model, scope: BindingScope(modes: {mode}, products: {},
                                          panes: {epEditor}),
        chords: chords & @["Ctrl+y"], operation: "redo", args: OpArgs(),
        spelling: "planted")
      let (dups, pref) = conflictsIn(planted, s)
      ck dups.len == 0
      # The SHORTER sequence is the one reported: it can never be typed,
      # because the resolver is still waiting for the longer one.
      ck pref == @[chords.join(" ")]

# ---------------------------------------------------------------------------
# THE REACHABLE SET, THE FILED SET, AND THE EQUALITY BETWEEN THEM — 6
# ---------------------------------------------------------------------------

suite "PLAT-31: what a keymap reaches and what it files, as an equality":
  test "every model: covered + filed == every operation, with the two sets DISJOINT":
    for def in allModels():
      let reach = reachableOperations(def.keymap, def.model)
      let filed = filedOperations(def)
      # Disjoint FIRST: `covered + filed == |operations|` is satisfied by two sets that
      # overlap and a gap of the same size, which is the accounting a filed row
      # could otherwise use to excuse a binding that exists.
      ck coverageOverlaps(def).len == 0
      ck reach.len + filed.len == operations().len
      ck operations().len == 226

  test "every model: the coverage GAP is empty":
    for def in allModels():
      # The number that must be zero. Dropping a binding moves an operation
      # into this list rather than quietly out of the claim.
      ck coverageGaps(def).len == 0

  test "every model: no reachable operation is keymap-PRIVATE":
    # §4.4's red gate, mechanised: every name a model can produce is one of
    # PLAT-30's 224, checked against `operationNamed` rather than against a
    # second list.
    for def in allModels():
      ck unpublishedOperations(def.keymap, def.model).len == 0

  test "the layer reaches two operations the binding tables do not always name":
    ck LayerReachedOperations.len == 2
    ck LayerReachedOperations == ["insert-text", "cancel-operator"]

    proc boundIn(def: KeymapDefinition; name: string): bool =
      for b in def.keymap.bindings:
        if b.model == def.model and b.operation == name: return true
      false

    for def in allModels():
      let reach = reachableOperations(def.keymap, def.model)
      for name in LayerReachedOperations:
        ck name in reach
      # `insert-text` IS THE CHARACTER ARM AND IS BOUND BY NOBODY. §4.1's
      # third outcome is decided by `keyCharacter` under the text-entry scope,
      # never by a row — which is exactly what makes the fourteenth row of
      # `TuiEditBindings` not a binding.
      ck not boundIn(def, "insert-text")

    # `cancel-operator` IS BOUND, BY ONE MODEL, AND THAT ASYMMETRY IS THE
    # REASON THE CONSTANT EXISTS. Vim gives it a key (`Esc` in
    # operator-pending, the user changing their mind). Kakoune has no
    # operator-pending state at all and binds no key to it — and still reaches
    # it, because a count typed under ANY model has to be cleared when the
    # command it belongs to completes, and `applyResolution` does that with the
    # published operation rather than by assignment. A reachable set computed
    # from the binding table alone would call it unreachable under Kakoune
    # while ordinary keystrokes executed it, and `DIFF-4` asserts every
    # recorded name is in that set.
    ck boundIn(vim, "cancel-operator")
    ck not boundIn(kak, "cancel-operator")
    ck not boundIn(prod, "cancel-operator")
    ck "cancel-operator" in reachableOperations(kak.keymap, kmKakoune)

  test "every filed row names a DECLARATION that exists, with a real reason":
    # A filed row against a declaration §2.2 does not publish files nothing and
    # would silently shrink the claim; an empty reason is a row that says "not
    # done yet" while looking like a decision.
    let vocab = vocabulary()
    var declNames = initHashSet[string]()
    for d in vocab: declNames.incl d.name
    for def in allModels():
      for f in def.filed:
        ck f.decl in declNames
        ck f.reason.len >= 15

  test "no filed row is a duplicate of another in the same model":
    for def in allModels():
      var seen = initHashSet[string]()
      for f in def.filed:
        let key = f.decl & "|" & $f.forms
        ck key notin seen
        seen.incl key

# ---------------------------------------------------------------------------
# THE CONFIGURATION FORMAT — five error kinds, each reachable, each reported
# ---------------------------------------------------------------------------

suite "PLAT-31: the configuration format layers over a keymap and REPORTS":
  test "the five error kinds are five, and the constant agrees with the enum":
    ck EditingKeymapErrorKindCount == ExpectedErrorKinds
    ck EditingKeymapErrorKind.toSeq.len == ExpectedErrorKinds

  test "`syntax` — a line with no `=`":
    let load = loadEditingKeymap(vim.keymap, "vim/normal d w\n")
    ck load.errors.len == 1
    ck load.errors[0].kind == ekSyntax
    # ITS NUMBER AND ITS TEXT, which is `.cttui-keys`'s own rule inherited
    # rather than re-decided: a keymap that ignores what it cannot parse is a
    # keymap that tells the user their binding works.
    ck load.errors[0].line == 1
    ck load.errors[0].text == "vim/normal d w"
    ck describeError(load.errors[0]).contains("keys:1:")

  test "`unknown-scope` — three ways, all reported":
    let load = loadEditingKeymap(vim.keymap,
      "helix/normal x = undo\nvim/wobble x = undo\nvimnormal x = undo\n")
    ck load.errors.len == 3
    for e in load.errors: ck e.kind == ekUnknownScope
    ck load.errors[0].line == 1
    ck load.errors[1].line == 2
    ck load.errors[2].line == 3

  test "`unknown-operation` — a name that is not one of the 224":
    let load = loadEditingKeymap(vim.keymap,
      "vim/normal Ctrl+y = delete-word-forward\n")
    ck load.errors.len == 1
    ck load.errors[0].kind == ekUnknownOperation
    # THE FUSED NAME §2.1 REFUSED, refused again here. A keymap cannot put it
    # back into the product through a configuration file.
    ck load.errors[0].message.contains("delete-word-forward")

  test "`empty-chords` — a scope and no chord":
    let load = loadEditingKeymap(vim.keymap, "vim/normal = undo\n")
    ck load.errors.len == 1
    ck load.errors[0].kind == ekEmptyChords

  test "`bad-argument` — the wrong shape for the declaration's own ArgKind":
    # `move-line-number` AND NOT `line-number`. §2.4: *"A declaration's NAME is
    # the token up to `(`"* — and a motion declaration generates THREE
    # operations, none of them spelled with the bare declaration name. Writing
    # `line-number(4)` here produced `unknown-operation`, correctly, which is
    # the loader refusing a name that is a declaration rather than an
    # operation; the two error kinds are genuinely different and this case is
    # about the second.
    ck operationNamed("line-number") < 0
    ck operationNamed("move-line-number") >= 0
    let load = loadEditingKeymap(vim.keymap,
      "vim/normal Ctrl+y = move-line-number(elephant)\n" &
      "vim/normal Ctrl+t = move-line-number(4\n")
    ck load.errors.len == 2
    ck load.errors[0].kind == ekBadArgument
    ck load.errors[1].kind == ekBadArgument
    # …and the well-formed spelling of the same operation is accepted, so the
    # two cases differ by the ARGUMENT and not by the name.
    let good = loadEditingKeymap(vim.keymap,
      "vim/normal Ctrl+y = move-line-number(4)\n")
    ck good.errors.len == 0

  test "a good line binds, and its operation resolves":
    let load = loadEditingKeymap(vim.keymap, "vim/normal Ctrl+y = undo\n")
    ck load.errors.len == 0
    let s = scopeFor(kmVim, emNormal)
    let r = resolve(trieFor(load.keymap, s), initEditorState(ProbeDoc), s,
                    "Ctrl+y", 0)
    ck r.kind == erOperation
    ck r.operation == "undo"

  test "`-` unbinds, and the chord then resolves to nothing":
    let load = loadEditingKeymap(vim.keymap, "vim/normal x = -\n")
    ck load.errors.len == 0
    let s = scopeFor(kmVim, emNormal)
    let before = resolve(trieFor(vim.keymap, s), initEditorState(ProbeDoc), s,
                         "x", 0)
    ck before.kind == erOperation
    ck before.operation == "delete-char-forward"
    let after = resolve(trieFor(load.keymap, s), initEditorState(ProbeDoc), s,
                        "x", 0)
    ck after.kind == erNothing

  test "a comment and a blank line are not errors, and bind nothing":
    let load = loadEditingKeymap(vim.keymap,
      "# a comment\n\n   \nvim/normal Ctrl+y = undo   # trailing\n")
    ck load.errors.len == 0
    ck load.keymap.bindings.len == vim.keymap.bindings.len + 1

  test "a malformed line does not stop the ones after it":
    # Every malformed line is reported — not the first one, and not silently
    # the whole file.
    let load = loadEditingKeymap(vim.keymap,
      "nonsense\nvim/normal Ctrl+y = undo\nalso nonsense\n")
    ck load.errors.len == 2
    ck load.errors[0].line == 1
    ck load.errors[1].line == 3
    ck load.keymap.bindings.len == vim.keymap.bindings.len + 1

  test "`<model>/*` binds in every editing mode":
    let load = loadEditingKeymap(vim.keymap, "vim/* Ctrl+y = undo\n")
    ck load.errors.len == 0
    for mode in EditingMode:
      let s = scopeFor(kmVim, mode)
      let r = resolve(trieFor(load.keymap, s), initEditorState(ProbeDoc), s,
                      "Ctrl+y", 0)
      ck r.kind == erOperation

# ---------------------------------------------------------------------------
# MODAL STATE LIVES IN THE EDITOR — §3
# ---------------------------------------------------------------------------

suite "PLAT-31: the modal state is the EDITOR's, and the resolver holds none":
  test "a count is editor state: a trie entry cannot hold one":
    # THE DELIVERABLE, AS A VALUE. `3` does not resolve to "a pending count
    # 3" — it resolves to the published `push-count-digit`, which writes
    # `EditorState.count`. A keymap-private count could not be read by a
    # status line and could not be typed INSIDE operator-pending, which is
    # what `d2j` needs.
    let s = scopeFor(kmVim, emNormal)
    var st = initEditorState(ProbeDoc)
    for digit in ["3", "7"]:
      let r = resolve(trieFor(vim.keymap, s), st, s, digit, 0)
      ck r.kind == erOperation
      ck r.operation == "push-count-digit"
      # The resolution carries no count of its own — the trie entry holds the
      # DIGIT as a published argument and the accumulation is the editor's.
      ck r.pending.chords.len == 0
      let (after, _) = applyResolution(st, r, settings, 0)
      st = after
    ck st.count == 37

  test "a count typed inside operator-pending reaches the same field":
    # `d2j`. The count is typed AFTER the operator, in a different editing
    # mode, and lands on the same `EditorState.count` — which is the placement
    # a keymap-private count cannot express.
    var st = initEditorState(ProbeDoc)
    var s = scopeFor(kmVim, emNormal)
    let (afterD, _) = applyResolution(st,
      resolve(trieFor(vim.keymap, s), st, s, "d", 0), settings, 0)
    st = afterD
    ck st.pendingOperator == "delete-selection"
    ck st.mode == emOperatorPending
    s = scopeFor(kmVim, emOperatorPending)
    let (after2, _) = applyResolution(st,
      resolve(trieFor(vim.keymap, s), st, s, "2", 0), settings, 0)
    ck after2.count == 2
    ck after2.pendingOperator == "delete-selection"

  test "a count is APPLIED to the motion, and the repeat is the `extend-` form":
    # **THIS CASE EXISTS BECAUSE A MUTATION ARM HAD NOWHERE TO DIE.** `M8` of
    # `run-plat31-keymap-mutations.py` replaces `max(1, state.count)` with `1`,
    # so `3dw` deletes one word. It was aimed at a `DIFF-4` count task and came
    # back **MISDIRECTED**: the count is applied in `applyResolution`, which
    # BOTH keymaps share, so the mutation degrades both arms identically, the
    # two end documents still agree, and the differential is structurally
    # incapable of seeing it. It died only in `assertion count` — which is a
    # tally noticing that fewer operations ran, not a case noticing that the
    # product is wrong.
    #
    # That is the §30 trap the milestone names, arriving from the direction it
    # was not expected from: not "the two arms are one implementation" but "the
    # DEFECT is in the shared layer, below where the two arms diverge". A
    # differential can only see what differs between its sides. Everything
    # below that point needs a law, and this is it.
    let vimScope = scopeFor(kmVim, emNormal)
    let st = initEditorState(ProbeDoc)
    let (one, oneOps) = driveKeys(st, vim.keymap, vimScope, @["d", "w"],
                                  settings)
    let (three, threeOps) = driveKeys(st, vim.keymap, vimScope,
                                      @["3", "d", "w"], settings)
    # THE DOCUMENT, FIRST: a count that is read and ignored leaves these two
    # equal, and that is the whole defect.
    ck one.doc.len < st.doc.len
    ck three.doc.len < one.doc.len
    ck three.doc != one.doc

    # THE SEQUENCE, SECOND, and it carries the sharper claim: the SECOND and
    # later applications use the `extend-` form of the same declaration. A
    # `select-` form applied three times spans from the OLD position each time
    # and selects only the third group; `extend-` keeps the anchor and moves
    # the head, which is what makes `3dw` three groups rather than the third.
    ck threeOps.count("extend-group-right") == 2
    ck threeOps.count("select-group-right") == 1
    ck oneOps.count("extend-group-right") == 0
    # …and the transients are cleared afterwards, through the published
    # operation, so the count does not leak into the next command.
    ck three.count == 0
    ck three.pendingOperator.len == 0

    # THE SAME CLAIM UNDER KAKOUNE, because the count lives in the editor and
    # the shared layer applies it — so a law that held for one model and not
    # the other would mean the count had become keymap state after all.
    let kakScope = scopeFor(kmKakoune, emNormal)
    let (kOne, _) = driveKeys(st, kak.keymap, kakScope, @["w", "d"], settings)
    let (kThree, kThreeOps) = driveKeys(st, kak.keymap, kakScope,
                                        @["3", "w", "d"], settings)
    ck kThree.doc.len < kOne.doc.len
    ck kThreeOps.count("extend-group-right") == 2
    # The two models reach the same document by two paths — which is `DIFF-4`'s
    # claim, asserted here too because this case is about the layer BELOW the
    # place those two paths diverge.
    ck kThree.doc == three.doc

  test "the pending-chord buffer is a field of the EDITOR, and the resolver is pure":
    # The resolver returns the NEXT buffer rather than writing one, which is
    # what makes it a function of `(trie, state, scope, key, now)`. Called
    # twice with the same arguments it answers the same thing — and the state
    # it was given is unchanged.
    let s = scopeFor(kmVim, emNormal)
    let st = initEditorState(ProbeDoc)
    let t = trieFor(vim.keymap, s)
    let a = resolve(t, st, s, "g", 100)
    let b = resolve(t, st, s, "g", 100)
    ck a.kind == b.kind
    ck a.pending.chords == b.pending.chords
    ck a.pending.chords == @["g"]
    ck st.pending.chords.len == 0

  test "`applyResolution` is what puts the buffer back on the state":
    let s = scopeFor(kmVim, emNormal)
    let st = initEditorState(ProbeDoc)
    let r = resolve(trieFor(vim.keymap, s), st, s, "g", 100)
    let (after, ops) = applyResolution(st, r, settings, 100)
    ck after.pending.chords == @["g"]
    ck after.pending.startedMs == 100
    # A PENDING PREFIX PERFORMS NO OPERATION. The user is part-way through
    # typing a command and the document must not have moved.
    ck ops.len == 0
    ck after.doc == st.doc

  test "the mode is re-read from the state after every key":
    # A chord that entered insert mode changes which trie the NEXT chord
    # resolves through, which is the entire reason the mode is state rather
    # than a resolver argument.
    let s = scopeFor(kmVim, emNormal)
    let st = initEditorState("abc\ndef\n")
    # `k` alone, from normal mode, is a motion.
    let (moved, movedOps) = driveKeys(st, vim.keymap, s, @["k"], settings)
    ck movedOps == @["move-line-up"]
    ck moved.mode == emNormal
    # The SAME key, after `i`, is not — the second trie is a different trie,
    # chosen by a field the first key wrote.
    let (after, ops) = driveKeys(st, vim.keymap, s, @["i", "k"], settings)
    ck ops == @["enter-insert"]
    ck after.mode == emInsert
    # `Esc` then `k` moves again: the mode went back and so did the trie.
    let (back, backOps) = driveKeys(st, vim.keymap, s,
                                    @["i", "Esc", "k"], settings)
    ck backOps == @["enter-insert", "enter-normal", "move-line-up"]
    ck back.mode == emNormal

# ---------------------------------------------------------------------------
# THE SOURCE FACTS — three claims that are not visible in any answer
# ---------------------------------------------------------------------------

const
  KeymapSource = staticRead("../../keymap/editing_keymap.nim")
  OperationsSource = staticRead("../../editor/operations.nim")
  WrapSource = staticRead("../../editor/wrap.nim")
  TuiKeymapSource = staticRead("../../../tui/app/input/keymap.nim")

proc bodyBetween(src, opening, closing: string): string =
  let a = src.find(opening)
  if a < 0: return ""
  let b = src.find(closing, a + opening.len)
  if b < 0: return src[a .. ^1]
  src[a ..< b]

suite "PLAT-31: three claims about the source, checked because no answer shows them":
  test "`applyResolution` assigns exactly ONE EditorState field, and it is `pending`":
    # THE CLAIM: *"the keymap layer's whole effect on the editor is a sequence
    # of the 224"*. A private assignment beside the operations produces the
    # same states while making the recorded sequence a LOG rather than the
    # effect — and `DIFF-4` compares that sequence, so the claim has to be
    # true of the source and not only of the answers.
    let body = bodyBetween(KeymapSource, "proc applyResolution*",
                           "proc driveKeys*")
    ck body.len > 0
    var assigned: seq[string] = @[]
    for line in body.splitLines():
      let text = line.strip()
      if text.startsWith("##") or text.startsWith("#"): continue
      if not text.startsWith("state."): continue
      let eq = text.find('=')
      if eq < 0: continue
      # **AN `=` IS NOT AN ASSIGNMENT UNTIL THE COMPARISONS ARE EXCLUDED**, and
      # this scan claimed a second assigned field until they were: the
      # operator-pending discharge reads `state.pendingOperator != res.operation`
      # and the scan reported `pendingOperator !`. A needle that cannot tell a
      # comparison from a write is a needle that reports the code it is
      # policing as already broken, which is the failure mode that gets a check
      # widened instead of fixed.
      if eq + 1 < text.len and text[eq + 1] == '=': continue
      if eq > 0 and text[eq - 1] in {'!', '<', '>', '+', '-', '*', '/'}: continue
      let field = text[len("state.") ..< eq].strip()
      if field.len > 0 and field notin assigned: assigned.add field
    ck assigned == @["pending"]
    # AND THE BODY IS NOT EMPTY OF WRITES EITHER — a scan that matched nothing
    # satisfies every check written over what it read (§4).
    ck body.contains("state.pending = res.pending")
    ck body.count("run(") >= 4

  test "both goal-producing sites read a `DisplayPos.column`":
    # PLAT-27 RECORDED A RESIDUAL HERE AND PLAT-30 CLOSED IT;
    # `wrap.displayGoalOf`'s header says this check exists, and a header that
    # claims a check had better be the same commit as the check. The residual
    # existed only if the two motion families carried goal columns in two
    # units. They do not, and that is a fact about two call sites.
    let vertical = bodyBetween(OperationsSource, "proc verticalLogical",
                               "proc mLineUp")
    ck vertical.len > 0
    ck vertical.contains("cache.toDisplay(")
    ck vertical.contains("here.column")
    let goalOf = bodyBetween(WrapSource, "func displayGoalOf",
                             "proc initDisplayCtx*")
    ck goalOf.len > 0
    ck goalOf.contains("at: DisplayPos")
    ck goalOf.contains("at.column")
    # …and the two read the SAME field of the SAME type, which is the half
    # that makes the pair an equality rather than two observations that agree
    # today. `here` in `verticalLogical` is what `cache.toDisplay` returns —
    # a `DisplayPos` — and `at` in `displayGoalOf` is declared one.
    ck vertical.contains("let goal = if r.goalColumn.isSome: r.goalColumn.get else: here.column")
    ck goalOf.contains("if r.goalColumn.isSome: r.goalColumn.get else: at.column")

  test "the text-entry predicate is ONE function with two callers (§30a)":
    # The milestone asks the editing keymap to reuse `keymap.nim`'s existing
    # `keyCharacter` spelling. There were two ways to obey that sentence and
    # only one of them is checkable: MOVE the rule into one module both
    # keymaps call. A second spelling is what this asserts cannot exist.
    ck not KeymapSource.contains("proc keyCharacter")
    ck not KeymapSource.contains("proc isPrintableKey")
    ck not TuiKeymapSource.contains("proc keyCharacter")
    ck not TuiKeymapSource.contains("proc isPrintableKey")
    ck KeymapSource.contains("import ../../../common/key_names")
    ck TuiKeymapSource.contains("import ../../../../common/key_names")
    # And the shared function is the SAME object both sides call: one import,
    # one answer, so the debugger keymap's arms and the editing keymap's arms
    # are evidence about each other rather than two opinions from one mistake.
    ck keyCharacter("Space") == " "

  test "no module of the keymap package appears in the editing core's source":
    # The import-closure gate (`ci/test/editor-import-closure.sh`) is the
    # mechanical half and runs in its own lane, where it can spawn a process.
    # This is the half that runs on all three backends: the DEPENDENCY RUNS
    # ONE WAY, and the editing core names no keymap module.
    for src in [OperationsSource, WrapSource]:
      ck not src.contains("keymap/editing_keymap")
      ck not src.contains("keymap/vim_keymap")
      ck not src.contains("keymap/kakoune_keymap")
      ck not src.contains("keymap/product_keymap")
    # …and the other direction is true, which is what makes the first a
    # DIRECTION rather than two modules that happen not to speak.
    ck KeymapSource.contains("import ../editor/operations")

suite "PLAT-31: the trie is the structure resolution walks":
  test "a duplicate is detected by the INSERT, not by a second sweep":
    # The detector and the resolver read one structure, so a conflict the
    # detector cannot see is a conflict resolution cannot hit. Asserted by
    # planting a duplicate and reading it off the TRIE rather than off
    # `conflictsIn`, which is the wrapper.
    let s = scopeFor(kmVim, emNormal)
    var planted = vim.keymap
    planted.bindings.add EditingBinding(
      model: kmVim, scope: BindingScope(modes: {emNormal}, products: {},
                                        panes: {epEditor}),
      chords: @["x"], operation: "undo", args: OpArgs(), spelling: "x")
    let t = trieFor(planted, s)
    ck t.duplicates == @["x"]
    ck t.prefixed.len == 0

  test "every node but the root carries a chord, and every leaf carries a binding":
    # A node with neither a binding nor children cannot exist — `insert` only
    # creates a node on the way to a terminal one — which is what makes
    # `resolve`'s last line unreachable rather than a default.
    for s in everyScope():
      let t = trieFor(keymapOf(s.model), s)
      for i in 1 ..< t.nodes.len:
        ck t.nodes[i].chord.len > 0
        ck t.nodes[i].binding >= 0 or t.nodes[i].children.len > 0

  test "one trie per scope, built from the rows admissible in it":
    # The conflict rule is *"no chord bound twice IN A SCOPE"*, so the detector
    # is run per scope and has nothing to assume. A row scoped to visual mode
    # is absent from the normal-mode trie entirely.
    let normal = trieFor(vim.keymap, scopeFor(kmVim, emNormal))
    let visual = trieFor(vim.keymap, scopeFor(kmVim, emVisual))
    ck normal.bindings.len != visual.bindings.len
    for b in normal.bindings:
      ck b.model == kmVim
      ck b.scope.admits(scopeFor(kmVim, emNormal))

  test "every generated family's cardinality, asserted where the table claims it is":
    # **FOUR HEADERS IN THE KEYMAP PACKAGE SAY "ITS CARDINALITY IS ASSERTED",
    # AND UNTIL THIS CASE EXISTED THAT WAS FALSE OF THREE OF THEM.** Found by
    # reading the new modules' own claims back against the suite rather than by
    # anything failing — which is the audit this campaign keeps having to do,
    # and the reason a claim about a check should name the check.
    #
    # Each of these families is GENERATED by a loop, so losing half its members
    # is a silent event: the rows that remain still resolve, the trie still
    # reports no conflict, and `covered + filed == |operations|` is unmoved because the
    # operation is still reached by the survivors.

    # `r<c>` — the printable ASCII a replace can substitute. Both models spell
    # the same alphabet and the two constants are compared to each other as
    # well as to their length, because two copies of one list is the shape that
    # drifts.
    #
    # **THE NUMBER IS DERIVED, NOT WRITTEN.** It is the whole printable ASCII
    # range, `' '` … `'~'` — which is 95 and not the 94 this case first
    # asserted from memory. Comparing against the RANGE rather than against a
    # remembered count is the difference between a cardinality assertion and a
    # second thing to be wrong about; the set equality below would also catch a
    # list that had the right length and the wrong members.
    var printableAscii = ""
    for b in int(' ') .. int('~'):
      printableAscii.add char(b)
    ck printableAscii.len == 95
    ck vim_keymap.ReplaceCharKeys.len == printableAscii.len
    ck kakoune_keymap.ReplaceCharKeys.len == printableAscii.len
    ck vim_keymap.ReplaceCharKeys == kakoune_keymap.ReplaceCharKeys
    for ch in printableAscii:
      ck ch in vim_keymap.ReplaceCharKeys
    # …and every member really is a key a text field would accept, so the
    # length is a statement about the alphabet and not about a string.
    for ch in vim_keymap.ReplaceCharKeys:
      ck isPrintableKey($ch)

    # The four register/mark families are generated over this, and "every
    # letter is bound" is a property of the loop rather than of the eye.
    ck vim_keymap.RegisterLetters.len == 26
    ck kakoune_keymap.RegisterLetters.len == 26

    # Kakoune's nine motions with no collapsing form — the claim *"exactly
    # nine"* its header says a case can assert.
    ck NoCollapsingForm.len == 9
    for decl in NoCollapsingForm:
      # …and each really is filed for the `move-` FORM only, which is what
      # `FiledDeclaration.forms` exists for: the `select-` and `extend-` forms
      # of the same declaration ARE bound.
      ck "move-" & decl notin reachableOperations(kak.keymap, kmKakoune)
      ck "select-" & decl in reachableOperations(kak.keymap, kmKakoune)

    # The operations that do not COMPLETE a command, and so do not clear the
    # transient modal registers.
    ck CommandBuildingOperations.len == 3
    for name in CommandBuildingOperations:
      ck operationNamed(name) >= 0

    # Vim's two linewise shorthand lists partition the six operator keys.
    ck LinewiseAroundOperatorKeys.len == 2
    ck LinewiseInnerOperatorKeys.len == 4
    for key in LinewiseAroundOperatorKeys:
      ck key notin LinewiseInnerOperatorKeys

  test "the product default lifts thirteen rows and the fourteenth is the character arm":
    # `TuiEditBindings`'s last row has the empty key and names `insert-text` —
    # `applyEditKey`'s `else` arm. In the resolver that is not a binding at
    # all: it is §4.1's CHARACTER outcome. A fourteenth BINDING would mean the
    # `else` arm had been turned into a key.
    ck prod.keymap.bindings.len == 13
    ck TuiEditBindings.len == 14
    for b in prod.keymap.bindings:
      ck b.chords.len == 1
      ck b.chords[0] != DefaultEditKey
      ck b.operation != "insert-text"
    ck "insert-text" in reachableOperations(prod.keymap, kmProductDefault)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
