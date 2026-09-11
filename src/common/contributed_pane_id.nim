## contributed_pane_id.nim — PLAT-9 deliverable 1, the half that is a GRAMMAR.
##
## Extensibility-Model.md §6.1 states the constraint this module answers:
##
##   "`PaneKind` being a closed enum today is the constraint — an
##    extension-contributed pane needs an identity that is *not* a
##    compile-time enum value while keeping the property that an unknown pane
##    in a saved layout is a typed, reportable error rather than a blank
##    region."
##
## and §10's open decision 2 recommends "a namespaced string for contributed
## ones". This module owns that string: what it may contain, how it is
## composed, and — the part that matters most — why it can never be confused
## with a built-in pane.
##
## ## A CONTRIBUTED PANE ID IS ATTACKER-CONTROLLED TEXT
##
## It arrives from a third-party manifest, it is persisted into a layout
## document that the desktop reads back, and CodeTracer renders a region for
## it. Three things must therefore be impossible, and each is made impossible
## by construction rather than by a check somebody has to remember:
##
##   1. **It cannot collide with a built-in `PaneKind`.** Every contributed id
##      contains exactly one `/`; no `PaneKind` spelling contains one, and
##      `layout_model.nim` asserts that with a `static:` block over the whole
##      enum, so the disjointness is a compile error to break rather than a
##      sentence here. The layout encoder additionally writes the two under
##      SEPARATE JSON KEYS (`pane` vs `contributedPane`), so even a decoder
##      that ignored this grammar could not read one as the other.
##   2. **It cannot break the layout round-trip.** The charset below is closed
##      — ASCII letters, digits, `.`, `_`, `-` — so an id carries no quote, no
##      newline, no control character, no path separator other than the one
##      separator, and no Unicode. A hostile id is a JSON string that survives
##      `%` and `getStr` unchanged, and `layout_model`'s round-trip suite
##      drives exactly that.
##   3. **It cannot produce a blank region.** The decoder refuses a malformed
##      id with a typed error (`ldeBadContributedPane`), and an id that is
##      well-formed but names no loaded extension decodes to the typed value
##      `prUnloadedExtension` — a pane a front-end renders a report for. There
##      is no arm anywhere that drops a pane it did not recognise.
##
## ## COMPOSITION IS INJECTIVE, AND THAT IS THE ANTI-COLLISION ARGUMENT
##
## A manifest declares a surface's LOCAL id (`"metrics"`). The host composes
## the qualified id as `<pluginId>/<localId>`. Because neither segment may
## contain the separator, `qualifiedPaneId` is injective: two different
## `(plugin, surface)` pairs cannot produce one string. So two plugins can
## collide only by sharing a plugin id, and `resolution.nim` already refuses
## that with `pecDuplicatePlugin`. A plugin cannot name its way into another
## plugin's namespace, and it cannot name its way out of the contributed
## namespace at all.
##
## This module imports `std/strutils` and nothing else. It is pure data and
## total functions over it, so it compiles on the C and the JS targets and is
## reachable from both `src/common/plugin_model` (which validates a manifest)
## and `src/frontend/headless_app` (which persists a layout) without either
## importing the other.

import std/strutils

type
  PaneIdProblem* = enum
    ## Why a contributed pane id is not one. `pipOk` is the ordinary case and
    ## is the zero value, so a caller that forgets to check gets "fine" only
    ## when the checker actually said so.
    ##
    ## Enumerated rather than reported as a message string for the reason
    ## `LayoutProblemKind` is: a caller branches on the kind and a test asserts
    ## on it, without matching on prose.
    pipOk
    pipEmpty              ## the empty string
    pipNoSeparator        ## no `/` at all — this is how a built-in spelling fails
    pipTooManySeparators  ## more than one `/`
    pipEmptySegment       ## `/x`, `x/`, or `/`
    pipBadCharacter       ## a byte outside the closed charset
    pipEdgePunctuation    ## a segment starting or ending with `.`, `-` or `_`
    pipTooLong            ## a segment over `MaxPaneIdSegment` bytes

const
  PaneIdSeparator* = '/'
    ## THE ONE CHARACTER THAT MAKES THE TWO NAMESPACES DISJOINT. It is
    ## forbidden inside a segment and mandatory between them, and no `PaneKind`
    ## spelling contains it.

  MaxPaneIdSegment* = 64
    ## Per segment, not per id. A bound at all is the point: an id is written
    ## into a persisted document and rendered into a tab, and "as long as the
    ## manifest likes" is a decision nobody took.

  PaneIdAllowedPunctuation* = {'.', '_', '-'}
    ## The three separators a namespaced identifier conventionally uses.
    ## `/` is deliberately NOT here — see `PaneIdSeparator`.

func isPaneIdChar*(c: char): bool =
  ## The closed charset, as ONE predicate both the segment check and any
  ## caller that wants to explain the rule read (Verification-Harness-Traps
  ## §14: one predicate, one function).
  ##
  ## ASCII only. A Unicode id would let two visually identical ids be
  ## different strings — and, worse, let one contributed pane impersonate
  ## another in a tab strip.
  c in {'a' .. 'z'} or c in {'A' .. 'Z'} or c in {'0' .. '9'} or
    c in PaneIdAllowedPunctuation

func segmentProblem*(segment: string): PaneIdProblem =
  ## One segment — a plugin id or a surface's local id — against the grammar.
  if segment.len == 0: return pipEmptySegment
  if segment.len > MaxPaneIdSegment: return pipTooLong
  for c in segment:
    if c == PaneIdSeparator: return pipTooManySeparators
    if not isPaneIdChar(c): return pipBadCharacter
  if segment[0] in PaneIdAllowedPunctuation or
     segment[^1] in PaneIdAllowedPunctuation:
    # `.metrics` and `metrics-` are the shapes that read as a typo and sort
    # strangely; refusing them costs an author nothing and removes a class of
    # id that looks like two ids.
    return pipEdgePunctuation
  pipOk

func paneIdProblem*(qualified: string): PaneIdProblem =
  ## A whole contributed pane id: `<plugin>/<surface>`.
  ##
  ## `pipNoSeparator` is the arm that a BUILT-IN pane spelling lands in —
  ## `"editor"` is not a contributed pane id, and this function is what says
  ## so. That is the collision defence expressed as a total function rather
  ## than as a list of reserved words, which is the form that cannot fall
  ## behind `PaneKind`.
  if qualified.len == 0: return pipEmpty
  let cuts = qualified.count(PaneIdSeparator)
  if cuts == 0: return pipNoSeparator
  if cuts > 1: return pipTooManySeparators
  let at = qualified.find(PaneIdSeparator)
  let left = qualified[0 ..< at]
  let right = qualified[at + 1 .. ^1]
  result = segmentProblem(left)
  if result != pipOk: return
  result = segmentProblem(right)

func isContributedPaneId*(qualified: string): bool =
  paneIdProblem(qualified) == pipOk

func qualifiedPaneId*(plugin, surface: string): string =
  ## Compose. INJECTIVE over well-formed segments — see the module header.
  ##
  ## It does not validate: composing an id out of a bad segment produces a
  ## string `paneIdProblem` then refuses, and the refusal names the whole id,
  ## which is what an author needs to see. A composer that refused silently
  ## would be the missing-feature failure one layer down.
  plugin & PaneIdSeparator & surface

func pluginOf*(qualified: string): string =
  ## The owning plugin's id, or `""` when there is no separator. Used to
  ## attribute a pane in a saved layout to the extension that would have to be
  ## installed for it to appear.
  let at = qualified.find(PaneIdSeparator)
  if at < 0: "" else: qualified[0 ..< at]

func surfaceOf*(qualified: string): string =
  let at = qualified.find(PaneIdSeparator)
  if at < 0: "" else: qualified[at + 1 .. ^1]

func describe*(p: PaneIdProblem; subject: string): string =
  ## The human half, written here rather than at each call site so one problem
  ## cannot acquire two spellings. Every arm says what to do.
  case p
  of pipOk:
    "'" & subject & "' is a well-formed contributed pane id"
  of pipEmpty:
    "a contributed pane id is required and this one is empty"
  of pipNoSeparator:
    "'" & subject & "' is not namespaced. A contributed pane id is " &
      "'<plugin>" & $PaneIdSeparator & "<surface>'; a bare name is a " &
      "BUILT-IN pane's spelling and the two namespaces do not overlap"
  of pipTooManySeparators:
    "'" & subject & "' contains more than one '" & $PaneIdSeparator &
      "'. The separator divides exactly two segments"
  of pipEmptySegment:
    "'" & subject & "' has an empty segment; both the plugin and the " &
      "surface must be named"
  of pipBadCharacter:
    "'" & subject & "' contains a character outside the closed set " &
      "[A-Za-z0-9._-]. An id is persisted into a layout document and " &
      "rendered into a tab, so it carries no quotes, no control characters " &
      "and no Unicode"
  of pipEdgePunctuation:
    "'" & subject & "' has a segment starting or ending with '.', '-' or " &
      "'_'; name the segment without the leading or trailing punctuation"
  of pipTooLong:
    "'" & subject & "' has a segment longer than " & $MaxPaneIdSegment &
      " characters"
