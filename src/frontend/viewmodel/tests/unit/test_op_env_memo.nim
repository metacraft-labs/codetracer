## The operation environment's memo is an OPTIMISATION, so it must be
## invisible: every environment it hands out equals the one a full derivation
## of the same document would build.
##
## Run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_op_env_memo.nim
##
## `operations.initOpEnv` keeps the last document's derived contexts (cluster
## boundaries, line index, wrap cache) and, when the next call's document
## differs, MOVES them by the edit between the two rather than re-deriving
## (`incrementalDerivation`). PLAT-42's frame budget is why: every operation on
## a 40,000-line file re-derived all three, ~680 ms per cursor motion.
##
## Held here to the full derivation — `clusterBoundariesOf`, `toTextStore` and
## `initWrapCache` of the new text, computed independently — over:
##
##   * PLAT-24's eighteen corpus documents, each edited at its start, its end,
##     mid-line, across a line break (joining two lines) and by inserting one;
##   * the edits a cluster-aware splice could get wrong: a combining mark
##     attached to the character BEFORE the edit, a CR LF split and re-joined,
##     a ZWJ emoji sequence cut in half, a whole document replaced, and an
##     empty document grown and emptied;
##   * a seeded stream of 300 random edits chained through the memo, with soft
##     wrap off (the terminal's setting) and on (column 8), so the wrap cache's
##     incremental path is exercised as well as the boundaries';
##
## and, the negative half: an environment handed out earlier is never changed
## by a later derivation, and a settings change is a full derivation.
##
## No mocks: the real operation environment and the real derivations.

import std/[random, strutils, unittest]

import ../../editor/operations
import ../../editor/selection_ops
import ../../editor/text_store
import ../../editor/wrap
import ../generators/vocabulary_generator

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  NoWrap = WrapSettings(wrapColumn: 0)
  RandomSteps = 300
  Seed = 20260923

proc rowsOf(c: WrapCache): seq[DisplayRow] =
  for i in 0 ..< c.rowCount: result.add c.rowAt(i)

proc agreesWithFull(env: OpEnv; doc: string; settings: WrapSettings): bool =
  ## The environment `initOpEnv` returned, against an independent full
  ## derivation of `doc`.
  let store = toTextStore(doc)
  env.ctx.doc == doc and env.display.doc == doc and
    env.ctx.boundaries == clusterBoundariesOf(doc) and
    env.display.boundaries == env.ctx.boundaries and
    env.ctx.store.lineCount == store.lineCount and
    env.display.store.lineCount == store.lineCount and
    rowsOf(env.display.cache) == rowsOf(initWrapCache(doc, settings))

proc edited(doc: string; at, removed: int; inserted: string): string =
  doc[0 ..< at] & inserted & doc[min(doc.len, at + removed) .. ^1]

proc step(before, after: string; settings: WrapSettings): bool =
  ## Prime the memo with `before`, move it to `after`, compare.
  discard initOpEnv(before, settings)
  initOpEnv(after, settings).agreesWithFull(after, settings)

suite "the operation environment's memo equals a full derivation":

  for settings in [NoWrap, wrapSettings(8)]:
    let label = "wrap " & $settings.wrapColumn
    test "PLAT-24's corpus, edited at the start, the end, mid-line and across lines — " & label:
      let docs = scenarioDocs()
      ck docs.len == 18
      for d in docs:
        let t = d.text
        checkpoint(d.id)
        ck step(t, "x" & t, settings)
        ck step(t, t & "x", settings)
        ck step(t, edited(t, t.len div 2, 0, "yz"), settings)
        let nl = t.find('\n')
        if nl >= 0:
          ck step(t, edited(t, nl, 1, ""), settings)       # join two lines
          ck step(t, edited(t, nl, 0, "\n\n"), settings)   # split one
        ck step(t, edited(t, 0, t.len div 3, ""), settings)

    test "the splices a cluster-aware derivation could get wrong — " & label:
      # A combining acute joins the `e` BEFORE the edit into one cluster.
      ck step("cafe\nnext", "café\nnext", settings)
      ck step("café\nnext", "cafe\nnext", settings)
      # CR LF split by an insert between the two, then re-joined.
      ck step("a\r\nb\r\nc", "a\rX\nb\r\nc", settings)
      ck step("a\rX\nb\r\nc", "a\r\nb\r\nc", settings)
      # A ZWJ family cut in half, and restored.
      let family = "\u{1F468}‍\u{1F469}‍\u{1F467}"
      ck step("x " & family & " y\nz", "x \u{1F468} y\nz", settings)
      ck step("x \u{1F468} y\nz", "x " & family & " y\nz", settings)
      # Whole document replaced; empty grown and emptied.
      ck step("one\ntwo\nthree", "four\nfive", settings)
      ck step("", "abc\ndef", settings)
      ck step("abc\ndef", "", settings)
      # The same text twice: no edit at all.
      ck step("same\ntext", "same\ntext", settings)

    test "300 seeded random edits chained through the memo — " & label:
      var r = initRand(Seed + settings.wrapColumn)
      let alphabet = @["a", "b", " ", "\n", "\t", "\r\n", "é",
                       "é", "中", "\u{1F600}", "‍"]
      var doc = scenarioDocs()[3].text
      discard initOpEnv(doc, settings)
      var agreed = 0
      for i in 0 ..< RandomSteps:
        # A byte offset on a RUNE boundary, as an editor's edit would be.
        var at = r.rand(doc.len)
        while at > 0 and at < doc.len and (ord(doc[at]) and 0xC0) == 0x80:
          dec at
        var removed = r.rand(min(8, doc.len - at))
        while at + removed < doc.len and
              (ord(doc[at + removed]) and 0xC0) == 0x80:
          inc removed
        var ins = ""
        for _ in 0 ..< r.rand(3): ins.add alphabet[r.rand(alphabet.high)]
        doc = edited(doc, at, removed, ins)
        let env = initOpEnv(doc, settings)
        if env.agreesWithFull(doc, settings): inc agreed
        else: checkpoint("step " & $i & " disagrees")
      ck agreed == RandomSteps

suite "the memo changes how long an answer takes, never what it was":

  test "an environment handed out earlier is not changed by a later one":
    let a = "first\ndocument"
    let envA = initOpEnv(a, NoWrap)
    let boundsA = envA.ctx.boundaries
    discard initOpEnv("second\ndocument, longer", NoWrap)
    discard initOpEnv(a & "!", NoWrap)
    ck envA.ctx.doc == a
    ck envA.ctx.boundaries == boundsA
    ck envA.agreesWithFull(a, NoWrap)

  test "a settings change is a full derivation, not a move":
    let d = "a long line that wraps at eight cells\nshort"
    discard initOpEnv(d, NoWrap)
    let wrapped = initOpEnv(d, wrapSettings(8))
    ck wrapped.agreesWithFull(d, wrapSettings(8))
    ck wrapped.display.cache.rowCount > toTextStore(d).lineCount

suite "op-env memo — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
