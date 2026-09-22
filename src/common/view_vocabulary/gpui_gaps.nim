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

type
  RetiredGpuiGap* = object
    ## **A gap whose divergence has been REPAIRED.**
    ##
    ## PLAT-35's rule, inherited by PLAT-38: *"a filed gap is retired when its
    ## divergence is repaired"*. A repaired gap left in `FiledGpuiGaps` would
    ## make the census demand an escape the binding no longer takes, so the
    ## gate reddens either way — but a gap that simply VANISHED would leave no
    ## record that the claim was ever true, and the next reader would have to
    ## rediscover why the binding is shaped the way it is.
    ##
    ## **AND A RETIREMENT MUST NOT FIRE ON A RUN IN WHICH NOTHING HAPPENED.**
    ## `PLAT35-VG7` was retired against the one run in six where the GPUI
    ## locals never arrived: two empty answers compared equal, the question
    ## agreed, and the retirement case then demanded the gap go. So every row
    ## here names the POSITIVE EVIDENCE its retirement is conditioned on, and
    ## the suite asserts that evidence ARRIVED before it asserts the gap is
    ## absent from the register.
    id*: string
    entries*: seq[ViewKind]
      ## The entries the gap named while it was filed. Kept so the shrink can
      ## be asserted as an identity — `filed ∪ retired` is the original
      ## register, in both directions.
    subject*: GapSubject
    what*: string
      ## What the binding could not do. Past tense, verbatim from the filing.
    repairedIn*: string
      ## Where the repair landed, precisely enough to read.
    evidence*: string
      ## **THE POSITIVE OBSERVATION THE RETIREMENT REQUIRES**, named so the
      ## suite can demand it rather than infer it from an absence.

const
  RetiredGpuiGaps*: seq[RetiredGpuiGap] = @[
    RetiredGpuiGap(
      id: "PLAT21-VG1",
      entries: @[pkButton, pkCheckbox, pkToggle, pkInput, pkSelect, pkList,
                 pkTree, pkTable, pkTabs, pkCollapsible, pkModal, pkMenu],
      subject: gsRenderer,
      what: "A KEY COULD NOT BE DELIVERED TO A VIEW. isonim-gpui's " &
            "`addEventListener(node, event, handler)` took a `proc()` with " &
            "NO PARAMETER, and `gpui_dispatch_event(node, event)` carried no " &
            "payload either, so there was no keyboard event and no way to " &
            "say WHICH key was pressed. Every interactive entry — all twelve " &
            "— has a keyboard contract the vocabulary requires " &
            "(`acKeyboard` is not optional, and `portability.checkPortable` " &
            "refuses a pointer-only entry), and none of them could receive " &
            "one through the renderer's own event surface. The binding " &
            "encoded the key in the EVENT NAME (`vockey:Down`).",
      repairedIn: "isonim-gpui, PLAT-38. `EventCallback` is " &
                  "`extern \"C\" fn(*const GpuiEventPayload)` and " &
                  "`EventDispatcher` is " &
                  "`extern \"C\" fn(i32, *const GpuiEventPayload)`; " &
                  "`gpui_dispatch_event_with` carries a payload and answers " &
                  "how many listeners it reached; " &
                  "`rust/gpui-nim-shim/src/input.rs` records every delivery " &
                  "in the node's own element store BEFORE any callback runs. " &
                  "`gpui_app.rs` attaches a real `on_key_down` to a " &
                  "tracked-focus root, so a compositor key reaches the same " &
                  "routine.",
      evidence: "A key was DELIVERED and read back from the Rust-side " &
                "element store: the key name, the modifier set and a " &
                "non-zero delivery sequence, for every one of the twelve " &
                "interactive entries. Not the value the case sent — the " &
                "value `gpui_last_event_*` answers."),
    RetiredGpuiGap(
      id: "PLAT21-VG2",
      entries: @[pkButton, pkCheckbox, pkToggle, pkInput, pkSelect, pkList,
                 pkTree, pkTable, pkTabs, pkCollapsible, pkModal, pkMenu],
      subject: gsRenderer,
      what: "THE `disabled` ATTRIBUTE WAS DESTROYED ON THE WAY IN AND " &
            "UNREADABLE ON THE WAY OUT. `renderer.mapAttributeName` rewrote " &
            "`disabled` to `enabled`, and `mapAttributeValue` answered the " &
            "LITERAL `\"false\"` for it whatever the caller passed — so " &
            "`setAttribute(el, \"disabled\", \"false\")` recorded the " &
            "element as disabled. `getAttribute(el, \"disabled\")` then " &
            "answered \"\", because the stored key was `enabled`.",
      repairedIn: "isonim-gpui, PLAT-38. `mapAttributeName` and " &
                  "`mapAttributeValue` are the identity; the rewrite and " &
                  "the constant fold are gone and their absence is asserted " &
                  "with a planted positive control in " &
                  "`tests/test_input_focus.nim`.",
      evidence: "`setAttribute(el, \"disabled\", v)` then " &
                "`getAttribute(el, \"disabled\")` answered `v`, on the real " &
                "shim, for BOTH polarities and for every one of the twelve " &
                "interactive entries."),
    RetiredGpuiGap(
      id: "PLAT21-VG3",
      entries: @[pkModal],
      subject: gsRenderer,
      what: "THERE WAS NO ELEMENT FOCUS, SO EXCLUSIVITY COULD NOT BE " &
            "EXPRESSED. `Modal`'s specified behaviour is *a region that " &
            "takes exclusive input until dismissed*, and the vocabulary's " &
            "own note says the exclusivity is the medium-independent part — " &
            "a terminal focus trap and an inert DOM background are two " &
            "spellings of one statement about where input goes. isonim-gpui " &
            "had focus at the WINDOW level only (`window.onFocus`, per " &
            "window id); no element could hold, trap or refuse focus.",
      repairedIn: "isonim-gpui, PLAT-38. A node carries `focusable`, " &
                  "`focused` and `focus_trap`; `gpui_focused_count` counts " &
                  "holders over the WHOLE store (so the partition law can " &
                  "fail); `gpui_focus_next`/`prev` walk the render tree's " &
                  "document order; `gpui_set_focus_trap` confines that order " &
                  "to a subtree and makes `gpui_focus_element` REFUSE from " &
                  "outside it.",
      evidence: "A `Modal` held a focus trap on the real shim: focus moved " &
                "inside it when it opened, an element outside it was " &
                "refused, motion cycled within it, and at most one element " &
                "held focus at every point — counted over the whole tree.")]
    ## **THE RETIRED GAPS.** Three, all against the RENDERER, all closed by
    ## PLAT-38. `view_vocabulary_test.nim` asserts that none of these ids is
    ## still in `FiledGpuiGaps`, that each one's evidence arrived, and that
    ## the union of the two registers is the four ids PLAT-21 filed.

  FiledGpuiGaps*: seq[GpuiGap] = @[
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
    ## **ONE, since PLAT-38.** It was four; three were against the RENDERER and
    ## all three are in `RetiredGpuiGaps` above. The one that remains is the
    ## one filed against the VOCABULARY — and that split is why the shrink is
    ## the shape it is: no change to isonim-gpui could ever have closed
    ## `PLAT21-VG4`, because the entry has nothing to give the renderer.
    ##
    ## `view_vocabulary_test.nim` asserts the length, asserts every field
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

func retiredGapIds*(): seq[string] =
  for g in RetiredGpuiGaps: result.add g.id

func filedGapIds*(): seq[string] =
  for g in FiledGpuiGaps: result.add g.id

func retiredGapById*(id: string): RetiredGpuiGap =
  for g in RetiredGpuiGaps:
    if g.id == id: return g
  RetiredGpuiGap()

func isRetired*(id: string): bool =
  ## **ONE PREDICATE.** The retirement case and its negative twin both ask
  ## through this rather than each filtering a list, so a control cannot agree
  ## with itself while the rule is broken (Verification-Harness-Traps §30).
  for g in RetiredGpuiGaps:
    if g.id == id: return true
  false

func everFiledGapIds*(): seq[string] =
  ## Every gap PLAT-21 filed, whether it is still open or has been retired.
  ## **The identity the shrink is asserted against**: a gap that vanished from
  ## both registers is a claim that stopped being recorded, and an id that
  ## appears in both is a retirement nobody finished.
  result = filedGapIds()
  for id in retiredGapIds(): result.add id

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
