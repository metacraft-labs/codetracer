## value_presentation.nim (src/frontend) — the JS-binding name for the ONE
## value-presentation package.
##
## Nothing but a re-export. See `src/common/value_presentation.nim`'s header for
## why the name has to exist in both directories; `ci/test/
## value-presentation-boundary.sh` asserts this file declares no routine of its
## own, so it cannot quietly become a second implementation.

import ../common/value_presentation/[vocabulary, value_model, presenter, surfaces]
export vocabulary, value_model, presenter, surfaces
