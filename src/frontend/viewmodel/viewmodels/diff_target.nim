## Which git command a unified-diff tab's target asks for, as data.
##
## A unified-diff tab is identified by a *target* string (VCS-Panel.md,
## "Unified Diff View (Editor Integration)"):
##
## - ``""`` / ``"Working Tree"`` — every working-tree change, against ``HEAD``;
## - ``file:<path>`` — one file's working-tree change, against ``HEAD``;
## - ``commit:<hash>:<path>`` — what one commit changed in one file;
## - ``commit:<hash>`` — everything one commit changed;
## - anything else — read as a bare path, like ``file:``.
##
## ``ui/unified_diff.nim`` used to decide the git arguments for each of these
## inline, in a JavaScript-only module no headless test could reach.  The
## decision is pure — a target and the active review in, git arguments out —
## so it lives here and ``vcs/diff_target_test.nim`` asserts it natively.  The
## caller still owns *running* git and parsing what comes back.
##
## The one input beyond the target is the active review's commit context.  It
## exists for VCS-Panel.md, "Which two revisions a file row compares": the
## DeepReview Changed Files list mints ``file:<path>`` rows, and a review may
## list a file whose record carries no diff, so the tab falls back to git.  When
## that review names a commit, the row must show *that commit's* change —
## ``git diff <baseCommitSha> <commitSha> -- <path>`` when the review names its
## base, otherwise what ``commit:<commitSha>:<path>`` shows — and never
## ``git diff HEAD -- <path>``, which compares the working tree instead of the
## change under review.  (codetracer-pm issue
## ``2026-09-29-changed-files-rows-diff-against-head-for-a-selected-historical-commit``.)
## The row keeps minting ``file:<path>`` because review navigation in
## ``vcs_vm.nim`` keys its tabs on that shape; the commit scope is applied here,
## where the target is resolved, instead.

import std/strutils

type
  DiffGitPlan* = object
    ## What a target resolves to.
    args*: seq[string]
      ## The git arguments, without the leading ``git``.  Every per-file form
      ## carries a ``--`` pathspec relative to the repository root, which is
      ## why the caller runs git there (see ``loadFromGit``).
    sessionTitle*: string
      ## The tab's session title.
    newRevision*: string
      ## The revision the diff's *new* side shows, which is where context
      ## expansion must read the file's full text from.  ``""`` means the
      ## working tree: ``gitFileText`` reads it as "the file on disk".
    reviewScoped*: bool
      ## True when the active review's commit, not the working tree, decided
      ## the command, so the caller can record the review's revisions as the
      ## ones compared rather than ``HEAD``.

proc shortSha(hash: string): string =
  hash[0 ..< min(12, hash.len)]

proc commitFilePlan(hash, filepath: string): DiffGitPlan =
  ## One commit's change to one file, against its parent.  ``--root`` makes a
  ## root commit diff against the empty tree instead of printing nothing.
  DiffGitPlan(
    args: @["diff-tree", "-p", "--no-commit-id", "--root", hash, "--",
            filepath],
    sessionTitle: "Diff: " & filepath & " (" & shortSha(hash) & ")",
    newRevision: hash)

proc diffGitPlan*(target: string; reviewCommitSha = "";
                  reviewBaseCommitSha = ""): DiffGitPlan =
  ## Resolve a unified-diff target to the git command that produces its diff.
  ##
  ## ``reviewCommitSha`` / ``reviewBaseCommitSha`` are the active DeepReview's
  ## ``commitSha`` / ``baseCommitSha``; pass ``""`` for both when no review is
  ## active.  They change only what a ``file:<path>`` target asks for — see the
  ## module header for why.
  if target.len == 0 or target == "Working Tree":
    DiffGitPlan(args: @["diff", "HEAD"],
                sessionTitle: "Working Tree Changes",
                newRevision: "")
  elif target.startsWith("file:"):
    let filepath = target[5 .. ^1]
    if reviewCommitSha.len > 0:
      # VCS-Panel.md, "Which two revisions a file row compares": a review
      # naming a commit scopes its file rows to that commit, never to the
      # working tree.  With the review's base, compare exactly the two
      # revisions the review is of; without one, show what the commit itself
      # changed — the very command `commit:<sha>:<path>` runs, so the two row
      # kinds cannot drift apart.  The title stays the `file:` one: the tab
      # is still the review's row for this path.
      var plan =
        if reviewBaseCommitSha.len > 0:
          DiffGitPlan(args: @["diff", reviewBaseCommitSha, reviewCommitSha,
                              "--", filepath],
                      newRevision: reviewCommitSha)
        else:
          commitFilePlan(reviewCommitSha, filepath)
      plan.sessionTitle = "Diff: " & filepath
      plan.reviewScoped = true
      plan
    else:
      # No review commit: the working tree's change, as in normal VCS mode.
      DiffGitPlan(args: @["diff", "HEAD", "--", filepath],
                  sessionTitle: "Diff: " & filepath,
                  newRevision: "")
  elif target.startsWith("commit:"):
    let commitPart = target[7 .. ^1]
    let colonIdx = commitPart.find(':')
    if colonIdx >= 0:
      commitFilePlan(commitPart[0 ..< colonIdx], commitPart[colonIdx + 1 .. ^1])
    else:
      DiffGitPlan(
        args: @["diff-tree", "-p", "--no-commit-id", "--root", commitPart],
        sessionTitle: "Commit Diff: " & shortSha(commitPart),
        newRevision: commitPart)
  else:
    DiffGitPlan(args: @["diff", "HEAD", "--", target],
                sessionTitle: "Diff: " & target,
                newRevision: "")
