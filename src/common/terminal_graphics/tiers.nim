## terminal_graphics/tiers.nim — PLAT-14. §2.1's seven tiers, as a value.
##
## CodeTracer-TUI-Graphics.md §2.1 publishes a table of seven rendering tiers,
## from a true-pixel graphics protocol down to an ASCII luminance ramp. This
## module is that table and nothing else: the enum, the sub-cell geometry of
## each tier, the Unicode repertoire each tier needs, and the ordering that
## lets a caller say "not better than this" without writing a comparison.
##
## ## NOTHING HERE READS THE ENVIRONMENT, OPENS AN FD, OR DRAWS A PIXEL
##
## Deliberately, and for `app/theme/capabilities.nim`'s reason: the DECISION is
## a pure function of a value, the READING of the process's environment is a
## host act, and the two live in different files so the whole decision table
## can be swept in a lane with no terminal in it. This module sits one level
## below even that — it is the vocabulary both the decision and the renderer
## speak, and it is in `src/common/` rather than in `src/frontend/tui/` because
## `value_presentation/surfaces.nim` has to name a tier in order to say which
## media a terminal surface can draw, and `src/common/` may not import the
## front-end.
##
## ## THE ORDINAL IS THE SPEC'S TIER NUMBER, AND THAT IS LOAD-BEARING
##
## `ord(itProtocol) == 0` … `ord(itAscii) == 6`, exactly as §2.1 numbers them.
## So a LARGER ordinal is a WEAKER rendering, and every "fail toward the safer
## answer" rule in this campaign is `max` over ordinals rather than `min` —
## which is the sort of inversion that reads correctly and behaves backwards.
## `weakerOf` below is the only place the comparison is written, so there is
## one predicate and every caller uses it (Verification-Harness-Traps §14).
##
## ## WHY TWO TIERS ARE NOT AUTOMATICALLY SELECTABLE, AND ONE IS NOT DRAWABLE
##
## `AutomaticTiers` is a strict subset of the enum and the gap is deliberate:
##
##   * **Quadrants, sextants and octants are never chosen automatically.**
##     §2.1's own note is that tiers 2-4 buy vertical resolution *at the cost of
##     colour* — six sextant sub-pixels share one foreground and one background
##     — so "more sub-pixels" is not "a better picture", and §2.2 says the
##     renderer picks "the highest tier the terminal supports **that suits the
##     hint**". For `ihPhoto` that is tier 1; for `ihLineArt`/`ihMask` it is
##     tier 5. Nothing suits tiers 2-4 better than one of those two, and — the
##     stronger reason — sextants and octants need a FONT that has them, which
##     no probe can detect. Selecting a tier on an undetectable premise is the
##     optimistic failure §3 forbids: the user gets a grid of tofu, which is
##     worse than a low-fidelity picture. They are reachable through
##     `--image-tier`, which §2.2 says always wins.
##   * **`itOctant` is in the model and REFUSES to draw.** See
##     `cell_render.glyphFor`. The U+1CD00 block maps 256 sub-cell masks onto
##     230 code points because 26 masks already have legacy spellings, and the
##     exception table could not be verified against Unicode 16's charts in
##     this checkout. An unverified table does not degrade the picture, it
##     draws a DIFFERENT one, which is exactly what §2.5 forbids ("It will not
##     be a good picture. It must still be a *correct* one"). The tier stays in
##     the enum because §2.1's table has seven rows and a model that silently
##     had six would disagree with the document it implements.
##
## ## A DEVIATION FROM §2.1'S "Needs" COLUMN, IN THE SAFE DIRECTION
##
## §2.1 lists quadrants as needing "Unicode 1.1". They are U+2596-U+259F, added
## in Unicode **3.2**; braille is U+2800-U+28FF, added in **3.0**. Only the
## half block U+2580 is Unicode 1.1. The table below uses the real versions, so
## a terminal whose repertoire this build cannot establish is offered a half
## block rather than a quadrant — a correction that can only ever move a
## decision DOWN the ladder.

type
  ImageTier* = enum
    ## §2.1's seven rows, in the document's own order and numbering.
    itProtocol = 0    ## Kitty / iTerm2 / Sixel — true pixels
    itHalfBlock = 1   ## `▀` — 1x2, two full colours per cell
    itQuadrant = 2    ## `▘▝▖▗▚▞█` — 2x2
    itSextant = 3     ## U+1FB00… — 2x3
    itOctant = 4      ## U+1CD00… — 2x4 (in the model; refuses to draw)
    itBraille = 5     ## `⠀`-`⣿` — 2x4 shape, one colour pair per cell
    itAscii = 6       ## luminance ramp — 1x1

  ImageProtocol* = enum
    ## Which tier-0 protocol an emission uses, or `ipNone` for no tier 0 at all.
    ##
    ## A SEPARATE ENUM FROM `nim_termctl.ImageFormat` AND FROM
    ## `isonim_tui.ImageEmittedProtocol`, and not because a third spelling is
    ## wanted. `src/common/` is compiled into the ViewModel's `nim js` lane,
    ## where `nim_termctl/image` (which imports `std/os`) has no business being;
    ## and `isonim_tui.ImageEmittedProtocol` lives in a module that drags the
    ## whole terminal renderer in. The MAPPING to `nim_termctl` is one function
    ## in `terminal_graphics/emit.nim`, in one place, and the byte-level
    ## agreement between the two is asserted rather than assumed — see
    ## `emit.kittyTransmit`.
    ipNone
    ipKitty
    ipITerm2
    ipSixel

  ImageHint* = enum
    ## §2.2's content hint. "The right tier depends on the image as well as the
    ## terminal": a reconstructed game frame wants colour (tier 1), a depth
    ## buffer or a wireframe wants shape resolution (tier 5).
    ihPhoto
    ihLineArt
    ihMask

  UnicodeRepertoire* = enum
    ## What a terminal-and-font pair can be relied on to draw, as a ladder so
    ## `>=` orders it. See this module's header for the version corrections.
    urAscii          ## nothing above U+007F
    urBlocks1_1      ## U+2580 half blocks — Unicode 1.1
    urWide3_2        ## U+2596-U+259F quadrants (3.2), U+2800 braille (3.0)
    urSextants13     ## U+1FB00-U+1FB3B — Unicode 13
    urOctants16      ## U+1CD00-U+1CDE5 — Unicode 16

  SubCell* = object
    ## How many source samples one cell carries at a tier, and how they are
    ## laid out. §2.1's "effective resolution per cell" column, as a value a
    ## test can read instead of a sentence a reader has to trust.
    cols*: int
    rows*: int

const
  AutomaticTiers* = {itProtocol, itHalfBlock, itBraille, itAscii}
    ## The tiers automatic selection may reach. See this module's header for
    ## why the other three are override-only; `selection.chooseTier` never
    ## returns a member outside this set and
    ## `terminal_graphics/selection_test.nim` asserts that over the whole
    ## environment cross product rather than over the rows somebody thought of.

  DrawableTiers* = {itProtocol, itHalfBlock, itQuadrant, itSextant,
                    itBraille, itAscii}
    ## The tiers that produce bytes. `itOctant` is absent — see the header.

func subCell*(tier: ImageTier): SubCell =
  ## §2.1's geometry column.
  case tier
  of itProtocol: SubCell(cols: 0, rows: 0)  ## not a cell rendering at all
  of itHalfBlock: SubCell(cols: 1, rows: 2)
  of itQuadrant: SubCell(cols: 2, rows: 2)
  of itSextant: SubCell(cols: 2, rows: 3)
  of itOctant: SubCell(cols: 2, rows: 4)
  of itBraille: SubCell(cols: 2, rows: 4)
  of itAscii: SubCell(cols: 1, rows: 1)

func subCellCount*(tier: ImageTier): int =
  let g = subCell(tier)
  g.cols * g.rows

func candidatesPerCell*(tier: ImageTier): int =
  ## How many (glyph, fg, bg) triples the per-cell search considers.
  ##
  ## §2.3: "The candidate set is small and fixed, so the search is a bounded
  ## loop per cell, not a general optimisation." This function IS that bound,
  ## and it is a function rather than a comment so a test can assert the work
  ## the renderer actually did against it — the campaign's rule that a bound, a
  ## claim and a measurement have to be the same quantity. The quantity here is
  ## *candidate masks evaluated*, which is deterministic and identical on every
  ## build and memory manager; no timing is claimed anywhere in this package.
  case tier
  of itProtocol: 0
  of itAscii: 0           ## a ramp lookup, not a search
  else: 1 shl subCellCount(tier)

func requiredRepertoire*(tier: ImageTier): UnicodeRepertoire =
  ## §2.1's "Needs" column, corrected to the real Unicode versions — see the
  ## module header.
  case tier
  of itProtocol: urAscii      ## the escape payload is ASCII; the protocol is
                              ## gated by `ImageProtocol`, not by a repertoire
  of itHalfBlock: urBlocks1_1
  of itQuadrant: urWide3_2
  of itBraille: urWide3_2
  of itSextant: urSextants13
  of itOctant: urOctants16
  of itAscii: urAscii

func needsTwoColours*(tier: ImageTier): bool =
  ## Whether the tier needs a foreground AND a background to mean anything.
  ## Tier 6 carries luminance in the GLYPH, so it survives a monochrome
  ## terminal; every cell tier above it does not.
  tier in {itHalfBlock, itQuadrant, itSextant, itOctant, itBraille}

func weakerOf*(a, b: ImageTier): ImageTier =
  ## The safer of two tiers — the one that asks LESS of the terminal.
  ##
  ## THE ONLY COMPARISON BETWEEN TIERS IN THE PRODUCT. Every "fail toward the
  ## lower tier" rule in `app/theme/image_capability.nim` is a call to this,
  ## so there is one predicate and the rule and its controls all reach it
  ## (§14). Written as `max` over the ordinal because §2.1 numbers the BEST
  ## tier 0.
  if ord(a) >= ord(b): a else: b

func isWeakerOrEqual*(a, b: ImageTier): bool =
  ## `a` asks no more of the terminal than `b` does.
  ord(a) >= ord(b)

func tierName*(tier: ImageTier): string =
  ## The spelling a `--image-tier` argument uses and a pane title shows.
  ## §4: "The pane declares its tier in its title, because a user needs to know
  ## whether they are looking at a faithful frame or a 2x3 approximation before
  ## they trust it."
  case tier
  of itProtocol: "protocol"
  of itHalfBlock: "half-block"
  of itQuadrant: "quadrant"
  of itSextant: "sextant"
  of itOctant: "octant"
  of itBraille: "braille"
  of itAscii: "ascii"

func parseTierName*(name: string): (bool, ImageTier) =
  ## `--image-tier=<name>`'s argument, matched against the enum's own published
  ## spellings — read off the enum, for `capabilities.parseTheme`'s reason: a
  ## tier added here is nameable on the same edit rather than a release later.
  ##
  ## THE FAILURE VALUE IS THE WEAKEST TIER, not `itProtocol`. A caller that
  ## ignored the `bool` — the mistake this shape exists to survive — gets the
  ## answer that cannot put garbage on a screen. `ImageTier`'s zero value is
  ## `itProtocol` for the spec-numbering reason above, so this is the one place
  ## in the package where a defaulted tier would have been optimistic, and it
  ## is written out rather than left to the enum.
  for tier in ImageTier:
    if tierName(tier) == name:
      return (true, tier)
  (false, itAscii)

func tierNames*(): string =
  ## The seven names, for a usage message. Same source as `parseTierName`.
  var parts: seq[string] = @[]
  for tier in ImageTier:
    parts.add tierName(tier)
  var acc = ""
  for i, p in parts:
    if i > 0: acc.add ", "
    acc.add p
  acc
