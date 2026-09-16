## view_vocabulary.nim — PLAT-3's package facade.
##
## `import view_vocabulary` gives a caller the whole vocabulary: the sixteen
## entries, the state each carries, the keyboard contract each answers, the
## portability check, the admission test and the three front-end mappings.
##
## THE BINDINGS ARE NOT HERE, deliberately. `src/frontend/view_vocabulary/`
## holds `terminal_binding.nim` (isonim-tui) and `web_binding.nim` (the DOM
## through isonim's `ui()` DSL), and neither is re-exported: this package is
## pure, imports nothing outside `std` and `common/value_presentation`, and is
## therefore compilable in a workspace where `isonim-tui` — an ADVISORY
## sibling, per `scripts/require-siblings.sh` — is not checked out. A facade
## that pulled a binding in would put a renderer on the dependency path of
## every consumer of the vocabulary, which is the arrangement the vocabulary
## exists to remove.
##
## See `view_vocabulary/vocabulary.nim` for the specification of each of the
## sixteen entries by behaviour and state.
##
## **PLAT-21 added `view_vocabulary/gpui_gaps.nim`** — the register of gaps the
## third front-end's binding measured, which is PLAT-21's verification gate
## expressed as data rather than as a paragraph. It is in this facade rather
## than beside the binding for the same reason the mapping table is: a gap is a
## statement about an ENTRY, and a reader asking "what does this entry cost on
## GPUI" should not have to link a renderer to find out.
##
## **PLAT-22 added `view_vocabulary/editor_rows.nim`**, and a reader should
## notice that it is the one module here that is NOT about the sixteen entries.
## PLAT-3's admission test refused `Editor`, so a source editor is a native view
## per medium — and three native views still have to agree on what a ROW is, or
## the execution pointer means one thing in the terminal and another on the GPU.
## It is in this package because it is pure and medium-free by exactly the same
## standard as the rest (std only, no renderer, compiles with no `isonim-tui`
## checkout), and it is a SEPARATE module because it is deliberately outside the
## closed set: nothing in it is a `ViewKind`, and `checkPortable` never sees it.

import ./view_vocabulary/vocabulary
import ./view_vocabulary/behaviour
import ./view_vocabulary/portability
import ./view_vocabulary/mappings
import ./view_vocabulary/admission
import ./view_vocabulary/gpui_gaps
import ./view_vocabulary/editor_rows

export vocabulary, behaviour, portability, mappings, admission, gpui_gaps
export editor_rows
