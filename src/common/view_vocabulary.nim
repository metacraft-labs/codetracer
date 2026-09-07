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

import ./view_vocabulary/vocabulary
import ./view_vocabulary/behaviour
import ./view_vocabulary/portability
import ./view_vocabulary/mappings
import ./view_vocabulary/admission

export vocabulary, behaviour, portability, mappings, admission
