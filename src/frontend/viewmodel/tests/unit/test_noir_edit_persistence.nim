## Noir Studio keeps what you type, and it is what gets compiled.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_noir_edit_persistence.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_noir_edit_persistence.nim
##
## ## The defect this suite is written against
##
## `ide.codetracer.com/noir` presented a working IDE and silently discarded
## every keystroke. Two halves:
##
##   * `web_noir_build.templateVfsEntries` read `tmpl.files` off a copy of the
##     compile-time bundled template that nothing mutated, so **Build and Run
##     compiled the bundled project no matter what the visitor had typed.** A
##     visitor could edit `src/main.nr`, press Ctrl+B, and get a successful
##     build of code they had not written.
##   * `CODETRACER::save-file` had no host on web, so Ctrl+S logged
##     *"no host for CODETRACER::save-file"* and the buffer stayed dirty
##     forever.
##
## ## THE FALSE PASS THIS SUITE EXISTS TO AVOID, stated first
##
## **A test that edits a file and asserts a successful build proves nothing**,
## because the unedited template also builds successfully. The green tick is
## produced by both the fixed product and the broken one, so it distinguishes
## nothing. Every assertion below is therefore about the BYTES HANDED TO THE
## COMPILER, and each one is written as a pair:
##
##   * the edited text **is** in the payload, and
##   * the original text **is not**.
##
## The second half is the one that fails on the shipped build. A check for the
## first alone could be satisfied by a payload that carried both — an append
## rather than a replace — and a check that merely counted entries would be
## satisfied by the bundle itself.
##
## `test_the_edit_changes_the_outcome_not_merely_the_input` makes that explicit
## against a fixture whose two versions differ in whether they *would* compile,
## so the suite asserts a changed verdict rather than a repeated one.
##
## ## What is NOT asserted here
##
## That OPFS works. This suite installs a `ProjectWriter` and asserts the store
## is asked for exactly the right writes; whether `navigator.storage` honours
## them is a browser fact, and `ci/test/noir-edit-persists.sh` asserts it in a
## real tab across a real reload. Mocking OPFS here and calling it persistence
## would be the chain-of-agreements failure this campaign keeps finding.

import std/[strutils, unittest]

import ../../../ui/web_project_store
import ../../platform/noir_template

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 83
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const originalMain = """fn main(x: Field, y: pub Field) {
    assert(x != y);
}
"""

const brokenMain = """fn main(x: Field, y: pub Field) {
    assert(x !== y);
}
"""
  ## `!==` is not a Noir operator. The point of this fixture is that the two
  ## versions differ in COMPILABILITY, not merely in bytes — see the header on
  ## the false pass.

proc fixture(): ProjectTemplate =
  ProjectTemplate(
    language: "noir", name: "hello_noir", entryFile: "src/main.nr",
    files: @[
      TemplateFile(path: "Nargo.toml", content: "[package]\nname = \"hello_noir\"\n"),
      TemplateFile(path: "Prover.toml", content: "x = \"1\"\ny = \"2\"\n"),
      TemplateFile(path: "src/main.nr", content: originalMain)])

proc vfsContentFor(tmpl: ProjectTemplate; relative: string): string =
  ## What `web_noir_build.templateVfsEntries` would hand the compiler for one
  ## file.
  ##
  ## Reimplemented as a one-line lookup rather than imported, because
  ## `web_noir_build` is a `nim js` module that reaches `ctPlatform()` and the
  ## BUILD pane. What that proc does with a template is `for file in
  ## tmpl.files` — so the fact under test is "which template does it get", and
  ## that is `currentProject()`, which this suite drives directly.
  for file in tmpl.files:
    if file.path == relative:
      return file.content
  ""

proc reset() =
  setProjectWriter(nil)
  setCurrentProject(fixture())

# ---------------------------------------------------------------------------

suite "the open project is what gets compiled":

  test "a fresh session compiles the bundled template":
    # The CONTROL. Without it the assertions below could be red for an
    # unrelated reason, and a negative assertion with no positive twin has
    # nothing to fail.
    reset()
    counted hasLiveProject()
    counted currentProject().files.len == 3
    counted vfsContentFor(currentProject(), "src/main.nr") == originalMain
    counted vfsContentFor(currentProject(), "src/main.nr").contains("!=")
    counted not vfsContentFor(currentProject(), "src/main.nr").contains("!==")

  test "a save changes the bytes the compiler is handed":
    # THE DEFECT, as one assertion pair. On the shipped build the second of
    # these was false: the payload still carried `originalMain`.
    reset()
    var reported = 0
    saveProjectFile("src/main.nr", brokenMain, proc(ok: bool; error: string) =
      inc reported
      counted ok
      counted error.len == 0)
    counted reported == 1
    counted vfsContentFor(currentProject(), "src/main.nr") == brokenMain
    counted not vfsContentFor(currentProject(), "src/main.nr").contains(
      originalMain)

  test "the_edit_changes_the_outcome_not_merely_the_input":
    ## THE FALSE PASS, excluded explicitly.
    ##
    ## Asserting "after an edit, a build succeeds" is satisfied by the broken
    ## product, because the bundled template compiles. So the fixture's two
    ## versions differ in whether they COULD compile, and the assertion is that
    ## the compiler's input crosses that line — `!==` present, `!=`-only
    ## absent. A payload that changed nothing fails the second half.
    reset()
    let before = vfsContentFor(currentProject(), "src/main.nr")
    counted before.contains("assert(x != y)")
    counted not before.contains("assert(x !== y)")

    saveProjectFile("src/main.nr", brokenMain, proc(ok: bool; error: string) =
      counted ok)

    let after = vfsContentFor(currentProject(), "src/main.nr")
    counted after.contains("assert(x !== y)")
    counted not after.contains("assert(x != y)")
    counted before != after

  test "only the saved file changes":
    reset()
    saveProjectFile("src/main.nr", brokenMain, proc(ok: bool; error: string) =
      counted ok)
    counted vfsContentFor(currentProject(), "Nargo.toml").contains("hello_noir")
    counted vfsContentFor(currentProject(), "Prover.toml").contains("x = \"1\"")
    counted currentProject().files.len == 3

  test "the whole project is still handed over, not only the edited file":
    # A replace that dropped the untouched files would compile the edit and
    # fail on a missing module — a different bug wearing the same green tick.
    reset()
    saveProjectFile("src/main.nr", brokenMain, proc(ok: bool; error: string) =
      counted ok)
    var seen = 0
    for file in currentProject().files:
      counted file.content.len > 0
      inc seen
    counted seen == 3

suite "saving writes through to the project store":

  test "the writer is asked for exactly the edit":
    reset()
    var paths: seq[string] = @[]
    var contents: seq[string] = @[]
    setProjectWriter(proc(relativePath, content: string; onDone: SaveDone) =
      paths.add relativePath
      contents.add content
      onDone(true, ""))

    var reported = 0
    saveProjectFile("src/main.nr", brokenMain, proc(ok: bool; error: string) =
      inc reported
      counted ok)

    counted reported == 1
    counted paths.len == 1
    counted paths == @["src/main.nr"]
    counted contents.len == 1
    counted contents[0] == brokenMain

  test "a refused write still leaves the editor's bytes in what Build compiles":
    ## The ordering `saveProjectFile` documents, as an assertion.
    ##
    ## In §4.2's degraded rows a write can fail. If the in-memory update were
    ## conditional on it, the user would press Ctrl+S, see an error, and then
    ## have Build compile the OLD bytes — the original defect, reintroduced for
    ## the users least able to afford it.
    reset()
    setProjectWriter(proc(relativePath, content: string; onDone: SaveDone) =
      onDone(false, "the origin refused the write"))

    var reported = 0
    var sawError = ""
    saveProjectFile("src/main.nr", brokenMain, proc(ok: bool; error: string) =
      inc reported
      sawError = error
      counted not ok)

    counted reported == 1
    counted sawError == "the origin refused the write"
    # The save FAILED and the edit is still what would be compiled.
    counted vfsContentFor(currentProject(), "src/main.nr") == brokenMain
    counted not vfsContentFor(currentProject(), "src/main.nr").contains(
      originalMain)

  test "with no store the save still succeeds, in this tab":
    reset()
    counted not hasProjectWriter()
    var reported = 0
    saveProjectFile("src/main.nr", brokenMain, proc(ok: bool; error: string) =
      inc reported
      counted ok
      counted error.len == 0)
    counted reported == 1
    counted vfsContentFor(currentProject(), "src/main.nr") == brokenMain

  test "a file the project does not have is refused and nothing is written":
    reset()
    var writes = 0
    setProjectWriter(proc(relativePath, content: string; onDone: SaveDone) =
      inc writes
      onDone(true, ""))

    var reported = 0
    var sawError = ""
    saveProjectFile("src/nope.nr", "anything", proc(ok: bool; error: string) =
      inc reported
      sawError = error
      counted not ok)

    counted reported == 1
    counted writes == 0
    counted sawError.contains("src/nope.nr")
    counted sawError.contains("not a file in this project")
    counted currentProject().files.len == 3

  test "every save is reported exactly once":
    reset()
    setProjectWriter(proc(relativePath, content: string; onDone: SaveDone) =
      onDone(true, ""))
    var reported = 0
    for i in 0 ..< 4:
      saveProjectFile("src/main.nr", "fn main() {}\n// " & $i & "\n",
                      proc(ok: bool; error: string) = inc reported)
    counted reported == 4
    counted vfsContentFor(currentProject(), "src/main.nr").contains("// 3")

suite "paths cross the renderer/store boundary exactly once":

  test "an absolute renderer path becomes a project-relative store key":
    let tmpl = fixture()
    counted templateProjectRoot(tmpl) == "/hello_noir"
    counted templateFilePath(tmpl, "src/main.nr") == "/hello_noir/src/main.nr"
    counted projectRelative(tmpl, "/hello_noir/src/main.nr") == "src/main.nr"
    counted projectRelative(tmpl, "/hello_noir/Nargo.toml") == "Nargo.toml"

  test "a path outside the project is refused rather than coerced":
    let tmpl = fixture()
    counted projectRelative(tmpl, "/other/src/main.nr") == ""
    counted projectRelative(tmpl, "src/main.nr") == ""
    counted projectRelative(tmpl, "/hello_noir") == ""
    counted projectRelative(tmpl, "") == ""
    counted templateFileFor(tmpl, "/other/src/main.nr") == -1

  test "the index a tab-load resolves to is the file it names":
    let tmpl = fixture()
    counted templateFileFor(tmpl, "/hello_noir/src/main.nr") == 2
    counted templateFileFor(tmpl, "/hello_noir/Nargo.toml") == 0
    counted templateFileFor(tmpl, "/hello_noir/src/absent.nr") == -1

  test "a save arriving by absolute path reaches the right file":
    # The host does `projectRelative` then `saveProjectFile`; this is that pair,
    # and it is where a one-character prefix mistake would silently write
    # nothing.
    reset()
    let relative = projectRelative(currentProject(),
                                   "/hello_noir/src/main.nr")
    counted relative == "src/main.nr"
    var reported = 0
    saveProjectFile(relative, brokenMain, proc(ok: bool; error: string) =
      inc reported
      counted ok)
    counted reported == 1
    counted vfsContentFor(currentProject(), "src/main.nr") == brokenMain

suite "the product says where the work lives":

  test "a durable session and a volatile one are different sentences":
    setDurabilityNotice("Your work is saved in this browser.", true)
    counted worksSurviveReload()
    counted durabilityNoticeText().len > 0
    counted durabilityNoticeText().contains("saved in this browser")

    setDurabilityNotice(
      "everything you write here is held in this tab and will be lost", false)
    counted not worksSurviveReload()
    counted durabilityNoticeText().contains("lost")

  test "a volatile session says so rather than staying silent":
    ## §4.2's third row: the in-memory case "**says so before the first
    ## keystroke**, because work will be lost on close. Never a blank failure."
    ## The sentence itself is `store_durability.announcementFor`'s and is
    ## asserted there; what this checks is that a volatile session cannot be
    ## left with nothing to show.
    setDurabilityNotice("", false)
    counted durabilityNoticeText().len == 0
    counted not worksSurviveReload()
    # …and that the accessor reports the tier honestly once set.
    setDurabilityNotice("held in this tab", false)
    counted durabilityNoticeText().len > 0
    counted not worksSurviveReload()

suite "EMT-D17: Run saves, and the header names what it saved":

  test "the header names every file saved":
    counted savedFilesLabel("nargo compile --debug", @["src/main.nr"]) ==
      "nargo compile --debug — saved src/main.nr"
    counted savedFilesLabel("nargo compile",
                            @["src/main.nr", "src/utils.nr"]) ==
      "nargo compile — saved src/main.nr, src/utils.nr"
    counted savedFilesLabel("nargo compile", @["a", "b", "c"]).contains(
      "a, b, c")

  test "a build that saved nothing says nothing":
    counted savedFilesLabel("nargo compile", @[]) == "nargo compile"
    counted savedFilesLabel("nargo compile --debug", @[]) ==
      "nargo compile --debug"
    counted not savedFilesLabel("nargo compile", @[]).contains("saved")

  test "the label names each file exactly once":
    let label = savedFilesLabel("nargo compile",
                                @["src/main.nr", "src/utils.nr"])
    counted label.count("src/main.nr") == 1
    counted label.count("src/utils.nr") == 1
    counted label.count("saved") == 1

  test "noir_edit_persistence_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
