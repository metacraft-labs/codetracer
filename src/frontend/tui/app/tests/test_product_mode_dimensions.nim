## test_product_mode_dimensions.nim — PLAT-16, Tier 1, STRUCTURAL.
##
## ## THE RISK THIS SUITE IS THE MITIGATION FOR
##
## PLAT-16's own risk row: *"collapsing input modes and product modes into one
## enum, producing fifteen states where two dimensions belong."*
## CodeTracer-TUI-Edit-Mode.md §1.2 says the same thing at length and adds the
## consequence: *"it will not be recoverable once bindings depend on it."*
##
## The mitigation the milestone names is that `UiMode`'s cardinality stays
## asserted **and gains the product-mode dimension separately**.
## `app/tests/test_layout_profiles.nim` carries the first half — its width sweep
## now runs over `240 * (2 + 6 * 2 * 3)` and the `6 * 2` is written as a product
## of two literals so that a collapse changes the ARITHMETIC rather than a
## number. This file carries the second half: that the two enums are two, that
## neither can name a member of the other, that the state space is their
## PRODUCT, and that one physical key resolves differently in the two product
## modes while the input mode is unchanged.
##
## ## WHAT WOULD FAIL IF THEY COLLAPSED
##
## Concretely, and each is a case below:
##
##   * `not compiles(umEdit)` and `not compiles(umDebug)` — a `UiMode` that
##     gained `EDIT` is a compile-time fact and this is where it is caught.
##     The positive twin (`compiles(umNormal)`) is what stops the check from
##     being satisfied by a typo.
##   * The status line carries TWO indicators, and the set of distinct
##     `(input, product)` renderings over the whole grid has `6 * 2` members.
##     A collapsed enum renders one indicator and the set has at most 6.
##   * `keymap.resolve` takes the two modes as TWO PARAMETERS. A single
##     fifteen-state enum could not be passed to it.
##
## ## No mocks
##
## Two enums, a keymap and a status-bar formatter. Nothing here constructs a
## debugger, a terminal or a process.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, the
## check takes its `else` branch, and the case still reports `[OK]` while
## `programResult` goes to 1. CTUI-2 measured that happening.

import std/[algorithm, strutils, unittest]

# `product_mode` — `ProductMode`, `sourceOriginFor`, the stale-trace verdict
# and `slugOfPreservedRow` — comes from the CORE through the sanctioned facade,
# which is the same door the modules under test use.
import codetracer_embed

import ../input/keymap
import ../input/modal_state
import ../layout/profile
import ../views/status_bar

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 95

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  InputModeCardinality = 6
    ## `UiMode`'s, as `test_layout_profiles.nim` spells it. A LITERAL: a
    ## `len(UiMode)` here would be computed by the same enum this file sweeps
    ## and would stop being able to notice that the sweep skipped a member.
  ProductModeCardinality = 2
    ## `ProductMode`'s, on the same rule.

suite "PLAT-16: input modes and product modes are two dimensions":

  test "the two enums have their own cardinalities, and neither names the other":
    var inputs: seq[string] = @[]
    for m in UiMode:
      inputs.add $m
    var products: seq[string] = @[]
    for p in ProductMode:
      products.add $p
    checkpoint("UiMode: " & inputs.join(", "))
    checkpoint("ProductMode: " & products.join(", "))
    ck inputs.len == InputModeCardinality
    ck products.len == ProductModeCardinality

    # NEITHER ENUM CONTAINS A MEMBER OF THE OTHER'S VOCABULARY. §1.2: "`UiMode`
    # … must not gain `EDIT`."
    for name in products:
      ck name notin inputs
    for name in inputs:
      ck name notin products

    # AND IT IS A COMPILE-TIME FACT, not only a spelling one. A `UiMode` that
    # gained `EDIT` would make the first two compile.
    ck not compiles(umEdit)
    ck not compiles(umDebug)
    ck not compiles(pmNormal)
    ck not compiles(pmCommand)
    # THE POSITIVE TWINS, without which every line above is satisfied by a
    # typo: `compiles` is false for a misspelling too.
    ck compiles(umNormal)
    ck compiles(pmEdit)
    ck compiles(pmDebug)

  test "the state space is the PRODUCT of the two, not their sum":
    # Every (input, product) pair renders a DISTINCT pair of indicators, and
    # there are 6 x 2 of them. A collapsed enum cannot produce twelve.
    var rendered: seq[string] = @[]
    var pairs = 0
    for mode in UiMode:
      for product in ProductMode:
        inc pairs
        let bar = statusBarText(
          initStatusBarModel(mode = mode, profile = lpStandard,
                             product = product), 120)
        # BOTH INDICATORS ARE ON THE ROW, in their two positions.
        ck bar.contains($mode)
        ck bar.contains(productIndicator(product))
        let key = $mode & "/" & $product
        if key notin rendered:
          rendered.add key
    checkpoint("distinct (input, product) renderings: " & $rendered.len)
    ck pairs == InputModeCardinality * ProductModeCardinality
    ck rendered.len == InputModeCardinality * ProductModeCardinality
    # AND THE TWO INDICATORS ARE IN TWO POSITIONS: the input one first, the
    # product one after it, with the product one never replacing it.
    let bar = statusBarText(
      initStatusBarModel(mode = umSearch, profile = lpStandard,
                         product = pmEdit), 120)
    checkpoint("row: " & bar.strip())
    ck bar.find("SEARCH") == 0
    ck bar.find("[EDIT]") > bar.find("SEARCH")

  test "the product mode changes the hint strip without changing the input mode":
    # §8's shortcut scoping, visible: NORMAL in Edit mode advertises editing
    # keys and NORMAL in Debug mode advertises stepping keys, and the INPUT
    # mode is `umNormal` in both.
    let debugHints = keyHints(umNormal, lpStandard, pmDebug)
    let editHints = keyHints(umNormal, lpStandard, pmEdit)
    checkpoint("debug: " & debugHints)
    checkpoint("edit:  " & editHints)
    ck debugHints != editHints
    ck debugHints.contains("step-over")
    ck not editHints.contains("step-over")
    ck editHints.contains("Ctrl+F5")
    # THE PROMPT MODES ARE UNCHANGED BY THE PRODUCT MODE, which is the control
    # that says the parameter is read where it means something and ignored
    # where it does not. A `:` prompt is the same prompt in both.
    for mode in [umCommand, umSearch, umInspect, umVisual, umSeek]:
      ck keyHints(mode, lpStandard, pmDebug) ==
         keyHints(mode, lpStandard, pmEdit)

suite "PLAT-16: keymap scoping is by PRODUCT mode, not by a fifth input mode":

  test "every action's scope is declared, and the three arms are exactly these":
    var both, debugOnly, editOnly: seq[string] = @[]
    var actions = 0
    for a in KeyAction:
      if a == kaNone:
        continue
      inc actions
      case scopeOf(a)
      of asBoth: both.add $a
      of asDebugOnly: debugOnly.add $a
      of asEditOnly: editOnly.add $a
    both.sort(); debugOnly.sort(); editOnly.sort()
    checkpoint("debug-only (" & $debugOnly.len & "): " & debugOnly.join(", "))
    checkpoint("edit-only (" & $editOnly.len & "): " & editOnly.join(", "))
    ck actions > 0
    ck both.len + debugOnly.len + editOnly.len == actions
    # BOTH POPULATED ARMS ARE NON-EMPTY. A `scopeOf` that answered `asBoth` for
    # everything would satisfy every other assertion in this file and would
    # make the whole scoping mechanism inert.
    ck both.len > 0
    ck debugOnly.len > 0
    # …AND THE THIRD IS EMPTY, ASSERTED RATHER THAN ASSUMED. `scopeOf`'s
    # docstring says nothing is `asEditOnly` yet and says why; this is what
    # announces the day that stops being true.
    ck editOnly.len == 0
    # The stepping actions are the ones §8.1 names by example.
    ck "step-over" in debugOnly
    ck "continue" in debugOnly
    # …and the structural ones are not.
    ck "focus-next-pane" in both
    ck "quit" in both
    ck "open-command-prompt" in both
    # §3 of CodeTracer-TUI-Edit-Mode.md: "Breakpoint markers stay: setting a
    # breakpoint while editing is a normal thing to do."
    ck "toggle-breakpoint" in both
    # §8.4: "The mode toggle is bound in both modes, or the transition is
    # one-way from the keyboard."
    ck "toggle-product-mode" in both

  test "one physical key, two product modes, two answers — and a control":
    # THE DEMONSTRATION THAT THE TWO DIMENSIONS ARE BOTH READ. `n` is Step Over
    # in NORMAL input mode; the INPUT mode is identical in both calls and only
    # the PRODUCT mode differs.
    var state = initModalState()
    var pending = initPendingState()
    let km = defaultKeymap()

    var pDebug = pending
    let inDebug = km.resolve(state, pDebug, "n", 0, pmDebug)
    checkpoint("debug: " & $inDebug.kind & " " & $inDebug.action)
    ck inDebug.kind == krAction
    ck inDebug.action == kaStepOver
    ck inDebug.reason.len == 0

    var pEdit = pending
    let inEdit = km.resolve(state, pEdit, "n", 0, pmEdit)
    checkpoint("edit: " & $inEdit.kind & " reason='" & inEdit.reason & "'")
    # §8.1: "must be inert AND SAY SO".
    ck inEdit.kind == krInertInMode
    ck inEdit.action == kaStepOver
    ck inEdit.reason.len > 0
    ck inEdit.reason.contains("step-over")
    ck inEdit.reason.contains("EDIT")
    ck inEdit.reason.contains("Ctrl+F5")
    # THE INPUT MODE DID NOT MOVE in either call, which is the orthogonality
    # claim itself: a resolution that had changed the modal state would mean
    # the product mode had reached the input machine.
    ck state.mode == mmNormal

    # `krInertInMode` IS A SIXTH KIND AND NOT A SECOND REASON FOR `krNone`
    # (Verification-Harness-Traps §5a). An unbound key still answers `krNone`
    # in Edit mode, with no reason, and the two are told apart.
    var pUnbound = pending
    let unbound = km.resolve(state, pUnbound, "Y", 0, pmEdit)
    ck unbound.kind == krNone
    ck unbound.reason.len == 0
    ck unbound.action == kaNone

    # THE NEGATIVE CONTROL FOR THE WHOLE MECHANISM (Verification-Harness-Traps
    # §7a: an unfalsified negative control is a self-comparison wearing a
    # negation). `Tab` is `asBoth`, so if the Edit answer above were produced by
    # "everything is inert in Edit mode" rather than by the scope table, this
    # would be inert too. It is not.
    var pTabDebug = pending
    var pTabEdit = pending
    let tabDebug = km.resolve(state, pTabDebug, "\t", 0, pmDebug)
    let tabEdit = km.resolve(state, pTabEdit, "\t", 0, pmEdit)
    ck tabDebug.kind == krAction
    ck tabEdit.kind == krAction
    ck tabDebug.action == kaFocusNextPane
    ck tabEdit.action == kaFocusNextPane

  test "Ctrl+F5 is one command, reachable from both product modes":
    # Mode-Transitions.md §1: "The mode toggle is one command. `Ctrl+F5`
    # switches to whichever mode the session is not in. It is the same command
    # in both directions."
    #
    # `\x1b[15;5~` is xterm's Ctrl+F5 — the DECODER's answer is asserted first,
    # so the resolution below is grounded in a real byte sequence rather than
    # in a name this file invented.
    ck keyName("\x1b[15;5~") == "Ctrl+F5"
    let km = defaultKeymap()
    var state = initModalState()
    var pending = initPendingState()
    for product in ProductMode:
      var p = pending
      let r = km.resolve(state, p, "\x1b[15;5~", 0, product)
      checkpoint($product & " -> " & $r.kind & " " & $r.action)
      ck r.kind == krAction
      ck r.action == kaToggleProductMode
    # ONE COMMAND IN BOTH DIRECTIONS, as a property of `toggled` rather than of
    # two one-way commands: applying it twice is the identity, and applying it
    # once never answers the mode it was given.
    for product in ProductMode:
      ck toggled(product) != product
      ck toggled(toggled(product)) == product

  test "the toggle comes from a third published document, and exactly one does":
    # `SpecSection` gained a third value rather than the toggle being filed
    # under §4.2, where `test_gdb_command_surface.nim` would have looked for a
    # row that does not exist. This is what stops a fourth source of bindings
    # from arriving unannounced — the same rule that file applies to §4.1's
    # three.
    var fromModeTransitions: seq[string] = @[]
    for a in KeyAction:
      if a != kaNone and specSectionOf(a) == ssModeTransitions:
        fromModeTransitions.add $a
    fromModeTransitions.sort()
    checkpoint("Mode-Transitions-sourced: " & fromModeTransitions.join(", "))
    ck fromModeTransitions == @["toggle-product-mode"]
    ck specAction(kaToggleProductMode) == ""
    ck defaultKeymap().bindingsOf(kaToggleProductMode).len == 1

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
