## viewmodels/agent_diff_rows.nim
##
## An agent evidence diff as the rows CodeTracer's VCS panel (`VCSDiffLineRow`,
## hunk headers kept) and DeepReview panel (`DeepReviewDiffLineEntry`, hunk
## headers dropped) show. The walk itself -- each raw line's kind and the
## numbering both panels show -- is `nim_agents/diff_walk` (CTF-M1 slice 8);
## these are the two adapters onto CodeTracer's row types, pinned by
## `tests/unit/test_agent_diff_rows.nim`, which passed on the walkers they
## replace.

import nim_agents/diff_walk

import ../store/types
import vcs_vm

proc diffRows*(diff: string): seq[VCSDiffLineRow] =
  ## The VCS panel's rows: every line, hunk headers included.
  for line in walkDiffLines(diff):
    let lineType =
      case line.kind
      of wlHunk: "hunk"
      of wlAdded: "add"
      of wlRemoved: "delete"
      of wlContext: "context"
    result.add VCSDiffLineRow(lineType: lineType, content: line.content,
      oldLine: line.oldLine, newLine: line.newLine)

proc deepReviewLineType*(line: string): string =
  ## The DeepReview panel's word for one raw line (a hunk header reads
  ## "context" here; `deepReviewLines` drops hunk headers before asking).
  case line.kindOf()
  of wlAdded: "added"
  of wlRemoved: "removed"
  of wlHunk, wlContext: "context"

proc deepReviewLines*(diff: string): seq[DeepReviewDiffLineEntry] =
  ## The DeepReview panel's lines: hunk headers dropped.
  for line in walkDiffLines(diff):
    if line.kind == wlHunk:
      continue
    result.add DeepReviewDiffLineEntry(lineType: deepReviewLineType(line.content),
      content: line.content, oldLine: line.oldLine, newLine: line.newLine)
