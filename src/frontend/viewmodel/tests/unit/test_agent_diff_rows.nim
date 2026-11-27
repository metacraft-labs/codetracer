## Both shapes of an agent evidence diff (`viewmodels/agent_diff_rows`): the VCS
## panel's rows, hunk headers kept, and the DeepReview panel's lines, hunk
## headers dropped, with the numbering both panels show today (both counters
## from 0, a hunk header advancing neither, file headers and the empty string
## after a trailing newline counted as context; codetracer-pm issue
## 2026-11-26-agent-workspace-diffs-number-lines-from-zero-not-from-the-hunk).
## Written to pass on the code before CTF-M1 slice 8 and unchanged after it.
## Every expectation is written out by hand.

import std/unittest
import store/types
import viewmodels/[vcs_vm, agent_diff_rows]

const Sample = "--- a/x.nim\n+++ b/x.nim\n@@ -10,3 +10,4 @@ proc f\n keep\n-old\n+new\n+more\n tail\n"
const TwoHunks = "@@ -1 +1 @@\n-a\n+b\n@@ -40 +40 @@\n c\n"

proc v(t, c: string; o, n: int): VCSDiffLineRow =
  VCSDiffLineRow(lineType: t, content: c, oldLine: o, newLine: n)
proc d(t, c: string; o, n: int): DeepReviewDiffLineEntry =
  DeepReviewDiffLineEntry(lineType: t, content: c, oldLine: o, newLine: n)

suite "agent evidence diff rows":
  test "VCS rows keep the hunk header, numbered as today":
    check diffRows(Sample) == @[
      v("context", "--- a/x.nim", 1, 1), v("context", "+++ b/x.nim", 2, 2),
      v("hunk", "@@ -10,3 +10,4 @@ proc f", 2, 2), v("context", " keep", 3, 3),
      v("delete", "-old", 4, 0), v("add", "+new", 0, 4), v("add", "+more", 0, 5),
      v("context", " tail", 5, 6), v("context", "", 6, 7)]
    check diffRows(TwoHunks) == @[
      v("hunk", "@@ -1 +1 @@", 0, 0), v("delete", "-a", 1, 0), v("add", "+b", 0, 1),
      v("hunk", "@@ -40 +40 @@", 1, 1), v("context", " c", 2, 2),
      v("context", "", 3, 3)]

  test "DeepReview lines drop the hunk header, numbered as today":
    check deepReviewLines(Sample) == @[
      d("context", "--- a/x.nim", 1, 1), d("context", "+++ b/x.nim", 2, 2),
      d("context", " keep", 3, 3), d("removed", "-old", 4, 0),
      d("added", "+new", 0, 4), d("added", "+more", 0, 5),
      d("context", " tail", 5, 6), d("context", "", 6, 7)]
    check deepReviewLines(TwoHunks) == @[
      d("removed", "-a", 1, 0), d("added", "+b", 0, 1),
      d("context", " c", 2, 2), d("context", "", 3, 3)]

  test "the empty diff and a bare sign":
    check diffRows("") == @[v("context", "", 1, 1)]
    check deepReviewLines("") == @[d("context", "", 1, 1)]
    check deepReviewLines("+\n-") == @[d("added", "+", 0, 1), d("removed", "-", 1, 0)]
    check deepReviewLineType("+++ b") == "context"
    check deepReviewLineType("---") == "context"
