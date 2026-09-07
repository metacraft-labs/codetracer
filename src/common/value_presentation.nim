## value_presentation.nim (src/common) — the facade `common_types` imports.
##
## ## WHY A FACADE, AND WHY THERE ARE TWO OF THEM
##
## `common_types.nim` is `include`d by BOTH `src/common/types.nim` and
## `src/frontend/types.nim`, and an unqualified `import` inside included code
## resolves against the INCLUDER's directory first. That is not an accident to
## work around — it is the mechanism the module already relies on:
## `task_and_event` exists at `src/common/task_and_event.nim` AND at
## `src/frontend/task_and_event.nim`, and `common_types.nim`'s single
## `import task_and_event` picks the right one per binding.
##
## A relative import (`import ./value_presentation/vocabulary`) cannot work
## here for exactly that reason: it would resolve to `src/frontend/
## value_presentation/` when `src/frontend/types.nim` is the includer, and no
## such directory exists.
##
## So the same pair-of-stubs shape is used: this file and
## `src/frontend/value_presentation.nim` both re-export the ONE implementation
## under `src/common/value_presentation/`. Unlike `task_and_event`, the two
## stubs are not two implementations — they are two names for one, which is why
## `ci/test/value-presentation-boundary.sh` checks that the frontend stub
## contains nothing but the re-export.

import value_presentation/[vocabulary, value_model, presenter, surfaces]
export vocabulary, value_model, presenter, surfaces
