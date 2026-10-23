## Headless tests for which git command a unified-diff tab asks for
## (``viewmodels/diff_target.diffGitPlan``).
##
## VCS-Panel.md, "Which two revisions a file row compares":
##
##   "A row diffs the revision whose file list it belongs to; it never compares
##    a historical commit's file with the working tree. … When the review names
##    a commit (`commitSha`), that row's diff is asked of git **for that
##    commit** — `git diff <baseCommitSha> <commitSha> -- <path>` when the
##    review names its base, otherwise what `commit:<commitSha>:<path>` shows —
##    and never `git diff HEAD -- <path>`, which would compare the working tree
##    instead of the change under review.  Only a review that names no commit
##    falls back to the working-tree diff."
##
## The defect this pins is codetracer-pm issue
## ``2026-09-29-changed-files-rows-diff-against-head-for-a-selected-historical-commit``:
## the DeepReview Changed Files list mints ``file:<path>`` rows, a review file
## with no diff record falls through to git, and git was asked for
## ``diff HEAD -- <path>`` whatever commit the review was of.
##
## What is covered:
## - a review naming a commit and its base: ``file:<path>`` asks for
##   ``diff <base> <commit> -- <path>``, and the new side is the commit;
## - a review naming a commit and no base: ``file:<path>`` asks for exactly
##   what ``commit:<commit>:<path>`` asks for, and the new side is the commit;
## - no review commit: ``file:<path>`` stays the working-tree diff against
##   ``HEAD``, with the working tree (``""``) as the new side;
## - the working-tree, ``commit:`` and bare-path targets are unaffected by a
##   review's commit context.
##
## No mocks: ``diffGitPlan`` is a pure function of its inputs, so every case
## calls the production proc directly.  Running git on the result is the
## caller's job (``ui/unified_diff.nim``) and is not re-tested here.

import std/unittest

import viewmodels/diff_target

const
  ReviewCommit = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
  ReviewBase = "0f1e2d3c4b5a69788796a5b4c3d2e1f098765432"
  Path = "src/lib/module.nim"

suite "diff target: a review's file row is scoped to the reviewed commit":
  test "review with a base: diff <base> <commit> -- <path>":
    let plan = diffGitPlan("file:" & Path, ReviewCommit, ReviewBase)
    check plan.args == @["diff", ReviewBase, ReviewCommit, "--", Path]
    check plan.newRevision == ReviewCommit
    check plan.reviewScoped
    check "HEAD" notin plan.args

  test "review without a base: the same command commit:<sha>:<path> uses":
    let plan = diffGitPlan("file:" & Path, ReviewCommit, "")
    let commitPlan = diffGitPlan("commit:" & ReviewCommit & ":" & Path)
    check plan.args == @["diff-tree", "-p", "--no-commit-id", "--root",
                         ReviewCommit, "--", Path]
    check plan.args == commitPlan.args
    check plan.newRevision == ReviewCommit
    check plan.reviewScoped
    check "HEAD" notin plan.args

  test "a base with no commit is not a commit-scoped review":
    # A base alone names no change under review, so the row keeps the
    # working-tree meaning rather than inventing a right-hand side.
    let plan = diffGitPlan("file:" & Path, "", ReviewBase)
    check plan.args == @["diff", "HEAD", "--", Path]
    check plan.newRevision == ""
    check not plan.reviewScoped

suite "diff target: without a review commit nothing changes":
  test "file:<path> is the working tree against HEAD":
    let plan = diffGitPlan("file:" & Path)
    check plan.args == @["diff", "HEAD", "--", Path]
    check plan.sessionTitle == "Diff: " & Path
    check plan.newRevision == ""
    check not plan.reviewScoped

  test "working tree, by empty target and by name":
    for target in ["", "Working Tree"]:
      checkpoint("target: '" & target & "'")
      for (commit, base) in [("", ""), (ReviewCommit, ReviewBase)]:
        let plan = diffGitPlan(target, commit, base)
        check plan.args == @["diff", "HEAD"]
        check plan.sessionTitle == "Working Tree Changes"
        check plan.newRevision == ""
        check not plan.reviewScoped

  test "a bare path keeps its working-tree meaning":
    let plan = diffGitPlan(Path, ReviewCommit, ReviewBase)
    check plan.args == @["diff", "HEAD", "--", Path]
    check plan.newRevision == ""

suite "diff target: commit targets ignore the review context":
  const Other = "fedcba9876543210fedcba9876543210fedcba98"

  test "commit:<hash>:<path>":
    for (commit, base) in [("", ""), (ReviewCommit, ReviewBase)]:
      let plan = diffGitPlan("commit:" & Other & ":" & Path, commit, base)
      check plan.args == @["diff-tree", "-p", "--no-commit-id", "--root",
                           Other, "--", Path]
      check plan.sessionTitle == "Diff: " & Path & " (fedcba987654)"
      check plan.newRevision == Other
      check not plan.reviewScoped

  test "commit:<hash>":
    for (commit, base) in [("", ""), (ReviewCommit, ReviewBase)]:
      let plan = diffGitPlan("commit:" & Other, commit, base)
      check plan.args == @["diff-tree", "-p", "--no-commit-id", "--root",
                           Other]
      check plan.sessionTitle == "Commit Diff: fedcba987654"
      check plan.newRevision == Other
      check not plan.reviewScoped

  test "a short hash is not over-sliced in the title":
    let plan = diffGitPlan("commit:abc")
    check plan.sessionTitle == "Commit Diff: abc"

suite "diff target: a whole-commit document's sections":
  ## VCS-Panel.md, "Whole-Commit Document" (the owner's 2026-10-23 decision on
  ## #753): a target naming several files opens as one document whose
  ## sections each load one file.

  test "only a commit with no file named is a whole-commit target":
    check isWholeCommitTarget("commit:abc123")
    check not isWholeCommitTarget("commit:abc123:src/main.nim")
    check not isWholeCommitTarget("file:src/main.nim")
    check not isWholeCommitTarget("agent-diff:msg-7")
    check not isWholeCommitTarget("Working Tree")

  test "a commit's section asks git for its own file":
    let section = diffSectionTarget("commit:abc123", "src/main.nim")
    check section.target == "commit:abc123:src/main.nim"
    check section.onlyPath == ""
    # ... which is the target the per-file button opens, so the section and
    # a tab of its own show the same diff.
    check diffGitPlan(section.target).args ==
      @["diff-tree", "-p", "--no-commit-id", "--root", "abc123", "--",
        "src/main.nim"]

  test "a target with no per-file form is loaded whole and narrowed":
    let section = diffSectionTarget("agent-diff:msg-7", "lib/a.nim")
    check section.target == "agent-diff:msg-7"
    check section.onlyPath == "lib/a.nim"
