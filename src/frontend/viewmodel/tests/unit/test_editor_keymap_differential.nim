## test_editor_keymap_differential.nim — PLAT-31's `DIFF-4`: THE SAME EDITING
## TASK THROUGH BOTH KEYMAPS.
##
## §8's table, row four: *"one editing task (start document, end document)"*,
## compared on *"the end document, and the recorded sequence of named
## operations, whose difference must be a filed entry"*.
##
## =========================================================================
## THE TRAP THIS FILE IS MOSTLY ABOUT
## =========================================================================
##
## The milestone names it before it names the population:
##
## > *"if both keymaps are thin tables over one resolver, the comparison is two
## > calls to one implementation and cannot fail (§30). What makes it a
## > differential axis is that the two keymaps take DIFFERENT PATHS to the same
## > end — Vim through operator-pending state, Kakoune through a selection — so
## > the compared artefact is the OPERATION SEQUENCE, which genuinely differs,
## > and not only the document, which trivially agrees."*
##
## Both keymaps ARE thin tables over one resolver — that is the design, and it
## is the right one. So the differential is not between two resolvers; it is
## between two PATHS, and this file's job is to make "two paths" a thing that
## is asserted rather than assumed. It is armed in three independent places:
##
##   1. **PER TASK, AT THE VALUE LEVEL.** Each arm's recorded operation
##      sequence must be a subset of ITS OWN model's reachable set, and the two
##      sequences must differ. An arm that resolved through the other model's
##      keymap would record operations that model reaches and this one does
##      not — `begin-operator` is the sharpest of them, and the case names it.
##   2. **ACROSS THE POPULATION, AS AN EQUALITY.** `DivergentOperationTasks` of
##      `TaskSetCardinality`, not a spot check.
##   3. **ON THIS FILE'S OWN SOURCE (§30a).** If the Vim arm ends up calling
##      `kakouneKeymap()`, every task still passes and nothing is compared —
##      the documents agree, the sequences agree, and no assertion about the
##      ANSWER can see it, because the answer is what was substituted. So the
##      two constructors are counted in the body by name. This is the one place
##      in this milestone where a source scan is not a weaker substitute for a
##      value assertion but the only instrument that reaches the question.
##
## =========================================================================
## §34, IN THE PLACE IT ACTUALLY LIVES HERE
## =========================================================================
##
## Six milestones of this campaign have met §34 somewhere different each time.
## Here it is in the POPULATION, and it has two shapes rather than one:
##
##   * **A row whose two key sequences are the same compares a thing with
##     itself.** `d w` under Vim against `d w` under Kakoune would agree about
##     the end document for a reason that has nothing to do with either keymap
##     being right. Asserted as an equality over the whole set.
##   * **Two distinct KEY sequences can still drive one OPERATION sequence** —
##     a task using only keys both models spell the same way in the same order.
##     That class is the one the differential is actually about, and it is
##     counted separately.
##
## The second is the sharper and is the one a reader should dispute first.

import std/[sequtils, sets, strutils, unittest]

import ../generators/keymap_task_set
import ../../keymap/vim_keymap
import ../../keymap/kakoune_keymap

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a static assertion count when a suite dies before printing.
const ExpectedAssertions = 16077

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

let
  docs = scenarioDocs()
  vim = vimKeymap()
  kak = kakouneKeymap()
  settings = wrapSettings(DisplayWrapA)
  vimReach = reachableOperations(vim.keymap, kmVim)
  kakReach = reachableOperations(kak.keymap, kmKakoune)

const
  ExpectedScenarioDocs = 18
    ## The corpus framing PLAT-30 already paid for. A task set over ASCII
    ## cannot distinguish a word motion that respects grapheme clusters from
    ## one that respects runes, so the documents are §5's and not this file's.

  VimOnlyWitness = "begin-operator"
    ## **THE OPERATION THAT MAKES §30a's SUBSTITUTION VISIBLE IN AN ANSWER.**
    ## Vim reaches it — it is what `d` does in normal mode — and Kakoune files
    ## it as *"THE DEFINING ABSENCE"*, because noun-then-verb has no
    ## operator-pending state to enter. If the Vim arm were resolved through
    ## the Kakoune keymap, no task would record it and the case below would
    ## die. The source scan is still here, because a substitution that also
    ## removed this assertion would not be visible in any other answer.

  KakouneOnlyWitness = "delete-line"
    ## The other direction. Kakoune binds `Ctrl+x` to the published
    ## `delete-line`; Vim files it deliberately, reaching the same document
    ## through `begin-operator` + `select-around-line` + the operator. The two
    ## witnesses are the `DIFF-4` difference in one word each.

proc vimScope(): EditingScope =
  ## **CALLED BY NAME, AND COUNTED IN THIS FILE'S SOURCE.** See the header's
  ## third arming: the two arms are two named constructors, and a body in which
  ## one of them appeared twice would be the substitution §30a describes.
  EditingScope(model: kmVim, product: pmEdit, pane: epEditor, mode: emNormal,
               textEntry: false)

proc kakouneScope(): EditingScope =
  EditingScope(model: kmKakoune, product: pmEdit, pane: epEditor,
               mode: emNormal, textEntry: false)

proc runVim(d: ScenarioDoc; t: EditingTask): (EditorState, seq[string]) =
  driveKeys(taskState(d, t), vim.keymap, vimScope(), t.vimKeys, settings)

proc runKakoune(d: ScenarioDoc; t: EditingTask): (EditorState, seq[string]) =
  driveKeys(taskState(d, t), kak.keymap, kakouneScope(), t.kakouneKeys,
            settings)

suite "PLAT-31: the DIFF-4 population, before a single task is compared":
  test "the task set is its declared cardinality, and no id appears twice":
    # A DATA FILE WHOSE LENGTH IS CHECKED, so it can grow but cannot silently
    # shrink to the four tasks somebody demoed. This assertion is what caught
    # the table being written with one more row than the constant declared.
    ck TaskSet.len == TaskSetCardinality
    ck duplicateTaskIds().len == 0
    ck TaskSet.mapIt(it.id).deduplicate().len == TaskSetCardinality

  test "every task family is non-empty":
    # A task set that drifted into forty-one operator-plus-motion rows would
    # satisfy every count in the generator and would not contain a single
    # composed command with a count — the shape PLAT-31's risk section says
    # gets approximated.
    let counts = familyCounts()
    for family in TaskFamily:
      ck counts[family] > 0
    ck counts[tfCount] >= 8
    ck counts[tfRegister] >= 3

  test "§34 — every row's two KEY sequences are distinct, as an equality":
    # Not a spot check: `41 of 41`. A row that compared `d w` against `d w`
    # would be a green case that measured nothing at all.
    ck distinctKeySequences() == TaskSetCardinality
    for t in TaskSet:
      ck t.vimKeys != t.kakouneKeys
      ck t.vimKeys.len > 0
      ck t.kakouneKeys.len > 0

  test "§34 — and the sharper half: the two OPERATION sequences also differ":
    # Two distinct KEY sequences can still drive ONE operation sequence. That
    # class is the one the differential is actually about, so it is counted
    # separately and asserted as an equality against its own declared number.
    #
    # THE FIRST RUN OF THIS CASE MOVED THE NUMBER, from 41 to 38. Three rows
    # are single operations that both models bind under different keys; they
    # are named in `CoincidentOperationTasks` rather than left inside a count
    # that would have read as "every row takes two paths".
    var divergent = 0
    var coincident: seq[string] = @[]
    for t in TaskSet:
      let (_, vops) = runVim(docs[0], t)
      let (_, kops) = runKakoune(docs[0], t)
      if vops != kops: inc divergent else: coincident.add t.id
    ck divergent == DivergentOperationTasks
    # THE EXCEPTIONS BY NAME AND NOT ONLY BY COUNT. A fourth row falling into
    # the class would keep any count that was written as "41 minus a few" and
    # would move this list.
    ck coincident == @CoincidentOperationTasks
    # …and the two numbers are tied to each other, so neither can drift into
    # agreeing with a set it no longer describes.
    ck DivergentOperationTasks ==
       TaskSetCardinality - CoincidentOperationTasks.len

  test "the documents are the corpus, through PLAT-30's scenario frame":
    ck docs.len == ExpectedScenarioDocs
    var classes = initHashSet[int]()
    for d in docs: classes.incl d.cls
    ck classes.len == 9

  test "§30a — this file's body names the two constructors, once each":
    # THE ONLY INSTRUMENT THAT REACHES THIS QUESTION. If `runVim` resolved
    # through `kakouneKeymap()`, every task below would still pass: the two
    # documents would agree because they are the same computation, the two
    # sequences would agree for the same reason, and the comparison would be
    # two calls to one implementation. No assertion about the ANSWER can see
    # that, because the answer is what was substituted.
    const Raw = staticRead("test_editor_keymap_differential.nim")
    # **THE PROSE IS NOT THE BODY.** This file's own header discusses
    # `kakouneKeymap()` by name — it is the substitution the scan is about —
    # and a scan that counted the discussion would report three calls where
    # there is one. Comments and doc comments are stripped before anything is
    # counted, which is the same rule `ci/lib/nim-imports.sh` keeps for the
    # closure gates and is kept here for the same reason.
    var code = ""
    for line in Raw.splitLines():
      let text = line.strip()
      if text.startsWith("#"): continue
      code.add line
      code.add "\n"
    let Body = code
    # **EVERY NEEDLE IS BUILT BY CONCATENATION AND NOT WRITTEN WHOLE**, because
    # a scan over its own source counts its own string literals: spelling
    # `"vimKeymap()"` here would make the count 2 and the assertion would be
    # about this line rather than about the arm. The joins below appear in the
    # source in pieces, so they match the call sites and nothing else — which
    # is the same trap §32's needle rules are about, met inside a needle.
    let vimCtor = "vimKeymap" & "()"
    let kakCtor = "kakouneKeymap" & "()"
    # The two constructors, each called exactly once.
    ck Body.count(vimCtor) == 1
    ck Body.count(kakCtor) == 1
    # …and the two arms are two named procs, each naming its own keymap. A
    # `runVim` whose body said `kak.keymap` is exactly the substitution.
    ck Body.count("proc " & "runVim(") == 1
    ck Body.count("proc " & "runKakoune(") == 1
    ck Body.contains("vim.keymap, " & "vimScope()")
    ck Body.contains("kak.keymap, " & "kakouneScope()")
    ck not Body.contains("vim.keymap, " & "kakouneScope()")
    ck not Body.contains("kak.keymap, " & "vimScope()")
    # The two scopes carry the two models, one each.
    ck Body.count("model: " & "kmVim") == 1
    ck Body.count("model: " & "kmKakoune") == 1
    # And the keys each arm drives come from its OWN column of the row. A row
    # carries both sequences precisely so neither is derived from the other
    # (§30); an arm reading the wrong column would compare one path twice.
    ck Body.count("t." & "vimKeys, settings") == 1
    ck Body.count("t." & "kakouneKeys,") == 1

  test "§30a, at the value level — each arm records what the other cannot reach":
    # The source scan's companion, and the stronger of the two where it
    # applies: `begin-operator` is reachable under Vim and FILED under
    # Kakoune, so a Vim arm resolved through the Kakoune keymap could not
    # record it. Asserted by NAME rather than as "the sets differ".
    ck VimOnlyWitness in vimReach
    ck VimOnlyWitness notin kakReach
    ck KakouneOnlyWitness in kakReach
    ck KakouneOnlyWitness notin vimReach
    var sawVimOnly = false
    var sawKakouneOnly = false
    for t in TaskSet:
      let (_, vops) = runVim(docs[0], t)
      let (_, kops) = runKakoune(docs[0], t)
      if VimOnlyWitness in vops: sawVimOnly = true
      if KakouneOnlyWitness in kops: sawKakouneOnly = true
    ck sawVimOnly
    ck sawKakouneOnly

suite "PLAT-31: the two reachable sets, and every difference a FILED entry":
  test "the two sets genuinely differ — the differential has a subject":
    # Asserted before the filing, because two identical sets satisfy every
    # "difference is filed" check vacuously.
    ck vimReach != kakReach
    let onlyVim = vimReach.filterIt(it notin kakReach)
    let onlyKak = kakReach.filterIt(it notin vimReach)
    ck onlyVim.len > 0
    ck onlyKak.len > 0

  test "everything Vim reaches and Kakoune does not is filed BY KAKOUNE":
    let filed = filedOperations(kak).toHashSet()
    for name in vimReach:
      if name in kakReach: continue
      # A NAMED, FILED ENTRY — with a reason, not merely a membership.
      ck name in filed

  test "everything Kakoune reaches and Vim does not is filed BY VIM":
    let filed = filedOperations(vim).toHashSet()
    for name in kakReach:
      if name in vimReach: continue
      ck name in filed

  test "the union of the two reachable sets is published, and the cardinality holds":
    # Both directions have now been checked and both are satisfied by two empty
    # sets; the cardinality is the line usually omitted.
    var union = initHashSet[string]()
    for name in vimReach: union.incl name
    for name in kakReach: union.incl name
    ck union.len > vimReach.len
    ck union.len > kakReach.len
    for name in union:
      ck operationNamed(name) >= 0
    ck unpublishedOperations(vim.keymap, kmVim).len == 0
    ck unpublishedOperations(kak.keymap, kmKakoune).len == 0

# ---------------------------------------------------------------------------
# 41 TASKS x 2 KEYMAPS
# ---------------------------------------------------------------------------

suite "PLAT-31: DIFF-4 — 41 editing tasks, each through both keymaps":
  for task in TaskSet:
    let t = task

    test "DIFF-4 " & t.id & " / vim":
      var changed = 0
      for d in docs:
        let start = taskState(d, t)
        let (vState, vops) = runVim(d, t)
        let (kState, _) = runKakoune(d, t)
        # EVERY RECORDED NAME IS ONE OF PLAT-30's 224.
        ck vops.len > 0
        for name in vops:
          ck operationNamed(name) >= 0
          # …and one THIS MODEL reaches. An arm resolved through the other
          # keymap would fail here before the documents were ever compared.
          ck name in vimReach
        # THE END DOCUMENTS ARE EQUAL — the differential's first half, stated
        # from this arm's side.
        ck vState.doc == kState.doc
        if vState.doc != start.doc: inc changed
      # …and the task is not a no-op dressed as an agreement. One row is a
      # deliberate identity and says so in its note; every other row must move
      # the document on every document.
      if t.id == "indent-then-dedent":
        ck changed == 0
      else:
        ck changed == docs.len

    test "DIFF-4 " & t.id & " / kakoune":
      for d in docs:
        let (vState, vops) = runVim(d, t)
        let (kState, kops) = runKakoune(d, t)
        ck kops.len > 0
        for name in kops:
          ck operationNamed(name) >= 0
          ck name in kakReach
        ck kState.doc == vState.doc
        # THE SHARPER HALF, PER TASK: the two paths are two paths. Asserted on
        # every document rather than on the first, because a row whose
        # sequences coincide on one document and diverge on another is a row
        # the aggregate count would score either way.
        #
        # The three named exceptions are asserted in the OTHER direction — the
        # sequences must be EQUAL — rather than skipped, because a row excused
        # from a check is a row nothing checks, and the reason they are excused
        # is itself a claim: that the two models agree about what that key
        # means.
        if t.id in CoincidentOperationTasks:
          ck vops == kops
        else:
          ck vops != kops
      # The two key sequences this row carries are distinct — §34, at the row
      # rather than only in the aggregate.
      ck t.vimKeys != t.kakouneKeys
      ck describeTask(t).contains(t.id)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
