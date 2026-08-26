## Path identity between a review dataset and an open editor tab.
##
## A review dataset addresses files by their path **inside the reviewed
## repository** — `DeepReviewFileData.path` is `src/main.nr`, never
## `/home/you/scale_sum/src/main.nr`.  Both collectors write it that way
## (`db-backend/src/deepreview/collector.rs`, and the native exporter's
## `json_export.rs`), and they have to: a dataset is a file that gets attached
## to a ticket and opened on another machine, where no absolute path from the
## collecting machine means anything.
##
## Editor tabs, on the other hand, are addressed by whatever path opened them.
## `ct review` opens them by the dataset path, so the two are equal; but a
## review started over a *live* trace diff (`ui/vcs.startReviewForTraceDiff`)
## or from an agent session (`ui/agentic_session_launcher`) opens the debugger's
## own absolute paths, and a tab the user opened by hand can be absolute too.
##
## So "is this tab the dataset's file?" is not `==`.  It is `==` **or** "the
## tab path ends with the dataset path at a component boundary", and that is
## the single rule this module holds so that the two overlays that ask it
## (`ui/editor.deepReviewDiffStyleLines` for §5.1's diff highlights and
## `ui/editor.reviewFlowStyleLines` for §5.3's flow overlay) and the index
## process that serves the file's text (`index/config.open`) cannot answer it
## differently.  They did answer it differently — both overlays compared
## `file.path == self.path` with a relative left side and an absolute right
## side, which is never true, so Full Files mode drew nothing at all.
##
## Reference: `codetracer-specs/DeepReview/DeepReview-GUI.md` §5.1, §5.3.

import std/strutils

func normalizeReviewPath*(path: string): string =
  ## Separator-normalized form used for every comparison here.
  ##
  ## Windows datasets and POSIX datasets must compare equal against a tab path
  ## produced on either platform, so `\` folds to `/`.  Nothing else is
  ## rewritten: `..` and symlinks are deliberately NOT resolved, because doing
  ## so needs a filesystem, and this module must run in the renderer, in the
  ## index process and in a headless test with no disk.
  path.replace('\\', '/')

func isAbsoluteReviewPath*(path: string): bool =
  ## POSIX root, UNC/backslash root, or a Windows drive letter.
  ##
  ## Shares the definition with `trace_source_paths.isAbsoluteTraceSourcePath`
  ## rather than calling it, because that module is about trace payloads and
  ## importing it here would couple a review to trace storage.
  if path.len > 0 and (path[0] == '/' or path[0] == '\\'):
    return true
  path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')

func reviewPathsIdentifySameFile*(datasetPath, tabPath: string): bool =
  ## Does `tabPath` name the file the dataset calls `datasetPath`?
  ##
  ## Two ways to be true, and only two:
  ##
  ## 1. the normalized paths are equal — the `ct review` case, where the tab
  ##    was opened by the dataset path itself;
  ## 2. `tabPath` is absolute, `datasetPath` is relative, and `tabPath` ends
  ##    with `/` & `datasetPath` — the live-trace-diff case, where the
  ##    debugger opened `/home/you/scale_sum/src/main.nr` for the dataset's
  ##    `src/main.nr`.
  ##
  ## The leading `/` in rule 2 is what makes it a *component* suffix rather
  ## than a string suffix: without it `main.nr` would claim
  ## `/repo/src/domain.nr`, and a review would paint one file's diff onto
  ## another's lines — a wrong answer that looks exactly like a right one.
  ##
  ## Two absolute paths must match exactly.  A relative tab path is never
  ## allowed to claim an absolute dataset path either: a relative path is
  ## meaningless without the working directory that resolves it, and guessing
  ## that directory is what this whole module exists to avoid.
  if datasetPath.len == 0 or tabPath.len == 0:
    return false
  let dataset = normalizeReviewPath(datasetPath)
  let tab = normalizeReviewPath(tabPath)
  if dataset == tab:
    return true
  if isAbsoluteReviewPath(dataset) or not isAbsoluteReviewPath(tab):
    return false
  tab.len > dataset.len + 1 and tab.endsWith("/" & dataset)

func reviewFileIndexForPath*(datasetPaths: openArray[string];
                             tabPath: string): int =
  ## Index into `datasetPaths` of the file `tabPath` names, or -1.
  ##
  ## When more than one dataset entry matches — possible only through rule 2,
  ## e.g. `main.nr` and `src/main.nr` both suffixing `/repo/src/main.nr` — the
  ## **longest** dataset path wins.  It is the more specific claim, and
  ## preferring it makes the answer independent of the order the collector
  ## happened to write the files in.  Returning the first match instead would
  ## make a review's decorations depend on dataset ordering, which is exactly
  ## the class of bug that is invisible until a user has the unlucky repo.
  result = -1
  var bestLen = -1
  for i, candidate in datasetPaths:
    if reviewPathsIdentifySameFile(candidate, tabPath):
      let candidateLen = normalizeReviewPath(candidate).len
      if candidateLen > bestLen:
        bestLen = candidateLen
        result = i
