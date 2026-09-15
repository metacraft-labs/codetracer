## view_vocabulary/gpui_gaps.nim — PLAT-21's verification gate, as data.
##
## ## THE GATE
##
## PLAT-21: *"The count of vocabulary entries needing a GPUI-specific escape is
## **zero**, or each is a named, filed vocabulary defect. Silent escapes are how
## a shared vocabulary becomes three vocabularies."*
##
## A gate phrased as a count needs two things to be checkable rather than
## arguable: a DEFINITION of "escape" that a machine can apply, and a REGISTER
## of what has been filed. Both are here, and `frontend/view_vocabulary/
## gpui_binding.nim` reports the escapes it actually took **at render time**, so
## the census is taken from a run rather than read off this file.
##
## ## WHAT COUNTS AS A GPUI-SPECIFIC ESCAPE
##
## > A vocabulary entry needs a **GPUI-specific escape** when rendering it
## > correctly forces the GPUI binding into a code path keyed on *the renderer*
## > rather than on *the entry* — something neither the terminal binding nor the
## > web binding has to do for the same entry.
##
## Three things this deliberately does NOT count, each because counting them
## would make the gate say something other than what it means:
##
##   * **A tag collapsing to `div`.** Eleven entries do that, and it is the
##     ordinary condition of a renderer with a small element vocabulary. The
##     binding supplies the semantics for `Button` on GPUI exactly as it
##     supplies them for `Menu` on the terminal, where isonim-tui has no menu
##     widget. That is a *mapping status*, and `mappings.gpuiMapping` is where
##     it is recorded.
##   * **A composition.** The terminal `Menu` is an `OptionListWidget` inside a
##     `ModalWidget`; nobody calls that an escape. A GPUI `Table` built out of
##     nested containers is the same act.
##   * **A drawing the vocabulary never asked for.** `ProgressIndicator`'s whole
##     specified state is a number in 0..100 or `ProgressIndeterminate`. A
##     surface that carries the number has rendered everything the entry
##     specifies; *how wide the bar is* is geometry, and
##     `vocabulary.nim`'s second structural consequence says the vocabulary does
##     not have geometry. An entry cannot be short of a thing it does not
##     specify.
##
## ## SUBJECT: THE VOCABULARY, OR THE RENDERER
##
## The gate's word is "vocabulary defect", and PLAT-21's goal is *"a vocabulary
## validated on two front-ends may have encoded one of them"*. So a filed gap
## has to say which of the two is at fault, because a renderer bug filed as a
## vocabulary defect would send the next reader to edit the wrong file, and a
## vocabulary defect filed as a renderer bug is how the vocabulary stops being
## looked at. `gsVocabulary` means *the vocabulary assumed something only the
## terminal or the DOM provides*; `gsRenderer` means *the vocabulary is right
## and isonim-gpui cannot carry it yet*.

import std/strutils

import ./vocabulary

type
  GapSubject* = enum
    gsVocabulary
      ## The vocabulary encoded an assumption a third medium does not meet.
    gsRenderer
      ## isonim-gpui cannot carry what the vocabulary specifies. The entry is
      ## fine; the renderer is short.

  GpuiGap* = object
    ## One filed gap. Every field is required and every one is checked by
    ## `src/common/view_vocabulary_test.nim`, because a register whose rows may
    ## be blank is a register that can be satisfied by an empty row.
    id*: string
      ## Stable, greppable, campaign-namespaced: `PLAT21-VG<n>`.
    entries*: seq[ViewKind]
      ## The vocabulary entries this gap is about. **Non-empty**: the gate
      ## counts ENTRIES, so a gap naming none would satisfy it for free
      ## (Verification-Harness-Traps §4).
    subject*: GapSubject
    what*: string
      ## What the binding cannot do.
    measured*: string
      ## THE MEASUREMENT, with the command or the observed value in it. A gap
      ## argued rather than measured is the header-comment shape §7a is about.
    remedy*: string
      ## What would close it, and in which repository.

const
  FiledGpuiGaps*: seq[GpuiGap] = @[
    GpuiGap(
      id: "PLAT21-VG1",
      entries: @[pkButton, pkCheckbox, pkToggle, pkInput, pkSelect, pkList,
                 pkTree, pkTable, pkTabs, pkCollapsible, pkModal, pkMenu],
      subject: gsRenderer,
      what: "A KEY CANNOT BE DELIVERED TO A VIEW. isonim-gpui's " &
            "`addEventListener(node, event, handler)` takes a `proc()` with " &
            "NO PARAMETER, and `gpui_dispatch_event(node, event)` carries no " &
            "payload either, so there is no `KeyboardEvent` and no way to " &
            "say WHICH key was pressed. Every interactive entry — all twelve " &
            "— has a keyboard contract the vocabulary requires " &
            "(`acKeyboard` is not optional, and `portability.checkPortable` " &
            "refuses a pointer-only entry), and none of them can receive one " &
            "through the renderer's own event surface.",
      measured: "`rust/gpui-nim-shim/src/lib.rs` `gpui_add_event_listener_id` " &
                "takes (node, event, callback_id) and stores " &
                "`EventListener { callback, callback_id }`; the Nim side's " &
                "`globalDispatcher(callbackId: int32)` looks the closure up " &
                "and calls it with no argument. Measured on 2026-09-15 by " &
                "firing three events at one element: the two with listeners " &
                "ran, the third did not, and neither handler could tell " &
                "which key it was.",
      remedy: "isonim-gpui: widen the callback ABI to carry an event payload " &
              "(a key name at minimum). Until then the binding encodes the " &
              "key IN THE EVENT NAME — `vockey:ArrowDown` — which is the " &
              "escape this gap files."),
    GpuiGap(
      id: "PLAT21-VG2",
      entries: @[pkButton, pkCheckbox, pkToggle, pkInput, pkSelect, pkList,
                 pkTree, pkTable, pkTabs, pkCollapsible, pkModal, pkMenu],
      subject: gsRenderer,
      what: "THE `disabled` ATTRIBUTE IS DESTROYED ON THE WAY IN AND " &
            "UNREADABLE ON THE WAY OUT. `renderer.mapAttributeName` rewrites " &
            "`disabled` to `enabled`, and `mapAttributeValue` answers the " &
            "LITERAL `\"false\"` for it whatever the caller passed — so " &
            "`setAttribute(el, \"disabled\", \"false\")` records the element " &
            "as disabled. `getAttribute(el, \"disabled\")` then answers \"\", " &
            "because the stored key is `enabled`.",
      measured: "2026-09-15, through the real shim: after " &
                "setAttribute(disabled,\"true\") -> disabled='' enabled='false'; " &
                "after setAttribute(disabled,\"false\") -> enabled='false', " &
                "UNCHANGED. `disabled` is observable state on `Button` " &
                "(`nodeFacts` emits it) and on every `ViewOption`.",
      remedy: "isonim-gpui: `mapAttributeValue` should invert the value " &
              "rather than constant-fold it. Until then the binding never " &
              "writes the name `disabled` and carries the fact as " &
              "`data-disabled`, which is the escape this gap files — and " &
              "which the WEB binding does not need, because the DOM keeps " &
              "what it is given."),
    GpuiGap(
      id: "PLAT21-VG3",
      entries: @[pkModal],
      subject: gsRenderer,
      what: "THERE IS NO ELEMENT FOCUS, SO EXCLUSIVITY CANNOT BE EXPRESSED. " &
            "`Modal`'s specified behaviour is *a region that takes exclusive " &
            "input until dismissed*, and the vocabulary's own note says the " &
            "exclusivity is the medium-independent part — a terminal focus " &
            "trap and an inert DOM background are two spellings of one " &
            "statement about where input goes. isonim-gpui has focus at the " &
            "WINDOW level only (`window.onFocus`, per window id); no element " &
            "can hold, trap or refuse focus, and the render plan carries no " &
            "layer, no z-order and no modality.",
      measured: "2026-09-15: `grep -n focus` over " &
                "`rust/gpui-nim-shim/src/tree.rs` and `render_sync.rs` " &
                "returns NOTHING; every hit in `src/isonim_gpui/window.nim` " &
                "is the per-window `onFocus` callback. The render plan's " &
                "node shape is (kind, tag, text, has_click_handler, " &
                "has_input_handler, event_names, styles, children) and none " &
                "of those is a layer.",
      remedy: "isonim-gpui: an element-level focus/trap concept, or gpui-kit's " &
              "own overlay once it is reachable (PLAT-20 premise 1). Until " &
              "then the binding renders the Modal's exclusivity as PRESENCE " &
              "— the body is in the tree when open and absent when dismissed " &
              "— which is what the entry's `open` fact already carries and is " &
              "strictly less than the entry specifies."),
    GpuiGap(
      id: "PLAT21-VG4",
      entries: @[pkImage],
      subject: gsVocabulary,
      what: "`Image` CARRIES NO PAYLOAD, SO NO RENDERER CAN DRAW IT — and " &
            "GPUI is the first front-end for which that is the whole of the " &
            "entry. `ViewNode` has `mediaType`, `mediaBytes` and `alt` and no " &
            "bytes; the terminal's binding renders `alt` and says so, the " &
            "web's emits `<img alt=…>` with no `src`, and isonim-gpui has a " &
            "real `Img` element kind (one of exactly two tags that reach a " &
            "dedicated kind) which the binding therefore has nothing to put " &
            "in. This is filed against the VOCABULARY rather than the " &
            "renderer: the entry is specified so that the two media that " &
            "could not draw it are satisfied, and the medium that can is not.",
      measured: "2026-09-15: `img` is one of two tags whose render-plan kind " &
                "is not `Div` — `img -> kind=Img`, `svg -> kind=Svg`, " &
                "everything else is `Div` or `TextContainer`. " &
                "`vocabulary.ViewNode` has no field a binding could read " &
                "bytes out of; `viewImage(id, mediaType, alt, mediaBytes)` " &
                "takes a SIZE.",
      remedy: "PLAT-14 widened the terminal's media capability without " &
              "widening the entry, and `Budget.media` already carries what a " &
              "SURFACE can draw. The entry needs the payload (or a handle to " &
              "one) beside the type, and the decision belongs with whichever " &
              "milestone gives a front-end real pixels to hand over.")]
    ## **THE FILED GAPS, AND THE COUNT IS PART OF THE CONTRACT.**
    ##
    ## Four. `view_vocabulary_test.nim` asserts the length, asserts every field
    ## non-empty, asserts every `entries` list non-empty and every id unique,
    ## and — the assertion that makes this a gate rather than a document —
    ## asserts that the set of entries the GPUI binding REPORTED taking an
    ## escape for, on a run, is exactly the set named here.

func gapsFor*(k: ViewKind): seq[GpuiGap] =
  ## Every filed gap naming this entry. **The one predicate**: the census in
  ## the suite and the report below both ask through it rather than each
  ## filtering the list themselves (Verification-Harness-Traps §14).
  for g in FiledGpuiGaps:
    if k in g.entries: result.add g

func entriesWithFiledGap*(): seq[ViewKind] =
  ## Every entry named by at least one filed gap, in `ViewKind` order.
  for k in ViewKind:
    if gapsFor(k).len > 0: result.add k

func gapById*(id: string): GpuiGap =
  for g in FiledGpuiGaps:
    if g.id == id: return g
  GpuiGap()

func describeGaps*(): string =
  ## The register, as a report. The form PLAT-21's status block quotes.
  var lines: seq[string] = @[]
  for g in FiledGpuiGaps:
    var names: seq[string] = @[]
    for k in g.entries: names.add vocabularyName(k)
    lines.add g.id & "  [" & (case g.subject
                              of gsVocabulary: "vocabulary"
                              of gsRenderer: "renderer") & "]  " &
      $g.entries.len & " entr" & (if g.entries.len == 1: "y" else: "ies")
    for n in names: lines.add "    " & n
    lines.add "    what:     " & g.what
    lines.add "    measured: " & g.measured
    lines.add "    remedy:   " & g.remedy
  lines.join("\n")
