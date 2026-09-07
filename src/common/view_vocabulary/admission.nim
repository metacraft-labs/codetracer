## view_vocabulary/admission.nim — PLAT-3 deliverable 5. The admission test,
## applied to every entry, with the answer recorded per entry.
##
## ## THE TEST, AS Extensibility-Model.md §3.3 STATES IT
##
##   "The test for admitting a widget: **can its semantics be stated without
##    reference to any medium, and does at least one existing front-end already
##    have it?** A widget that fails either is not ready to be abstract."
##
## Two halves, and they fail differently:
##
##   HALF ONE — medium-independent semantics. This is a judgement, and writing
##   it down as a boolean would make it look like a measurement. So each entry
##   carries the STATEMENT of its semantics; the test is whether that statement
##   mentions a medium, and `view_vocabulary_test` checks the statements
##   against a list of words no medium-independent sentence contains — pixel,
##   cell, colour, click, hover, mouse, CSS, ANSI, DOM, terminal, browser.
##   That is a weak check on its own, and it is paired with a strong one: the
##   entry's BEHAVIOUR is `behaviour.applyKey`, which the cross-medium suite
##   drives identically on two media. An entry whose semantics were secretly
##   medium-specific could not pass that.
##
##   HALF TWO — at least one front-end already has it. This is a measurement,
##   and it is not stated twice: `frontEndsHaving` is DERIVED from
##   `mappings.nim`, so the two cannot disagree. What the suite asserts is that
##   the derivation is non-empty for every entry, and it reports the set.
##
## ## THE RESULT, 2026-09-07: SIXTEEN ADMITTED, ZERO REJECTED
##
## Every entry passes both halves. The two that came closest to failing are
## worth naming, because "all sixteen passed" is the answer a rubber stamp also
## gives:
##
##   `Menu` — the TERMINAL does not have it. isonim-tui has 36 widget modules
##   and none is a menu, a menubar, a context menu or a dropdown;
##   `command/palette.nim` is the closest construct and is not one. It is a
##   fuzzy command palette over a SEARCH INDEX contributed by `Provider`s: its
##   contents are computed from a query rather than authored as an ordered set,
##   so there is no structure a `Menu`'s "at most one under attention" is a
##   position IN. (Its `selectedIdx` moves with Up/Down and Enter commits at
##   it, exactly as a Menu's would — the difference is what the index indexes,
##   not how it is driven. An earlier draft of this comment said the palette
##   "commits by SEARCH rather than by position"; that was wrong about the
##   mechanism and right about the conclusion, and is corrected here rather
##   than deleted because the wrong version is the one a reader would
##   reconstruct.) `Menu` is admitted because the test
##   asks for at least ONE front-end and the web has it outright — the product
##   ships `viewmodel/views/isonim_menu_shell_view.nim`, `ui/menu.nim` and
##   `viewmodel/views/context_menu_bridge.nim`. Its terminal mapping is
##   `msPartial` and says so.
##
##   `ProgressIndicator` — its semantics are one number, which is as
##   medium-independent as a statement gets, and the terminal and the web both
##   have it outright. It fails on GPUI (`progress` is not in the 35-entry tag
##   map), but the test is "at least one", not "all three". Recording GPUI's
##   absence is `mappings.nim`'s job and PLAT-21's gate.
##
## ## WHAT THE TEST REJECTED, AND WHY THAT IS THE INTERESTING HALF
##
## The entries below are NOT in the vocabulary and were considered. Each is
## recorded with which half it fails, because PLAT-3's risk is "the vocabulary
## grows to cover editors, frames and timelines and becomes a
## lowest-common-denominator UI that is bad everywhere", and the only defence
## against that is a written record of what was refused and on what grounds.
## Each of these is a PLAT-9 native view instead.

import std/strutils

import ./vocabulary
import ./mappings

type
  Admission* = object
    kind*: ViewKind
    semantics*: string
      ## The entry's meaning, stated without reference to any medium. This is
      ## half one of the test, written out so it can be read rather than
      ## asserted about.
    frontEnds*: set[FrontEnd]
      ## Derived from `mappings.nim`; see the header.
    admitted*: bool

  Rejection* = object
    ## A surface that was considered and refused. Kept in the vocabulary's own
    ## source because a rejection recorded nowhere is a rejection that will be
    ## re-litigated by the next person who wants the surface.
    name*: string
    failsMediumIndependence*: bool
    failsExistingFrontEnd*: bool
    reason*: string

func semanticsOf*(k: ViewKind): string =
  ## Half one, per entry. Exhaustive over `ViewKind`.
  ##
  ## Each sentence is written to survive the word list the suite checks it
  ## against, and that constraint is the point rather than an obstacle: a
  ## sentence that cannot be written without "click" or "cell" is a sentence
  ## about one medium.
  case k
  of pkText:
    "An immutable run of characters, with no state a reader can change and " &
    "no way to act on it."
  of pkButton:
    "A named action. Invoking it raises the action exactly once; while it is " &
    "unavailable, invoking it raises nothing."
  of pkCheckbox:
    "An independent boolean with a name. Invoking it inverts the boolean. " &
    "Nothing about it says when the change takes effect."
  of pkToggle:
    "A boolean that IS a setting rather than a request to change one. " &
    "Invoking it inverts the setting, and the effect is immediate."
  of pkInput:
    "An editable sequence of characters with one insertion point, expressed " &
    "as a position between characters. Editing inserts at the point, removes " &
    "the character before it or after it, and moves the point."
  of pkSelect:
    "A choice of at most one member of a known set, with two states: the " &
    "member chosen, and the member being considered while the set is open. " &
    "Closing without committing leaves the chosen member unchanged."
  of pkList:
    "An ordered set of members with at most one under attention. Attention " &
    "moves by one, or to either end, and skips members that are unavailable. " &
    "The member under attention can be acted on."
  of pkTree:
    "A hierarchy in which each node is open or closed, with one position " &
    "over the sequence of nodes that are reachable from the root through " &
    "open nodes. Opening and closing change that sequence, and the position " &
    "always names a member of it."
  of pkTable:
    "A rectangle of values addressed by a named column and an ordinal row, " &
    "with a position in two dimensions. Every row has one value per column."
  of pkTabs:
    "A choice of exactly one of an ordered set of named pages, where making " &
    "the choice is the same act as considering it."
  of pkCollapsible:
    "A named region whose contents are present or absent, with one act that " &
    "inverts which."
  of pkModal:
    "A region that receives all input directed at its owner until it is " &
    "dismissed, and returns that input where it came from afterwards."
  of pkMenu:
    "A transient ordered set of named actions, with at most one under " &
    "attention, from which exactly one action is taken or none is."
  of pkProgressIndicator:
    "The completed fraction of an unfinished operation, or the statement " &
    "that the fraction is not known."
  of pkImage:
    "Media identified by a media type, together with a sequence of " &
    "characters that carries the same meaning where the media cannot be " &
    "presented."
  of pkMarkdown:
    "A document in a portable markup language, presented as the structure " &
    "the markup describes rather than as the markup."

func frontEndsHaving*(k: ViewKind): set[FrontEnd] =
  ## Half two, DERIVED rather than restated. A front-end "has" an entry when
  ## its mapping is not `msAbsent`: a partial mapping is a front-end that has
  ## the construct and needs help, which is a different fact from not having it
  ## at all.
  for fe in FrontEnd:
    if mappingFor(fe, k).status != msAbsent:
      result.incl fe

func admission*(k: ViewKind): Admission =
  let fes = frontEndsHaving(k)
  Admission(kind: k, semantics: semanticsOf(k), frontEnds: fes,
            admitted: fes.card > 0 and semanticsOf(k).len > 0)

const
  MediumWords*: seq[string] = @[
    "pixel", "cell", "colour", "color", "click", "hover", "mouse", "pointer",
    "css", "ansi", "dom", "terminal", "browser", "screen", "font", "widget",
    "html", "keyboard", "key", "keys", "draw", "paint", "render"]
    ## Words a medium-independent sentence does not contain. Deliberately
    ## includes "keyboard": the KEYBOARD CONTRACT is a separate artefact
    ## (`behaviour.keyContract`) and an entry whose SEMANTICS need to mention
    ## keys has not been stated at the right level. `semanticsOf` above says
    ## "invoking it", and each medium decides what invoking is.
    ##
    ## This list is a weak check and is documented as one in the header. Its
    ## value is that it fires on the specific regression PLAT-3's risk names:
    ## an entry added later, described in the words of whichever front-end
    ## wanted it.

func mediumWordsIn*(s: string): seq[string] =
  ## WHOLE WORDS, not substrings, and this is not a stylistic preference — it
  ## is Verification-Harness-Traps §4d arriving in the other direction. The
  ## first version of this function used `contains`, and `"ansi"` is a
  ## substring of `"tr-a-n-s-i-ent"`, which is the word `Menu`'s semantics open
  ## with. A substring scan would have reported the vocabulary's own
  ## medium-independent sentence as medium-specific, and the fix — rewording
  ## `Menu` — would have been made to satisfy a broken scanner.
  var tokens: seq[string] = @[]
  var current = ""
  for ch in s.toLowerAscii:
    if ch in {'a' .. 'z', '0' .. '9'}:
      current.add ch
    else:
      if current.len > 0: tokens.add current
      current = ""
  if current.len > 0: tokens.add current
  for w in MediumWords:
    if w in tokens and w notin result:
      result.add w

# ---------------------------------------------------------------------------
# What was refused
# ---------------------------------------------------------------------------

const Rejections*: seq[Rejection] = @[
  Rejection(name: "Editor",
    failsMediumIndependence: true, failsExistingFrontEnd: false,
    reason: "A source editor's semantics are inseparable from its " &
      "presentation: a selection is a region of a laid-out document, and " &
      "what a region IS differs between a wrapped terminal grid and a " &
      "proportional-font document. Both isonim-tui (TextAreaWidget, 1,522 " &
      "lines) and the web have one, so half two passes and half one does " &
      "not. PLAT-22 says the same thing from the other end: 'the editor is " &
      "deliberately not a PLAT-3 vocabulary entry ... PLAT-3's admission " &
      "test would reject it'"),
  Rejection(name: "Timeline / scrubber",
    failsMediumIndependence: true, failsExistingFrontEnd: false,
    reason: "A scrubber's contract is continuous position within a range, " &
      "and its usefulness is its resolution. A terminal's resolution is the " &
      "number of columns it has; a pointer's is the number of pixels. An " &
      "abstraction over both would have to pick one and lie to the other. " &
      "The TUI has app/views/timeline_bar.nim and the web has " &
      "viewmodel/views/isonim_timeline_view.nim — two implementations, " &
      "deliberately"),
  Rejection(name: "Frame viewer / rendered image with a pixel cursor",
    failsMediumIndependence: true, failsExistingFrontEnd: false,
    reason: "PLAT-15 deliverable 3 states the problem: 'above tier 0 a cell " &
      "is not a pixel and the coordinate must never be inferred'. An entry " &
      "whose contract is a coordinate cannot be stated without saying whose " &
      "coordinate. Image (which carries media and a text equivalent, and no " &
      "coordinate) is the part of this that IS medium-independent, and it " &
      "is in the vocabulary"),
  Rejection(name: "Graph / node-link view",
    failsMediumIndependence: true, failsExistingFrontEnd: true,
    reason: "Fails BOTH halves, which is the cleanest kind of rejection. Its " &
      "semantics are a layout in a plane, and no front-end here has one"),
  Rejection(name: "Split / dock container",
    failsMediumIndependence: false, failsExistingFrontEnd: false,
    reason: "Its semantics ARE medium-independent and both front-ends have " &
      "one — so it passes the admission test and is still not here, because " &
      "it is PLAT-4's Layout, which is a MODEL rather than a view. Putting " &
      "it in the vocabulary would give the tree two owners. Recorded because " &
      "passing the admission test is necessary and not sufficient, and this " &
      "is the entry that shows the difference"),
  Rejection(name: "Toolbar / status bar",
    failsMediumIndependence: false, failsExistingFrontEnd: false,
    reason: "Passes both halves and is refused as CHROME rather than " &
      "structure: it is a container of Buttons and Texts with a position, " &
      "and position is the layout's. Admitting it would start the growth " &
      "PLAT-3's risk names, one reasonable-looking entry at a time"),
  Rejection(name: "Tooltip",
    failsMediumIndependence: true, failsExistingFrontEnd: true,
    reason: "Its trigger is hover, which a terminal reader without a pointer " &
      "cannot produce; a keyboard-triggered tooltip is a Modal or a status " &
      "line. isonim-tui has no tooltip widget. Fails both halves"),
  Rejection(name: "Drag handle",
    failsMediumIndependence: true, failsExistingFrontEnd: false,
    reason: "A drag is a continuous gesture in a plane. PLAT-5 models drags " &
      "as a separate machine over PURE drop-target computation precisely so " &
      "that one implementation can serve a pixel pointer and a cell cursor; " &
      "that is the right home for it and it is not a view")]

func describeAdmission*(a: Admission): string =
  ## One line per entry, in the form the milestone asks the result to be
  ## reported in: the entry, the verdict, and which front-ends already have it.
  var fes: seq[string] = @[]
  for fe in FrontEnd:
    if fe in a.frontEnds: fes.add frontEndName(fe)
  vocabularyName(a.kind) & ": " &
    (if a.admitted: "ADMITTED" else: "REJECTED") &
    " (front-ends having it: " &
    (if fes.len == 0: "none" else: fes.join(", ")) & ")"

func admissionSummary*(): string =
  var lines: seq[string] = @[]
  for k in ViewKind:
    lines.add describeAdmission(admission(k))
  lines.join("\n")
