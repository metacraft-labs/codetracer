## frontend/view_vocabulary/fact_reader.nim — PLAT-21. **ONE reader, and it has
## TWO consumers of THREE bindings.**
##
## ## Why this module exists rather than a third copy of the walk
##
## PLAT-3 shipped two bindings. Each renders a `ViewNode` tree onto its own
## medium and each projects the RENDERED artefact back down to `StateFact`
## triples, and the projection is what the cross-medium suite compares. The
## terminal's projection reads isonim-tui's widget objects and is necessarily
## its own code; the web's reads `data-*` attributes off the rendered elements
## by walking `firstChild` / `nextSibling`.
##
## PLAT-21 adds a third binding whose rendered artefact is *also* an
## attribute-carrying element tree — isonim-gpui's, held on the Rust side of an
## FFI boundary. Writing a second attribute walk for it is
## Verification-Harness-Traps §14 in its exact shape: *two copies of one
## predicate, and it is the copy nobody mutates that stays wrong*. So the walk
## is here, once, generic over isonim's `RendererBackend` shape, and both
## attribute-medium bindings call it.
##
## **TWO of the three, not three**, and the count is in the title because it is
## the whole of what makes the three-way comparison in
## `test_cross_renderer_panes.nim` more than a pair: the TERMINAL binding does
## not come through here at all.
##
## ## WHAT THE SHARING COSTS, SAID HERE RATHER THAN DISCOVERED LATER
##
## §14's remedy has a price PLAT-20 measured on `distributeExtent`: two arms of
## an agreement test that divide through one function agree about a change to
## that function, so the agreement cannot see it. The same is true here — a
## defect in this walk moves the web projection and the GPUI projection
## identically, and a suite that only compared those two would stay green.
##
## Three things keep that from being a hole:
##
##   * **The terminal projection does NOT come through here.** It reads
##     isonim-tui's widget fields, so the three-way comparison still has one
##     arm this module cannot move.
##   * **The field names come from `vocabulary.nodeFacts`**, which is the
##     vocabulary's own list. A field this reader forgot is a field the
##     vocabulary never declared.
##   * **A mutation arm is aimed at this function** and is graded against the
##     cross-renderer suite, so "the shared reader can go red" is a measured
##     property rather than an argument.
##
## ## WHAT IT DELIBERATELY DOES NOT READ
##
## It never looks at the `ViewNode` the tree was rendered from. A projection
## that read the model would be comparing the model with itself and would pass
## on a binding that rendered nothing (Verification-Harness-Traps §4a).

import ../../common/view_vocabulary

const
  ViewKindAttribute* = "data-view-kind"
    ## The attribute carrying `vocabulary.vocabularyName(kind)`.
  ViewIdAttribute* = "data-view-id"
    ## The attribute carrying `ViewNode.id`.
  FactAttributePrefix* = "data-"
    ## Every observable field is stamped as `data-<field>` with the field name
    ## `vocabulary.nodeFacts` uses. Named once, here, so a writer and this
    ## reader cannot disagree about the spelling.

proc factAttributeName*(field: string): string =
  ## The attribute one `StateFact` field is carried in. **The ONE spelling**,
  ## called by every writer and by the reader below.
  FactAttributePrefix & field

proc readAttributeFacts*[R, N](r: R; root: N): seq[StateFact] =
  ## Project an attribute-carrying element tree down to `StateFact`s.
  ##
  ## `R` must offer `getAttribute(node, name) -> string`, `firstChild` and
  ## `nextSibling`; `N` must be nil-able. isonim's `MockRenderer` and
  ## `WebRenderer` satisfy that directly; isonim-gpui's `GpuiRenderer` does
  ## once `gpui_binding` supplies the receiver-taking `getAttribute` overload
  ## its free-function form is missing.
  proc visit(r: R; el: N; acc: var seq[StateFact]) =
    if not el.isNil:
      let id = r.getAttribute(el, ViewIdAttribute)
      if id.len > 0:
        let kindName = r.getAttribute(el, ViewKindAttribute)
        for k in ViewKind:
          if vocabularyName(k) == kindName:
            for f in nodeFacts(ViewNode(kind: k)):
              acc.add fact(id, f.field,
                           r.getAttribute(el, factAttributeName(f.field)))
            break
      var child = r.firstChild(el)
      while not child.isNil:
        visit(r, child, acc)
        child = r.nextSibling(child)
  visit(r, root, result)
