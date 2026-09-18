## anchor.nim — PLAT-28: a position that survives edits, with a declared side
## and a TYPED FATE when the text it sat in is deleted.
##
## Owns: Editor-ViewModel.md §8.2. A breakpoint, the execution pointer, a
## decoration range's endpoint and a remote collaborator's caret are all
## anchors; §8.2's two load-bearing properties are the whole of this module.
##
## =========================================================================
## THE FATE IS `MappedKind`, AND THAT IS A DECISION RATHER THAN AN OMISSION
## =========================================================================
##
## §8.2 asks for *"a defined, typed fate"*. PLAT-25 already built one:
## `change_set.Mapped` is a three-arm variant whose arms are exactly the three
## things that can become of a position — it survived, it was inside REPLACED
## text, it was inside PURELY DELETED text that collapsed to a point. A second
## enum here, with three members meaning the same three things, would be a
## second place for those three to drift and a conversion nobody grades.
##
## So `AnchorFate` is an **alias**, not a copy, and `MappedAnchor` CARRIES a
## `Mapped` rather than restating its fields. The cost is that an anchor's fate
## is spelled `mapDeleted` rather than `afDeleted`; the benefit is that there
## is no conversion at all, so there is nothing for a conversion to lose.
##
## =========================================================================
## THE REMOTE ARM GOES THROUGH PLAT-25's ONE REBASE PRIMITIVE
## =========================================================================
##
## §8.2's *"mapped through every change set that passes, INCLUDING REMOTE
## ONES"* is the sentence that makes this module a place a sixth hand-written
## double mapping could land. `change_set.mapOver` — the routine taking
## `before` — is private to that module and `rebase` returns both arms, so
## `mapAnchorRemote` below is four lines and spells no flag.
##
## `Verification-Harness-Traps.md` §35 is why that is checkable rather than
## asserted: PLAT-25's scan enumerates `viewmodel/editor/` with a compile-time
## `walkDir` instead of a hardcoded list, so this module joined its subject set
## the moment it was created, and its claim *"no other module in the editor
## tree can spell the double mapping"* is a claim about this file too.
##
## =========================================================================
## NO CLAMP — §36a
## =========================================================================
##
## Nothing here repairs a position. An anchor outside `[0, length]` is a
## caller's defect, and `mapPos` raises on it rather than pulling it into
## range; `anchorAt` raises on a negative position for the same reason. A guard
## that repairs silently cannot be told from one that never fires, and every
## wrong answer it corrects is an answer nobody sees being wrong.

import ./change_set

# THE WHOLE MODULE, NOT A HAND-PICKED LIST. `Side` and `MappedKind` are enums
# and Nim refuses to export an enum FIELD individually, so a partial export
# would have to name the types and leave `sideBefore` unreachable — the shape
# where a caller imports two modules to spell one concept. An anchor IS a
# change-set concept; re-exporting the algebra it is defined over is what makes
# `import ./anchor` sufficient.
export change_set

type
  AnchorFate* = MappedKind
    ## **AN ALIAS, NOT A SECOND ENUM.** See the header: the three things that
    ## can become of a position are PLAT-25's three, and a parallel enum would
    ## be a second declaration of them.

  AnchorSurface* = enum
    ## **THE FOUR SURFACES §8.2 NAMES**, as a value rather than as a comment.
    ## It decides nothing about the mapping — an anchor maps the same way
    ## whatever it is for — and it exists so a caller's decision about a fate
    ## can be made per surface, which is §8.2's *"a breakpoint on a deleted
    ## line is not a breakpoint on the line that took its place"*.
    asBreakpoint
    asExecutionPointer
    asDecorationRange
    asRemoteCaret

  Anchor* = object
    ## A byte offset that survives edits.
    ##
    ## `pos` is a DOCUMENT byte offset, the same unit `change_set` maps and the
    ## same unit `text_store.offsetOf` produces. Not a `(line, column)`: a line
    ## number is itself a thing an edit invalidates, so an anchor expressed in
    ## lines would need an anchor to hold it.
    pos*: int
    side*: Side
      ## §8.2's first property. Which side of an insertion AT this exact
      ## position the anchor sticks to.
    surface*: AnchorSurface
    id*: int
      ## The caller's handle, carried through unchanged so a mapped anchor can
      ## be matched back to the thing that owned it.

  MappedAnchor* = object
    ## What became of one anchor. The identity and the side are carried so a
    ## caller holding a `seq[MappedAnchor]` needs no parallel array to say
    ## which anchor each answer is about.
    id*: int
    side*: Side
    surface*: AnchorSurface
    outcome*: Mapped

  AnchorError* = object of ValueError

const
  AnchorFateCount* = ord(high(MappedKind)) - ord(low(MappedKind)) + 1
    ## **THREE, DERIVED FROM THE ENUM.** PLAT-28's floor multiplies it by two
    ## sides and five edit kinds; §10.4's third rule says a sweep's multiplier
    ## must be an asserted cardinality rather than a round number, and this is
    ## the cardinality it is asserted against.

  AnchorSurfaceCount* = ord(high(AnchorSurface)) - ord(low(AnchorSurface)) + 1
    ## **FOUR**, and it is the other multiplier in the same floor.

  SideCount* = 2
    ## `Side` is PLAT-25's and has two members. Spelled as a constant here so
    ## the floor's derivation reads off a name rather than a literal.

func anchorAt*(pos: int; side: Side; surface = asDecorationRange;
               id = 0): Anchor =
  ## The only constructor. It REFUSES a negative position rather than moving it
  ## to zero — §36a: the repair would make every later answer plausible and
  ## wrong, and there is no specified behaviour called "an anchor before the
  ## start of the document".
  if pos < 0:
    raise newException(AnchorError,
      "anchorAt: " & $pos & " is before the start of the document. An anchor " &
      "is not clamped into range; a negative offset is a defect in whatever " &
      "computed it.")
  Anchor(pos: pos, side: side, surface: surface, id: id)

func fate*(m: MappedAnchor): AnchorFate = m.outcome.kind
  ## The typed fate, read off the carried outcome. One `case`-free accessor, so
  ## there is no place for a conversion to lose an arm.

func survived*(m: MappedAnchor): bool = m.outcome.kind == mapSurvived

func position*(m: MappedAnchor): int =
  ## **THE POSITION, AND ONLY WHEN THERE IS ONE.** A caller that wants a
  ## plausible neighbour for a deleted anchor asks for it by name
  ## (`landingOf`), which is §6.2's whole reason for a three-arm return: *"a
  ## caller that wants a plausible neighbour has to ask for it"*.
  if m.outcome.kind != mapSurvived:
    raise newException(AnchorError,
      "position: anchor " & $m.id & " did not survive (" & $m.outcome &
      "). Ask `landingOf` for the point the caller has DECIDED to use, or " &
      "branch on `fate`.")
  m.outcome.pos

func landingOf*(m: MappedAnchor): int =
  ## The point a caller that has decided it wants one gets, for every fate.
  ## `change_set.mapPosOr` spelled through the anchor's own type — the decision
  ## has a name on it rather than being a nullable return nobody checked.
  case m.outcome.kind
  of mapSurvived: m.outcome.pos
  of mapDeleted: m.outcome.landing
  of mapCollapsed: m.outcome.at

func `==`*(a, b: Anchor): bool =
  a.pos == b.pos and a.side == b.side and a.surface == b.surface and
    a.id == b.id

func `$`*(a: Anchor): string =
  "anchor#" & $a.id & "@" & $a.pos & "/" &
    (if a.side == sideBefore: "before" else: "after") & "/" & $a.surface

func `$`*(m: MappedAnchor): string =
  "anchor#" & $m.id & " -> " & $m.outcome

proc mapAnchor*(a: Anchor; cs: ChangeSet): MappedAnchor =
  ## **ONE CHANGE SET, LOCAL.** `mapPos` is total over `[0, cs.length]` and
  ## raises outside it, which is the behaviour this module wants: an anchor
  ## carried against the wrong document is a defect that should arrive at the
  ## first mapping rather than at the first wrong screen.
  MappedAnchor(id: a.id, side: a.side, surface: a.surface,
               outcome: cs.mapPos(a.pos, a.side))

proc mapAnchors*(xs: openArray[Anchor]; cs: ChangeSet): seq[MappedAnchor] =
  result = @[]
  for a in xs: result.add a.mapAnchor(cs)

proc mapAnchorRemote*(a: Anchor; local, remote: ChangeSet): MappedAnchor =
  ## **THE REMOTE ARM, THROUGH THE ONE REBASE PRIMITIVE.**
  ##
  ## `a` sits in the document AFTER `local` — the local, unconfirmed edit.
  ## `remote` was computed against the document BEFORE `local`, which is what
  ## makes this a rebase rather than a second mapping: applied as it stands it
  ## would address bytes that moved.
  ##
  ## `rebase(remote, local).aOverB` is `remote`, re-expressed to apply after
  ## `local`. **There is no flag here and there is none to get wrong**: §6.1a's
  ## double mapping is written once, in `change_set`, and `mapOver` is private
  ## to it. This is the fourth in-tree call site of `rebase` and it is four
  ## lines because of that.
  let r = rebase(remote, local)
  a.mapAnchor(r.aOverB)

proc advance*(a: Anchor; cs: ChangeSet): Anchor =
  ## The anchor, moved onto the new document, for a caller that has DECIDED
  ## what a lost anchor means. The side and the surface ride along; only the
  ## position moves.
  ##
  ## Spelled here rather than at call sites so "I accept the landing point" is
  ## one decision with one name, and a caller that wants the fate uses
  ## `mapAnchor` and branches.
  Anchor(pos: a.mapAnchor(cs).landingOf, side: a.side, surface: a.surface,
         id: a.id)
