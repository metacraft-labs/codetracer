## review_source_paths_test.nim
##
## Headless unit tests for `src/common/review_source_paths.nim` — RV-11 in
## `codetracer-specs/DeepReview/Review-Command.milestones.org`.
##
## ## What broke, and why a test of a *path comparison* is worth this much
##
## DeepReview-GUI.md §5.1 requires Full Files mode to "display diff highlights
## on modified lines", and §5.3 to "show overlays wherever DeepReview data
## exists for the loaded file".  Both were implemented, both were wired to the
## right data, and neither had ever drawn a single decoration, because both
## asked "is this tab the dataset's file?" as
##
##     file.path == self.path
##
## with the dataset's repo-relative `src/main.nr` on the left and the editor
## tab's path on the right.  Measured over the book's own worked example, the
## whole of Full Files mode contributed zero: 0 `line-diff-added`,
## 0 `line-diff-modified`, and the diff tab's 8 flow lines and 36 value chips
## unchanged by opening the file.
##
## The lesson the suite below encodes is that this is not a typo-class bug.
## The two path spaces are genuinely different — a dataset is *portable*, so it
## names files relative to the repository it describes, while an editor tab is
## named by whatever opened it — and the comparison between them has real rules
## that can be got subtly wrong in ways no `==` ever reveals.  In particular
## `endsWith` alone is NOT the fix: it makes `main.nr` claim
## `/repo/src/domain.nr`, which would paint one file's diff onto another's
## lines and look entirely plausible on screen.  That case is asserted below.
##
## The last suite runs the rule against the two REAL fixtures the Playwright
## review suites launch, so the pinned behaviour is the behaviour of shipped
## dataset bytes rather than of paths invented here.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/deepreview/review_source_paths_test.nim

import std/[strutils, unittest]

import ../../../../common/review_source_paths
import lib/review_dataset_json

proc fixtureDirPath(): string {.compileTime.} =
  let p = currentSourcePath()
  var cut = p.rfind('/')
  let backslash = p.rfind('\\')
  if backslash > cut:
    cut = backslash
  p[0 .. cut] & "fixtures/"

# Read at COMPILE time so the suite also runs on the JS lane
# (`just test-vm-js`), where there is no `fopen` — the pattern every other
# headless deepreview suite already uses for these files.
const
  SampleReviewJson = staticRead(fixtureDirPath() & "sample-review.json")
  MaterializedReviewJson = staticRead(fixtureDirPath() & "materialized-review.json")

suite "a dataset path and an editor tab path identify the same file":

  test "the ct review case: the tab was opened by the dataset path itself":
    # `ui/vcs.dispatchOpenAction` opens a review's files by their dataset path,
    # so this is the equality the shipped path relies on.
    check reviewPathsIdentifySameFile("src/main.nr", "src/main.nr")
    check reviewPathsIdentifySameFile("main.nr", "main.nr")

  test "the case that was broken: a relative dataset path, an absolute tab":
    # THE defect.  A review started over a live trace diff, or from an agent
    # session, opens the debugger's own absolute paths; before RV-11 every one
    # of these answered false and the file got no overlay at all.
    check reviewPathsIdentifySameFile("src/main.nr", "/tmp/scale_sum/src/main.nr")
    check reviewPathsIdentifySameFile("src/main.rs", "/home/you/proj/src/main.rs")
    check reviewPathsIdentifySameFile("main.nr", "/tmp/scale_sum/main.nr")

  test "the suffix must fall on a component boundary":
    # `endsWith` without the separator is the plausible-looking wrong fix: it
    # makes a short dataset path claim a longer file whose name merely ends
    # the same way, and a review would then draw one file's hunks over
    # another's lines with no visible sign of it.
    check not reviewPathsIdentifySameFile("main.nr", "/repo/src/domain.nr")
    check not reviewPathsIdentifySameFile("utils.rs", "/repo/src/my_utils.rs")
    check not reviewPathsIdentifySameFile("src/main.nr", "/repo/other_src/main.nr")

  test "a relative tab path never claims an absolute dataset path":
    # A relative path means nothing without the directory that resolves it,
    # and guessing that directory is the failure this module exists to end.
    check not reviewPathsIdentifySameFile("/repo/src/main.nr", "src/main.nr")

  test "two absolute paths must match exactly":
    check reviewPathsIdentifySameFile("/repo/src/main.nr", "/repo/src/main.nr")
    check not reviewPathsIdentifySameFile("/a/src/main.nr", "/b/src/main.nr")

  test "empty paths match nothing":
    check not reviewPathsIdentifySameFile("", "/repo/src/main.nr")
    check not reviewPathsIdentifySameFile("src/main.nr", "")
    check not reviewPathsIdentifySameFile("", "")

  test "Windows separators and drive letters":
    # A dataset collected on Windows and a tab opened on Windows must compare
    # equal, and so must the mixed forms Electron produces.
    check reviewPathsIdentifySameFile("src\\main.nr", "src/main.nr")
    check reviewPathsIdentifySameFile("src/main.nr", "C:\\proj\\src\\main.nr")
    check reviewPathsIdentifySameFile("src\\main.nr", "C:/proj/src/main.nr")
    check not reviewPathsIdentifySameFile("src/main.nr", "C:\\proj\\other\\main.nr")

  test "a path is not claimed by a longer dataset path":
    check not reviewPathsIdentifySameFile("src/deep/main.nr", "/repo/src/main.nr")

suite "choosing which dataset entry an editor tab belongs to":

  test "the matching entry is found by index":
    let paths = @["src/main.rs", "src/utils.rs", "src/config.rs"]
    check reviewFileIndexForPath(paths, "/repo/src/utils.rs") == 1
    check reviewFileIndexForPath(paths, "src/config.rs") == 2

  test "no match is -1 rather than a plausible neighbour":
    let paths = @["src/main.rs", "src/utils.rs"]
    check reviewFileIndexForPath(paths, "/repo/src/other.rs") == -1
    check reviewFileIndexForPath(@[], "/repo/src/main.rs") == -1

  test "the longest dataset path wins, so the answer is order-independent":
    # Both entries suffix-match the tab.  `src/main.nr` is the more specific
    # claim and must win from either ordering — otherwise a review's overlay
    # would depend on the order the collector happened to write its files in,
    # which is invisible until somebody has the unlucky repository.
    check reviewFileIndexForPath(
      @["main.nr", "src/main.nr"], "/repo/src/main.nr") == 1
    check reviewFileIndexForPath(
      @["src/main.nr", "main.nr"], "/repo/src/main.nr") == 0

suite "against the real fixtures the review suites launch":

  test "sample-review.json: every file is found from an absolute tab path":
    let data = decodeReviewDatasetJson(SampleReviewJson)
    check data.files.len == 3
    var paths: seq[string] = @[]
    for file in data.files:
      paths.add($file.path)
    # Exactly the shape `index/config.reviewSourceLookup` and
    # `ui/editor.reviewFileForTab` build, against exactly the paths a
    # live-trace-diff review would open.
    for i, path in paths:
      check reviewFileIndexForPath(paths, "/home/you/proj/" & path) == i
      check reviewFileIndexForPath(paths, path) == i

  test "materialized-review.json: the collector's own repo-relative path":
    let data = decodeReviewDatasetJson(MaterializedReviewJson)
    check data.files.len == 1
    # The real materialized collector writes `src/main.nr` — this is the exact
    # pair the CDP measurement found scoring zero decorations.
    check $data.files[0].path == "src/main.nr"
    check reviewPathsIdentifySameFile(
      $data.files[0].path, "/tmp/scale_sum/src/main.nr")

  test "the dataset carries the text a full-file tab is served from":
    # §5.1's decorations index the file AS OF THE REVIEWED COMMIT, so the
    # dataset's own `sourceContent` is the only text whose line numbering the
    # hunks' `newLine` values are valid against.  If this were ever empty for
    # the fixtures, Full Files mode would be unservable and the three
    # Playwright tests would be testing nothing.
    let data = decodeReviewDatasetJson(SampleReviewJson)
    for file in data.files:
      check ($file.sourceContent).len > 0
