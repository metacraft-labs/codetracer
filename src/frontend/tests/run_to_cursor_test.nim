## run_to_cursor_test.nim
##
## *Run to Cursor* is `ct/source-line-jump` with `behaviour = ForwardJump`.
## This suite pins the one thing that silently turns it back into "Jump to
## line": THE NUMBER THAT CROSSES THE WIRE.
##
## WHY A NUMBER AND NOT A NAME. `SourceLineJumpTarget` reaches the backend as
## `value.toJs` (`frontend/middleware.nim:307` → `dapApi.sendCtRequest`), and
## Nim's JS backend represents an enum as its ORDINAL. So `behaviour` arrives
## at `task::SourceLocation` as `0`, `1` or `2`, and the Rust side decodes it
## with `Serialize_repr`/`Deserialize_repr` against discriminants written out
## by hand. Nothing in either compiler relates the two.
##
## Reordering `JumpBehaviour` in
## `src/common/common_types/debugger_features/jumps.nim` — inserting a variant,
## alphabetising it — would keep both languages compiling, keep every existing
## suite green, and make Run to Cursor jump backwards. That is a silent
## wrong-direction move, which is the exact failure the backend's
## `SourceLocation` doc block calls out. The paired assertion lives in
## `src/db-backend/src/dap_handler.rs`
## (`the_wire_form_of_jump_behaviour_is_the_nim_ordinal`), which decodes these
## same three integers.
##
## THE COMMAND ITSELF IS NOT ASSERTED HERE, because it cannot be: the two
## surfaces that raise it — the `CTRL+F10` entry in `ui/editor.nim`'s Monaco
## `commands` table and the "Run to Cursor" context-menu item — live in a
## module `nim js` cannot build outside the Karax/Monaco tree. What the
## direction MEANS once it arrives is asserted where it is decided, in
## `dap_handler.rs`'s `run_to_cursor_*` cases, against the step actually landed
## on.
##
## Lane: `frontend-js` (`ci/lib/test-lane-files.sh`, `just test-frontend-js`).

import std/[unittest, jsffi]
# Through `frontend/types`, not straight at
# `common_types/debugger_features/jumps.nim`: that file is `include`d into
# `common_types.nim` and leans on `langstring`, which `task_and_event.nim`
# defines per backend. Importing it alone fails with `undeclared identifier:
# 'langstring'`. `../types` is also the module the editor sees these types
# through, so this reaches them by the product's own route.
import ../types

proc wireBehaviour(behaviour: JumpBehaviour): int =
  ## The value the backend actually receives, obtained the way it is actually
  ## produced — by building the target the editor builds and converting it the
  ## way `middleware.nim` converts it. Reading `ord(behaviour)` instead would
  ## assert the enum against itself and would not notice `toJs` changing shape.
  let target = SourceLineJumpTarget(
    path: cstring"/test/workdir/main.nr",
    line: 5,
    behaviour: behaviour)
  cast[int](target.toJs["behaviour"])

suite "Run to Cursor crosses the wire as a forward jump":

  test "the three behaviours serialise as the ordinals Rust decodes":
    let smart = wireBehaviour(SmartJump)
    let forward = wireBehaviour(ForwardJump)
    let backward = wireBehaviour(BackwardJump)

    echo "wire behaviour — SmartJump: ", smart,
      ", ForwardJump: ", forward,
      ", BackwardJump: ", backward
    # `task::JumpBehaviour` in `src/db-backend/src/task.rs` declares
    # `Smart = 0`, `Forward = 1`, `Backward = 2`. These three lines are the
    # other half of that declaration.
    check smart == 0
    check forward == 1
    check backward == 2

  test "Run to Cursor is not the same request as Jump to line":
    # Non-vacuity. If `toJs` ever dropped the field, or the enum collapsed,
    # every check above could still pass by all three being the same number —
    # and Run to Cursor would be Jump to line again, which is the state this
    # work found the product in.
    let smart = wireBehaviour(SmartJump)
    let forward = wireBehaviour(ForwardJump)
    let backward = wireBehaviour(BackwardJump)

    echo "distinct wire values: ", @[smart, forward, backward]
    check smart != forward
    check forward != backward
    check smart != backward

  test "the field is present, not merely absent-and-defaulted":
    # `SourceLocation` deserialises a MISSING `behaviour` as `Smart`
    # (`#[serde(default)]`), so a target that omitted the key would look
    # correct for Smart and silently disarm Forward. Assert the key exists.
    let target = SourceLineJumpTarget(
      path: cstring"/test/workdir/main.nr",
      line: 5,
      behaviour: ForwardJump)
    let hasKey = not target.toJs["behaviour"].isUndefined

    echo "behaviour key present on the emitted target: ", hasKey
    check hasKey
