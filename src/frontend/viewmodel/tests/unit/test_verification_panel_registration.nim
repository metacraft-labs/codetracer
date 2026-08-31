## test_verification_panel_registration.nim
##
## VN-M5. The two ordinal hazards the verification panel's wiring walks past,
## pinned.
##
## Both were guarded by comments and by the compiler's arity check, and neither
## was checked. The reason recorded for that was wrong and is corrected here:
## `common/common_types` does not import on the C backend — its own header says
## "should not be imported directly, use `common/types` or `frontend/types`
## instead", and `common/types` imports fine on both backends. The check had a
## home the whole time.
##
## ## What is actually at risk
##
## **`Content` ordinals are persisted.** A GoldenLayout config written by a
## previous run stores the ordinal, not the name (`renderer.saveConfig` /
## `layout.nim`). Insert a member anywhere but the end and every ordinal after
## it shifts, so a saved layout re-opens a *different panel* than the one the
## developer left there — silently, because both ordinals are valid.
##
## **`ClientAction` ordinals index a positional array.** `ui_js.nim`'s `actions`
## is `array[ClientAction, ClientActionHandler]`, built as a bare literal in
## enum order. Nim's arity check catches a *missing* handler; it cannot catch a
## *shifted* one, so inserting a member in the middle re-points every handler
## after it to the wrong action while the build stays green. The `Content` enum
## carries three separate comments saying "appended at the end on purpose" for
## this reason; this file is what makes them true rather than hoped.
##
## So the assertion is on the **literal ordinal**, not on `== high`. Pinning
## `== high` would go red on a perfectly legal append; pinning the literal goes
## red exactly when something is inserted *before* it, which is the hazard.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_verification_panel_registration.nim
##
## Discovered by the `vm-unit` (C) and `vm-unit-js` (JS) lanes by glob.

import std/unittest

import ../../../../common/types

suite "VN-M5 the verification panel's registration is where it says it is":

  test "Content.Verification keeps the ordinal a persisted layout names":
    # 47, and it must stay 47. A layout saved by a build where this was 47 and
    # restored by one where it is 48 opens whatever now holds 47.
    check ord(Content.Verification) == 47

  test "Content stays contiguous, which is what array[Content, ...] needs":
    # `Components.componentMapping` and `Components.openComponentIds` are
    # `array[Content, ...]`. A hole makes that array indexable at an ordinal no
    # member has. The retired members (`RetiredDeepReviewPanel`,
    # `FrameViewer`) exist *only* to keep this true, and their own comments say
    # so — this is the check those comments are asking for.
    var count = 0
    for content in Content:
      inc count
    check ord(Content.low) == 0
    check count == ord(Content.high) + 1

  test "aVerification keeps the ordinal ui_js.nim's positional array assumes":
    # 183. `actions` in `ui_js.nim` is `array[ClientAction, ClientActionHandler]`
    # written as a literal in enum order, so ordinal N must be the handler for
    # member N. Nim checks the *count*; nothing checks the *pairing*, and an
    # insertion in the middle silently re-points every handler after it.
    check ord(aVerification) == 183

  test "ClientAction stays contiguous for the same reason":
    var count = 0
    for action in ClientAction:
      inc count
    check ord(ClientAction.low) == 0
    check count == ord(ClientAction.high) + 1

  test "the two panels VN-M5 touches are distinct content kinds":
    # A positive control on the scan above: these checks are all about ordinals
    # being stable, and every one of them would pass over an enum that had
    # collapsed to a single member. This asserts the enum still distinguishes
    # the things the wiring distinguishes.
    check ord(Content.Verification) != ord(Content.EditorView)
    check ord(Content.Verification) != ord(Content.UnifiedDiff)
    check ord(Content.UnifiedDiff) == 46
    # And that there is no `Content.Counterexample`: the counterexample is a
    # region of the verification panel, not a panel of its own, because a panel
    # of its own would be openable when there is nothing to open. Spelled as a
    # name check because an enum member cannot be asserted absent by ordinal.
    var names: seq[string] = @[]
    for content in Content:
      names.add $content
    check names.len == ord(Content.high) + 1     # positive control
    check "Verification" in names
    check "Counterexample" notin names
