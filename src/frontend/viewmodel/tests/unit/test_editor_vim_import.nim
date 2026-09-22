## test_editor_vim_import.nim — PLAT-36's laws, sweeps and report.
##
## `codetracer-specs/GUI/Editing-Operations-And-Keymaps.md` §6, and
## `Testing/Editor-Model-Conformance-Suite.md` §7.1's two-way count over §6.1's
## twenty-two-spelling table and §6.3's five-member reason set.
##
## =========================================================================
## THE PARTITION LAW, AND THE THREE PRODUCERS THAT MAKE IT FALSIFIABLE
## =========================================================================
##
## `translated + reported == total mapping lines`, per file, as an EQUALITY.
## The milestone says why it is a law rather than a coverage figure: *"a
## coverage percentage is satisfied by an importer that loses lines, and a lost
## line is indistinguishable from a line the user never wrote."*
##
## The trap in it is `Verification-Harness-Traps` §22 — *"a cross-check whose
## two sides are computed from the same expression cannot fail"*. If `total`
## were `translated + reported`, the law would read `|A| + |B| == |A ∪ B|`. So
## the denominator has three independent producers and every case asserts all
## three:
##
##   1. the outcome list, filtered to `lkMapping`;
##   2. `vim_import.countMappingLines`, a second pass over the raw text in the
##      same module that never looks at an outcome;
##   3. `manifest.tsv`'s `mapLines`, produced by `vimrc-corpus-census.py` —
##      another language, no shared code, written from Vim's own documentation.
##
## The third is the one that matters and it is not decorative: the two parsers
## agree on 604 mapping lines and 283 option settings across the eighteen
## documents, and if they ever disagree the MANIFEST is what gets fixed, not
## either parser.
##
## =========================================================================
## §34, IN THE POPULATION — AND THERE ARE FOUR CLASSES, NOT THREE
## =========================================================================
##
## The trap this milestone is most exposed to is a corpus of `.vimrc` files
## that are all trivially translatable, so the untranslatable path is never
## exercised. The four file classes are asserted as EQUALITIES and each is
## required to be non-empty, witnessed by a named real file:
##
##   `empty`       no mapping line at all — `vimrc_example.vim`, `filetypes.vim`
##   `translated`  every mapping line translated — `dvorak/enable.vim`
##   `reported`    no mapping line translated — `swapmouse.vim` and six others
##   `mixed`       both — `mswin.vim`, `spf13-vim` and six others
##
## **The FOURTH class is the one that generalises.** *"I could not translate
## this line"* and *"this file binds nothing"* are different outcomes, and the
## same distinction lives one level down in `OutcomeKind`: `okUnbind` is an
## `unmap` that cleared nothing ON PURPOSE, `okUniqueRefused` is Vim's own
## refusal, and `okReported` is the failure. Collapsing them into an empty
## `seq[EditingBinding]` would make all three the same green run.

import std/[algorithm, sequtils, sets, strutils, tables, unittest]

import ../corpus/vimrc_corpus
import ../../keymap/vim_import
import ../../../../common/key_names

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a static assertion count when a suite dies before printing.
const ExpectedAssertions = 4056

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

# ===========================================================================
# THE SPEC, READ AND NEVER TRANSCRIBED
# ===========================================================================

const
  SpecRelativePath = "codetracer-specs/GUI/Editing-Operations-And-Keymaps.md"
  SpecSource = staticRead(
    "../../../../../../codetracer-specs/GUI/Editing-Operations-And-Keymaps.md")
    ## **READ, NEVER TRANSCRIBED**, exactly as `test_editor_vocabulary_oracle`
    ## reads §2.2. A transcribed copy would have been written from the same
    ## reading that produced the implementation, and the two would agree about
    ## a misreading.

  ExpectedFamilies = 22
  ExpectedReasons = 5
  ExpectedArguments = 5
  ExpectedOptions = 10

  ExpectedEmptyFiles = 2
  ExpectedTranslatedFiles = 1
  ExpectedReportedFiles = 7
  ExpectedMixedFiles = 8

proc sectionOf(startMark, endMark: string): string =
  let i = SpecSource.find(startMark)
  if i < 0:
    raise newException(ValueError, "section not found in " & SpecRelativePath &
      ": " & startMark)
  let j = SpecSource.find(endMark, i + startMark.len)
  if j < 0:
    raise newException(ValueError, "section end not found: " & endMark)
  SpecSource[i ..< j]

proc backtickedFirstColumns(section: string): seq[string] =
  ## §2.4's grammar: the declaration is the backticked token of the FIRST
  ## column, every other column is prose and is never read.
  result = @[]
  for raw in section.splitLines():
    let line = raw.strip()
    if not line.startsWith("|"): continue
    let rest = line[1 .. ^1].strip()
    if not rest.startsWith("`"): continue
    let close = rest.find('`', 1)
    if close < 0: continue
    result.add rest[1 ..< close]

proc squash(s: string): string =
  ## Collapse every run of whitespace to one space, so a list that wraps across
  ## source lines reads the same as one that does not.
  s.splitWhitespace().join(" ")

proc publishedReasons(): seq[string] =
  let norm = squash(sectionOf("### 6.3 The product is the report", "### 6.4 "))
  let open = norm.find("closed set (")
  let close = norm.find("), never a generic failure", open)
  if open < 0 or close < 0:
    raise newException(ValueError, "§6.3's closed set is not in its published shape")
  let inner = norm[open + len("closed set (") ..< close]
  result = @[]
  for part in inner.split("*, *"):
    result.add part.strip(chars = {'*', ' '})

proc publishedArguments(): seq[string] =
  let norm = squash(sectionOf("### 6.1 What is mechanically translatable",
                              "### 6.2 "))
  let marker = "; `<buffer>`, `<silent>`, `<expr>`, `<nowait>` and `<unique>` arguments"
  let i = norm.find(marker)
  if i < 0:
    raise newException(ValueError, "§6.1's argument list is not in its published shape")
  result = @[]
  for tok in norm[i ..< i + marker.len].split('`'):
    if tok.startsWith("<") and tok.endsWith(">"): result.add tok

proc publishedOptions(): seq[string] =
  let norm = squash(sectionOf("### 6.1 What is mechanically translatable",
                              "### 6.2 "))
  let marker = "A small set of `set` options that this model genuinely has: "
  let i = norm.find(marker)
  if i < 0:
    raise newException(ValueError, "§6.1's option list is not in its published shape")
  let j = norm.find('.', i + marker.len)
  result = @[]
  for tok in norm[i + marker.len ..< j].split('`'):
    let t = tok.strip()
    if t.len > 0 and t.allCharsInSet({'a' .. 'z'}): result.add t

let
  specFamilies = backtickedFirstColumns(
    sectionOf("**The twenty-two spellings, as a table", "### 6.2 "))
  specReasons = publishedReasons()
  specArguments = publishedArguments()
  specOptions = publishedOptions()

  implFamilies = (proc (): seq[string] =
    for f in VimMapFamily: result.add $f)()
  implReasons = (proc (): seq[string] =
    for r in ImportReason: result.add $r)()
  implArguments = (proc (): seq[string] =
    for a in VimMapArgument: result.add $a)()
  implOptions = (proc (): seq[string] =
    for o in VimOptionId: result.add $o)()

# ===========================================================================
# THE CORPUS, IMPORTED ONCE AT MODULE SCOPE — AND THE RAISES COUNTED
# ===========================================================================
#
# §36a's rule: *"every value computed at MODULE SCOPE from the subject under
# test is a place where a mutation can kill the harness instead of the suite.
# Count the raises there and assert the count in a case."* The importer is
# supposed to raise nowhere; an arm that makes it raise would otherwise take
# the process down before `unittest` printed a line and be reported as a badly
# written arm rather than as a kill.

type ImportFacts = object
  imp: VimImport
  raised: bool
  message: string

proc importAll(): (seq[ImportFacts], int) =
  var facts: seq[ImportFacts] = @[]
  var raises = 0
  for d in CorpusDocs:
    try:
      facts.add ImportFacts(imp: importVimConfig(d.text), raised: false,
                            message: "")
    except CatchableError as e:
      inc raises
      facts.add ImportFacts(imp: VimImport(), raised: true, message: e.msg)
  (facts, raises)

let
  (corpusFacts, corpusRaises) = importAll()
  manifest = manifestRows()

proc rowFor(id: string): VimrcManifestRow =
  for r in manifest:
    if r.id == id: return r
  raise newException(ValueError, "manifest has no row for " & id)

# ===========================================================================
# THE SWEEP FIXTURES — a tiny `.vimrc` per published spelling
# ===========================================================================

proc sampleFor(spelling: string): string =
  ## A ONE-LINE `.vimrc` exercising one spelling. The left-hand side is
  ## deliberately a chord no default Vim binding claims, so the case is about
  ## the spelling and not about a collision.
  case spelling
  of "unmap": "nnoremap gQ 0\nunmap gQ\n"
  of "mapclear": "nnoremap gQ 0\nmapclear\n"
  of "map!", "noremap!": spelling & " gQ ab\n"
  of "omap", "onoremap": spelling & " gQ w\n"
  of "imap", "inoremap", "cmap", "cnoremap", "lmap", "lnoremap":
    spelling & " gQ ab\n"
  else: spelling & " gQ 0\n"

suite "PLAT-36: importing a user's Vim configuration":

  # -------------------------------------------------------------------------
  # §7.1's two-way count, over four published lists
  # -------------------------------------------------------------------------

  test "THE MODULE-SCOPE CORPUS IMPORT RAISED NOTHING":
    # §36a. A raise here would kill the harness rather than a case, and the
    # verdict would read HARNESS-FAILURE — *"the mutation never ran"* — which
    # is indistinguishable from a badly written arm.
    ck corpusRaises == 0
    for f in corpusFacts:
      ck not f.raised
    ck corpusFacts.len == VimrcCorpusSize

  test "§6.1's twenty-two spellings: published == implemented, both directions":
    ck specFamilies.len == ExpectedFamilies
    ck implFamilies.len == ExpectedFamilies
    ck specFamilies.toHashSet.len == ExpectedFamilies
    ck implFamilies.toHashSet.len == ExpectedFamilies
    ck (specFamilies.toHashSet - implFamilies.toHashSet).len == 0
    ck (implFamilies.toHashSet - specFamilies.toHashSet).len == 0
    # The last line is the one usually omitted, and without it the two set
    # differences are both satisfied by two empty sets.
    ck specFamilies.toHashSet.len == implFamilies.toHashSet.len

  test "§6.3's reason set is CLOSED at five, published == implemented":
    ck specReasons.len == ExpectedReasons
    ck implReasons.len == ExpectedReasons
    ck (specReasons.toHashSet - implReasons.toHashSet).len == 0
    ck (implReasons.toHashSet - specReasons.toHashSet).len == 0
    ck specReasons.toHashSet.len == ExpectedReasons
    ck implReasons.toHashSet.len == ExpectedReasons
    for r in specReasons:
      ck r.len > 0

  test "§6.1's five map arguments and ten set options: both directions":
    ck specArguments.len == ExpectedArguments
    ck implArguments.len == ExpectedArguments
    ck (specArguments.toHashSet - implArguments.toHashSet).len == 0
    ck (implArguments.toHashSet - specArguments.toHashSet).len == 0
    ck specOptions.len == ExpectedOptions
    ck implOptions.len == ExpectedOptions
    ck (specOptions.toHashSet - implOptions.toHashSet).len == 0
    ck (implOptions.toHashSet - specOptions.toHashSet).len == 0
    ck specArguments.toHashSet.len == ExpectedArguments
    ck specOptions.toHashSet.len == ExpectedOptions

  test "THE CORPUS IS EIGHTEEN PINNED DOCUMENTS WITH A SOURCE AND A REVISION":
    ck CorpusDocs.len == VimrcCorpusSize
    ck manifest.len == VimrcCorpusSize
    let prov = provenanceRows()
    ck prov.len == VimrcCorpusSize
    var ids: seq[string] = @[]
    for d in CorpusDocs: ids.add d.id
    ck ids.toHashSet.len == VimrcCorpusSize
    for r in prov:
      ck r[0] in ids
      ck r[2].len == 40            ## a full commit sha, not an abbreviation
      ck r[5].len == 64            ## a full SHA-256, not a truncation
      ck r[1].contains("/")        ## owner/repo
      ck r[4].len > 0              ## a named licence
    for r in manifest:
      ck r.id in ids
      ck r.audit in ["hand-audited", "measured"]
    # Four distinct upstreams, so the corpus is not one project's house style.
    var repos: HashSet[string]
    for r in prov: repos.incl r[1]
    ck repos.len == 4

  test "THE FOUR FILE CLASSES ARE NON-EMPTY, AS EQUALITIES (§34)":
    var counts: array[VimrcFileClass, int]
    for i, d in CorpusDocs:
      let f = corpusFacts[i]
      let t = translatedMappingLines(f.imp)
      let r = reportedMappingLines(f.imp)
      let cls = (if t + r == 0: vfcEmpty
                 elif r == 0: vfcTranslated
                 elif t == 0: vfcReported
                 else: vfcMixed)
      ck cls == rowFor(d.id).class
      inc counts[cls]
    echo "CLASSES: empty=", counts[vfcEmpty], " translated=",
         counts[vfcTranslated], " reported=", counts[vfcReported],
         " mixed=", counts[vfcMixed]
    ck counts[vfcEmpty] == ExpectedEmptyFiles
    ck counts[vfcTranslated] == ExpectedTranslatedFiles
    ck counts[vfcReported] == ExpectedReportedFiles
    ck counts[vfcMixed] == ExpectedMixedFiles
    # Each one non-empty, stated separately from the equalities so that a
    # corpus whose distribution collapses fails on the CLAIM rather than on a
    # number somebody can edit.
    ck counts[vfcEmpty] > 0
    ck counts[vfcTranslated] > 0
    ck counts[vfcReported] > 0
    ck counts[vfcMixed] > 0
    ck counts[vfcEmpty] + counts[vfcTranslated] + counts[vfcReported] +
       counts[vfcMixed] == VimrcCorpusSize

  test "THE COVERAGE FIGURE IS MEASURED, AND IT IS N OF M":
    var translated = 0
    var total = 0
    var settings = 0
    var optTranslated = 0
    for f in corpusFacts:
      let (n, m) = coverageFraction(f.imp)
      translated += n
      total += m
      settings += optionOutcomes(f.imp)
      optTranslated += translatedOptionLines(f.imp)
    echo "COVERAGE: ", translated, " of ", total,
         " mapping lines translated; ", optTranslated, " of ", settings,
         " option settings"
    ck total == 604
    ck translated == 181
    ck settings == 283
    ck optTranslated == 20
    ck translated < total       ## an importer that translated everything would
                                ## be one whose corpus never reaches §6.2

  # -------------------------------------------------------------------------
  # THE PARTITION LAW — one case per corpus file
  # -------------------------------------------------------------------------

  for idx in 0 ..< VimrcCorpusSize:
    let docId = CorpusDocs[idx].id
    test "PARTITION LAW: translated + reported == total mapping lines — " & docId:
      let f = corpusFacts[idx]
      let row = rowFor(docId)
      let t = translatedMappingLines(f.imp)
      let r = reportedMappingLines(f.imp)
      let fromOutcomes = mappingOutcomes(f.imp)
      let fromSecondPass = countMappingLines(CorpusDocs[idx].text)
      # THE EQUALITY, against a denominator this file did not compute.
      ck t + r == row.mapLines
      ck fromOutcomes == row.mapLines
      ck fromSecondPass == row.mapLines
      # Every mapping line is in exactly one of the two outputs.
      ck t == row.translated
      ck r == row.reported
      ck boundLines(f.imp) + unbindLines(f.imp) +
         uniqueRefusedLines(f.imp) == t
      ck row.bound + row.unbound + row.uniqueRefused == row.translated
      # The option half, which is a second partition rather than part of this
      # one: §6.1's ten options are not mapping lines.
      ck optionOutcomes(f.imp) == row.settings
      ck translatedOptionLines(f.imp) + reportedOptionLines(f.imp) ==
         row.settings
      ck translatedOptionLines(f.imp) == row.optTranslated
      ck reportedOptionLines(f.imp) == row.optReported
      # The report holds exactly the reported lines of both partitions.
      ck f.imp.report.len == r + reportedOptionLines(f.imp)
      let rc = reasonCounts(f.imp)
      ck rc[irVimscript] == row.rVimscript
      ck rc[irPlugin] == row.rPlugin
      ck rc[irNoOperation] == row.rNoOperation
      ck rc[irNoOption] == row.rNoOption
      ck rc[irSyntax] == row.rSyntax
      ck f.imp.divergences.len == row.divergences
      ck (if f.imp.mapleaderResolved: f.imp.mapleader else: "-") == row.leader
      # EVERY report row carries a line number, the text and a reason — never
      # a generic failure (§6.3).
      for e in f.imp.report:
        ck e.line > 0
        ck e.text.len > 0
        ck e.detail.len > 0
        ck ($e.reason) in specReasons
      # EVERY line of the file has exactly one outcome, so nothing is dropped.
      var seen: HashSet[int]
      for o in f.imp.outcomes:
        if o.kind == lkMapping: seen.incl o.line
      ck seen.len == row.mapLines

  # -------------------------------------------------------------------------
  # THE MAP-FAMILY SWEEP — over §6.1's published list, not over the corpus
  # -------------------------------------------------------------------------

  for fam in VimMapFamily:
    test "MAP FAMILY: " & $fam & " is recognised and installs into its modes":
      let text = sampleFor($fam)
      let imp = importVimConfig(text)
      let mappings = mappingOutcomes(imp)
      # The fixture is one or two mapping lines depending on the spelling; the
      # count is asserted rather than assumed, because a spelling the parser
      # failed to recognise would produce ZERO and satisfy every check about
      # what the outcomes contain.
      ck mappings == countMappingLines(text)
      ck mappings >= 1
      ck translatedMappingLines(imp) + reportedMappingLines(imp) == mappings
      var found = false
      for o in imp.outcomes:
        if o.kind != lkMapping: continue
        case o.outcome
        of okBinding:
          if o.family == fam:
            found = true
            ck o.modes == familyModes(fam)
            ck o.chords.len > 0
            ck o.operations.len > 0
        of okUnbind:
          if o.unbindFamily == fam: found = true
        of okUniqueRefused, okOption, okReported:
          discard
      ck found
      # The modes are non-empty for every one of the twenty-two: a family that
      # installed into no mode would be a family whose bindings can never fire.
      ck familyModes(fam).len > 0

  # -------------------------------------------------------------------------
  # THE FIVE ARGUMENT DECISIONS — §6.1, one case each
  # -------------------------------------------------------------------------

  test "<buffer>: imported globally, with a divergence recorded":
    ck MapArgumentDecisions[vmaBuffer] == adGlobalWithDivergence
    let imp = importVimConfig("nnoremap <buffer> gQ 0\n")
    ck translatedMappingLines(imp) == 1
    ck reportedMappingLines(imp) == 0
    ck imp.keymap.bindings.len == 1
    ck imp.divergences.len == 1
    ck imp.divergences[0].note.contains("buffer")
    # The control: the same line WITHOUT the argument carries no divergence, so
    # the divergence is a statement about `<buffer>` and not about the line.
    let plain = importVimConfig("nnoremap gQ 0\n")
    ck plain.divergences.len == 0
    ck translatedMappingLines(plain) == 1

  test "<silent>: honoured trivially, and it is the one with NO divergence":
    ck MapArgumentDecisions[vmaSilent] == adNoDistinctionHere
    let imp = importVimConfig("nnoremap <silent> gQ 0\n")
    ck translatedMappingLines(imp) == 1
    ck imp.keymap.bindings.len == 1
    ck imp.divergences.len == 0
    let plain = importVimConfig("nnoremap gQ 0\n")
    ck imp.keymap.bindings[0].operation == plain.keymap.bindings[0].operation
    ck imp.keymap.bindings[0].chords == plain.keymap.bindings[0].chords

  test "<expr>: REFUSES the mapping, as invokes Vimscript":
    ck MapArgumentDecisions[vmaExpr] == adRefusesTheMapping
    let imp = importVimConfig("nnoremap <expr> gQ 0\n")
    ck reportedMappingLines(imp) == 1
    ck translatedMappingLines(imp) == 0
    ck imp.keymap.bindings.len == 0
    ck imp.report.len == 1
    ck imp.report[0].reason == irVimscript
    # The control: the same right-hand side without `<expr>` DOES translate, so
    # the refusal is about the flag rather than about the line.
    let plain = importVimConfig("nnoremap gQ 0\n")
    ck translatedMappingLines(plain) == 1

  test "<nowait>: imported, with a divergence about the global timeout":
    ck MapArgumentDecisions[vmaNowait] == adTimeoutIsGlobal
    let imp = importVimConfig("nnoremap <nowait> gQ 0\n")
    ck translatedMappingLines(imp) == 1
    ck imp.keymap.bindings.len == 1
    ck imp.divergences.len == 1
    ck imp.divergences[0].note.contains("timeout")
    ck EditingPendingTimeoutMs == 1000

  test "<unique>: ENFORCED — an already-claimed chord leaves it uninstalled":
    ck MapArgumentDecisions[vmaUnique] == adEnforced
    let imp = importVimConfig("nnoremap gQ 0\nnnoremap <unique> gQ $\n")
    ck mappingOutcomes(imp) == 2
    ck reportedMappingLines(imp) == 0
    ck translatedMappingLines(imp) == 2
    ck uniqueRefusedLines(imp) == 1
    ck boundLines(imp) == 1
    ck imp.keymap.bindings.len == 1
    ck imp.keymap.bindings[0].operation == "move-line-start"
    var refused = ""
    for o in imp.outcomes:
      if o.kind == lkMapping and o.outcome == okUniqueRefused:
        refused = o.claimedBy
    ck refused == "move-line-start"
    # The control: without `<unique>` the second line WINS, which is what makes
    # the refusal observable rather than a no-op.
    let plain = importVimConfig("nnoremap gQ 0\nnnoremap gQ $\n")
    ck plain.keymap.bindings.len == 1
    ck plain.keymap.bindings[0].operation == "move-line-end"
    ck uniqueRefusedLines(plain) == 0

  # -------------------------------------------------------------------------
  # THE TEN `set` OPTIONS — §6.1, one case each
  # -------------------------------------------------------------------------

  for opt in VimOptionId:
    test "SET OPTION: " & $opt & " is read, and an unknown one is reported":
      let boolean = opt in {voExpandtab, voWrap, voNumber, voRelativenumber,
                            voIgnorecase, voSmartcase}
      let line = (if boolean: "set " & $opt & "\n"
                  else: "set " & $opt & "=7\n")
      let imp = importVimConfig(line)
      ck optionOutcomes(imp) == 1
      ck translatedOptionLines(imp) == 1
      ck reportedOptionLines(imp) == 0
      ck imp.options[opt].given
      if boolean:
        ck imp.options[opt].boolean
        let off = importVimConfig("set no" & $opt & "\n")
        ck off.options[opt].given
        ck not off.options[opt].boolean
      else:
        ck imp.options[opt].number == 7
      # THE NEGATIVE HALF, in the same case: an option this model does NOT have
      # is reported rather than dropped, and the reason is the published one.
      let alien = importVimConfig("set " & $opt & "x=3\n")
      ck reportedOptionLines(alien) == 1
      ck translatedOptionLines(alien) == 0
      ck alien.report.len == 1
      ck alien.report[0].reason == irNoOption
      ck not alien.options[opt].given

  # -------------------------------------------------------------------------
  # ONE PLANTED LINE PER MEMBER OF THE CLOSED REASON SET
  # -------------------------------------------------------------------------
  #
  # *"A reason no planted line can produce is a reason nothing has ever
  # emitted, and a closed set with an unreachable member is an open set wearing
  # a type."* Each case plants its line into a real corpus document and
  # requires BOTH the reason to appear AND the totals to move.

  const PlantedFor: array[ImportReason, string] = [
    irVimscript: "nnoremap gQ :call Frobnicate()<CR>\n",
    irPlugin: "nmap gQ <Plug>SomePluginAction\n",
    irNoOperation: "nnoremap gQ <LeftMouse>\n",
    irNoOption: "set frobnitz=3\n",
    irSyntax: "nnoremap <LeftMouse> 0\n",
  ]

  for reason in ImportReason:
    test "PLANTED REASON: " & $reason & " is reachable and moves the totals":
      let baseText = docNamed("v04-vim-vimrc-example")
      let base = importVimConfig(baseText)
      let planted = importVimConfig(baseText & PlantedFor[reason])
      let baseCounts = reasonCounts(base)
      let plantedCounts = reasonCounts(planted)
      ck plantedCounts[reason] == baseCounts[reason] + 1
      ck planted.report.len == base.report.len + 1
      ck planted.report[^1].reason == reason
      ck planted.report[^1].line ==
         baseText.splitLines().len + (if baseText.endsWith("\n"): 0 else: 1)
      ck planted.report[^1].detail.len > 0
      # The totals move on the side the planted line belongs to, and NOT on the
      # other — which is what distinguishes "the report grew" from "the parser
      # reclassified something".
      if reason == irNoOption:
        ck optionOutcomes(planted) == optionOutcomes(base) + 1
        ck reportedOptionLines(planted) == reportedOptionLines(base) + 1
        ck mappingOutcomes(planted) == mappingOutcomes(base)
      else:
        ck mappingOutcomes(planted) == mappingOutcomes(base) + 1
        ck reportedMappingLines(planted) == reportedMappingLines(base) + 1
        ck translatedMappingLines(planted) == translatedMappingLines(base)
      # And every OTHER reason's count is unchanged, so a planted line that
      # produced two report rows would be caught.
      for other in ImportReason:
        if other != reason:
          ck plantedCounts[other] == baseCounts[other]

  # -------------------------------------------------------------------------
  # THE NEGATIVE ARM ON THE PARSER'S REACH
  # -------------------------------------------------------------------------

  test "A FILE OF ONLY UNTRANSLATABLE LINES PRODUCES ZERO BINDINGS AND M ENTRIES":
    # *"an importer that silently produces an empty keymap and exits 0 is
    # indistinguishable from one that worked."*
    const AllUntranslatable = """
" every line below is untranslatable, and each is a different member of the set
nnoremap <F2> :call One()<CR>
nmap <F3> <Plug>Two
vnoremap <F4> <RightMouse>
inoremap <F5> <C-R>=Three()<CR>
onoremap <F6> <Cmd>Four()<CR>
nnoremap <expr> <F7> Five()
"""
    let imp = importVimConfig(AllUntranslatable)
    let m = countMappingLines(AllUntranslatable)
    ck m == 6
    ck mappingOutcomes(imp) == m
    ck reportedMappingLines(imp) == m
    ck translatedMappingLines(imp) == 0
    ck imp.keymap.bindings.len == 0
    ck imp.report.len == m
    ck imp.macros.len == 0
    for e in imp.report:
      ck e.line > 0
      ck e.text.len > 0
    # M REPORT ENTRIES, not "at least one": a partial set is worse than an
    # empty one and "at least one" will not catch it (§4b).
    var lines: HashSet[int]
    for e in imp.report: lines.incl e.line
    ck lines.len == m

  test "THE NEGATIVE ARM'S POSITIVE CONTROL: a translatable file DOES bind":
    # Without this, "zero bindings" is satisfied by an importer that binds
    # nothing ever — §7b, an unfalsified negative control is a self-comparison
    # wearing a negation.
    const AllTranslatable = """
nnoremap gQ 0
nnoremap gW $
vnoremap gE d
"""
    let imp = importVimConfig(AllTranslatable)
    ck countMappingLines(AllTranslatable) == 3
    ck translatedMappingLines(imp) == 3
    ck reportedMappingLines(imp) == 0
    ck imp.report.len == 0
    ck imp.keymap.bindings.len == 3
    var ops: seq[string] = @[]
    for b in imp.keymap.bindings: ops.add b.operation
    ops.sort()
    ck ops == @["delete-selection", "move-line-end", "move-line-start"]

  # -------------------------------------------------------------------------
  # THE TYPED OUTCOME — the distinction this campaign keeps collapsing
  # -------------------------------------------------------------------------

  test "BINDING NOTHING AND FAILING TO READ ARE DIFFERENT CONSTRUCTORS":
    # An `unmap` of a chord nothing claimed clears zero bindings and is a
    # SUCCESS; a line naming a mouse button clears zero bindings and is a
    # FAILURE. Both produce an empty binding list, and only the type tells
    # them apart.
    let cleared = importVimConfig("unmap gQ\n")
    ck mappingOutcomes(cleared) == 1
    ck translatedMappingLines(cleared) == 1
    ck reportedMappingLines(cleared) == 0
    ck cleared.report.len == 0
    ck cleared.keymap.bindings.len == 0
    for o in cleared.outcomes:
      if o.kind == lkMapping:
        ck o.outcome == okUnbind
        ck o.cleared == 0

    let unreadable = importVimConfig("nnoremap <LeftMouse> 0\n")
    ck mappingOutcomes(unreadable) == 1
    ck translatedMappingLines(unreadable) == 0
    ck reportedMappingLines(unreadable) == 1
    ck unreadable.report.len == 1
    ck unreadable.keymap.bindings.len == 0
    for o in unreadable.outcomes:
      if o.kind == lkMapping:
        ck o.outcome == okReported

    # And a real `unmap` that DOES clear something, so `cleared == 0` is an
    # answer rather than a constant.
    let real = importVimConfig("nnoremap gQ 0\nunmap gQ\n")
    ck mappingOutcomes(real) == 2
    ck real.keymap.bindings.len == 0
    var clearedCount = -1
    for o in real.outcomes:
      if o.kind == lkMapping and o.outcome == okUnbind:
        clearedCount = o.cleared
    ck clearedCount == 1

  test "THE CORPUS REACHES ALL FIVE OUTCOME KINDS OR NAMES THE ONES IT DOES NOT":
    var kinds: array[OutcomeKind, int]
    for f in corpusFacts:
      for o in f.imp.outcomes:
        if o.kind == lkMapping or o.kind == lkSet:
          inc kinds[o.outcome]
    echo "OUTCOMES: binding=", kinds[okBinding], " unbind=", kinds[okUnbind],
         " unique-refused=", kinds[okUniqueRefused], " option=",
         kinds[okOption], " reported=", kinds[okReported]
    ck kinds[okBinding] > 0
    ck kinds[okUnbind] > 0
    ck kinds[okOption] > 0
    ck kinds[okReported] > 0
    # `okUniqueRefused` is NOT reached by the corpus and that is a fact rather
    # than a gap: none of the eighteen published configurations uses
    # `<unique>`. It is reached by the `<unique>` case above, and stating the
    # zero here is what keeps "no corpus witness" from being a silence.
    ck kinds[okUniqueRefused] == 0

  test "THE KEY NAMES THE IMPORTER PRODUCES ARE key_names' OWN (§30a)":
    # `keyName` goes BYTES to names and `canonicalKey` goes NOTATION to names,
    # so the two are not two copies of one predicate. What ties them together
    # is asserted rather than assumed: every name this module produces for a
    # byte `keyName` can read must be the string `keyName` produces.
    var checkedPairs = 0
    for c in 'a' .. 'z':
      let (ok, chords, _) = chordsOf("<C-" & $c & ">", "\\", false)
      ck ok
      ck chords.len == 1
      # `keyName` reads the BYTE, and five of the twenty-six control bytes are
      # a named key's byte — `<C-H>` is 0x08, which is Backspace. The importer
      # has to answer what the terminal can produce, or the binding is one no
      # reader can ever reach. This half of the case FAILED on its first run
      # and the importer is what changed.
      ck chords[0] == keyName($char(ord(c) - ord('a') + 1))
      inc checkedPairs
    for c in ' ' .. '~':
      let (ok, chords, _) = chordsOf($c, "\\", false)
      ck ok
      ck chords[0] == keyName($c)
      inc checkedPairs
    for pair in [("<CR>", "\r"), ("<Esc>", "\x1b"), ("<Tab>", "\t"),
                 ("<Space>", " "), ("<BS>", "\x7f")]:
      let (ok, chords, _) = chordsOf(pair[0], "\\", false)
      ck ok
      ck chords[0] == keyName(pair[1])
      inc checkedPairs
    ck checkedPairs == 26 + 95 + 5

  test "mapleader IS READ LEXICALLY, AND ONLY WHEN IT IS UNCONDITIONAL":
    let literal = importVimConfig("let mapleader = \",\"\nnnoremap <leader>q 0\n")
    ck literal.mapleaderResolved
    ck literal.mapleader == ","
    ck translatedMappingLines(literal) == 1
    ck literal.keymap.bindings[0].chords == @[",", "q"]

    let computed = importVimConfig(
      "let mapleader = g:something\nnnoremap <leader>q 0\n")
    ck not computed.mapleaderResolved
    ck reportedMappingLines(computed) == 1
    ck computed.report[0].reason == irVimscript

    let conditional = importVimConfig(
      "if 1\n    let mapleader = \",\"\nendif\nnnoremap <leader>q 0\n")
    ck not conditional.mapleaderResolved
    ck reportedMappingLines(conditional) == 1

    # The corpus witnesses both halves, which is why the distinction is here
    # rather than in a comment: `amix/vimrc` assigns a literal at column zero
    # and `spf13-vim` assigns a variable inside an `if`.
    ck rowFor("v15-amix-basic").leader == ","
    ck rowFor("v18-spf13-vimrc").leader == "-"

  test "A MULTI-OPERATION RIGHT-HAND SIDE BECOMES A MACRO, AND ITS LIMIT IS NAMED":
    # `ggj` is three keys and two argument-free operations, so it becomes a
    # macro the keymap replays.
    let imp = importVimConfig("nnoremap gQ ggj\n")
    ck translatedMappingLines(imp) == 1
    ck imp.macros.len == 1
    ck imp.keymap.bindings.len == 1
    ck imp.keymap.bindings[0].operation == "replay-macro"
    ck imp.keymap.bindings[0].args.id.len > 0
    ck imp.macros[imp.keymap.bindings[0].args.id] ==
       @["move-doc-start", "move-line-down"]

    # `y$` is two operations and one of them CARRIES AN ARGUMENT.
    # `EditorState.macros` records names without arguments, so replaying it
    # would drop the operator and the binding would do nothing — which is the
    # failure §6.3 exists to prevent, so the line is reported.
    let carries = importVimConfig("nnoremap gQ y$\n")
    ck reportedMappingLines(carries) == 1
    ck carries.macros.len == 0
    ck carries.keymap.bindings.len == 0
    ck carries.report[0].reason == irNoOperation
    ck carries.report[0].detail.contains("argument")

    # And the control that keeps the refusal from being about length: a
    # SINGLE argument-bearing operation binds fine, because a binding carries
    # its own args.
    let single = importVimConfig("nnoremap gQ ra\n")
    ck translatedMappingLines(single) == 1
    ck single.keymap.bindings[0].operation == "replace-char"
    ck single.keymap.bindings[0].args.ch == "a"

  test "CONSECUTIVE CHARACTERS COLLAPSE INTO ONE insert-text CARRYING THE TEXT":
    let imp = importVimConfig("cnoremap gQ tabe\n")
    ck translatedMappingLines(imp) == 1
    ck imp.macros.len == 0
    ck imp.keymap.bindings.len == 1
    ck imp.keymap.bindings[0].operation == "insert-text"
    ck imp.keymap.bindings[0].args.text == "tabe"
    ck imp.keymap.bindings[0].scope.panes == {epOtherPane}
    # TWO divergences §6.4 asks for, not one, and the second was a finding:
    # Vim's command line is not an editing mode here, AND the left-hand side
    # begins with a printable key in a text-entry mode, so §4.3's shadow means
    # the binding does not fire while that flag is set. The first write of this
    # case expected one and the SECOND one is the more useful of the two.
    ck imp.divergences.len == 2
    var notes = ""
    for d in imp.divergences: notes.add d.note
    ck notes.contains("Command-line")
    ck notes.contains("text-entry shadow")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
