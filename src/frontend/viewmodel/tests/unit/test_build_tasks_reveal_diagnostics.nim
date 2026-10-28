## test_build_tasks_reveal_diagnostics.nim — the shared rules behind build
## tasks, the task picker and the `:build` commands (Build-Output-Pane.md
## §3.6, §3.11, §3.12, §5.2), the Build Output pane's reveal and dismissal
## (§3.8, §5.1) and a build's diagnostics in the editor (§3.9), which the
## desktop, the terminal and the GPUI window all apply.
##
## LANE: `vm-unit`, `vm-unit-js` and `vm-unit-wasm`, by the directory glob.
##
## Asserted:
##
##   * THE TASK FILE (`build_tasks.parseBuildTasks`): §3.6's example read
##     whole; quoting, comments and `cwd`; every malformed line reported with
##     its line and its task left out; the default task's three rules; §5.2's
##     inferred task; where a task runs;
##   * THE GRAMMAR (`parseBuildVerb`): `:build`, `:build <command>`,
##     `:build:`, `:build: <task>`, the pane's four words;
##   * THE PICKER: the omnibox's `omBuildTask` mode on `BuildTaskQuery` lists
##     the default task first and the pane's words after, and ranks a typed
##     name;
##   * ACTING (`runBuildVerb` / `runBuildChoice`) through a host — on the
##     native backend the host RUNS THE COMMAND with the real `gcc` on the
##     PLAT-56 project (`build_fixtures/plat56_c_build`), in the task's
##     working directory, into a real `BuildVM`;
##   * `problemMatcher: none` makes no Problems row;
##   * THE REVEAL RULE (`build_auto_reveal`) over a real `BuildVM` fed a real
##     failing, warning and clean build: reveal on start, reveal Problems on
##     failure, dismiss two seconds after a clean success, not after a warning,
##     not after the user touched the pane, not when a new build started;
##     the settings read from a configuration's text;
##   * THE EDITOR'S MARKS (`editor_diagnostics`) from the Problems pane's
##     `ErrorsVM` filled by the real failing build: the spans (the word at the
##     compiler's column; byte columns in a line with multibyte text), the
##     gutter's most severe icon, the hover text, the path match, and that a
##     new build clears them.
##
## NO MOCKS. The one stand-in is the `BuildTaskHost`'s closures, which are the
## seam each front-end installs (its runner, its pane); on the native backend
## the `start` closure runs the real compiler with `execCmdEx` and feeds what
## it wrote into a real `BuildVM` — capturing the seam's arguments is observing
## the module's output, not replacing a collaborator. The JavaScript backend
## cannot start a process, so there it reads the same build's recorded
## transcript (`Plat56FailTranscript`), which the native run asserts the
## compiler still writes.

import std/[strutils, unittest]

import isonim/core/[owner, signals, computation]

import ../../store/types
import ../../viewmodels/build_vm
import ../../viewmodels/errors_vm
import ../../viewmodels/omnibar_vm
import ../../viewmodels/build_tasks
import ../../viewmodels/build_auto_reveal
import ../../viewmodels/editor_diagnostics
import ./build_fixtures/plat56_c_build

when not defined(js):
  import std/[os, osproc]

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

const ExpectedAssertions = when defined(js): 138 else: 140

const SpecExample = """# In project config or .codetracer/build.yaml
tasks:
  default:
    command: "nim c --debugger:native -o:./build/app src/main.nim"
    problemMatcher: nim
    group: build

  test:
    command: "nim c -r tests/test_all.nim"
    problemMatcher: nim
    group: test

  clean:
    command: "rm -rf ./build"
    group: none
"""

const CleanCommand = "gcc -fdiagnostics-color=always -c src/ok.c -o /dev/null"
  ## `src/ok.c` without `-Wall`: a success with no warning.

proc transcriptOf(command: string): tuple[lines: seq[string]; code: int] =
  ## What `command` writes to stderr, line by line, and its exit code — the
  ## real compiler's on the native backend, the recorded one under JS.
  when defined(js):
    if command == Plat56FailCommand: (Plat56FailTranscript, 1)
    elif command == Plat56PassCommand: (Plat56PassTranscript, 0)
    else: (newSeq[string](), 0)
  else:
    discard

when not defined(js):
  var projectDir = writePlat56Project("ct-build-tasks-")

  proc runIn(dir, command: string): tuple[lines: seq[string]; code: int] =
    let (output, code) = execCmdEx("cd " & quoteShell(dir) & " && " & command &
                                   " 2>&1 1>/dev/null")
    var lines = output.splitLines
    if lines.len > 0 and lines[^1].len == 0:
      lines.setLen(lines.len - 1)
    (lines, code)
else:
  let projectDir = "/project"

  proc runIn(dir, command: string): tuple[lines: seq[string]; code: int] =
    transcriptOf(command)

proc newHostFor(vm: BuildVM; errs: ErrorsVM; log: ref seq[string]): BuildTaskHost =
  ## The front-end's seam: `start` runs the command (for real, natively) into
  ## the BuildVM and the Problems pane, as the hosts do.
  result.projectDir = projectDir
  result.start = proc(command, dir, task, matcher: string): string =
    log[].add "start " & command & " @ " & dir & " [" & task & "]"
    vm.beginBuild(command, 0.0, taskName = task, problemMatcher = matcher)
    errs.clearProblems()
    let (lines, code) = runIn(dir, command)
    for raw in lines:
      let read = vm.feedOutput(raw, isStdout = false)
      if read.fed.problem:
        errs.appendProblem(read.fed.row)
    vm.finishBuild(code, 400.0)
    ""
  result.stop = proc(): string =
    log[].add "stop"
    "cancelling build …"
  result.clear = proc(): string =
    log[].add "clear"
    vm.clearOutput()
    ""
  result.showHistory = proc(): string =
    log[].add "history"
    ""
  result.openPicker = proc(): string =
    log[].add "picker"
    ""

suite "the task file":

  test "§3.6's example, read whole":
    let c = parseBuildTasks(SpecExample)
    ck c.problems.len == 0
    ck c.tasks.len == 3
    ck c.tasks[0].name == "default"
    ck c.tasks[0].command == "nim c --debugger:native -o:./build/app src/main.nim"
    ck c.tasks[0].problemMatcher == "nim"
    ck c.tasks[1].group == btgTest
    ck c.tasks[2].group == btgNone
    ck c.tasks[2].problemMatcher == ""
    ck c.tasks[1].line == 8
    # The task named `default` is the default.
    ck c.defaultTask.found
    ck c.defaultTask.task.name == "default"

  test "quoting, comments, cwd and the explicit default":
    let c = parseBuildTasks("""tasks:   # the tasks
  app:
    command: 'make "all" it''s' # a comment
    cwd: packages/app
  lib:
    command: "echo \"a # b\""
    default: true
""")
    ck c.problems.len == 0
    ck c.tasks.len == 2
    ck c.tasks[0].command == "make \"all\" it's"
    ck c.tasks[1].command == "echo \"a # b\""
    ck c.defaultTask.task.name == "lib"
    ck c.tasks[0].workingDirectoryOf("/p") == "/p/packages/app"
    ck c.tasks[1].workingDirectoryOf("/p") == "/p"
    ck c.tasks[0].workingDirectoryOf("/p/") == "/p/packages/app"

  test "every malformed line is reported, and its task left out":
    let c = parseBuildTasks("""tasks:
  nocommand:
    group: build
  badmatcher:
    command: make
    problemMatcher: cobol
  badkey:
    command: make
    colour: red
  badgroup:
    command: make
    group: deploy
  good:
    command: make
  good:
    command: make again
	tabbed: x
settings:
  x: 1
""")
    ck c.tasks.len == 1
    ck c.tasks[0].name == "good"
    ck c.tasks[0].command == "make"
    checkpoint(c.problems.join(" | "))
    ck c.problems.len == 7
    # In the order they were met (a task's missing command when it ends).
    ck c.problems[0] == ".codetracer/build.yaml:2: task 'nocommand' has no command"
    ck c.problems[1] == ".codetracer/build.yaml:6: unknown problemMatcher " &
      "'cobol' (one of nim, gcc, clang, rust, go, python, typescript, noir, " &
      "generic, none)"
    ck c.problems[2].startsWith(".codetracer/build.yaml:9: unknown key 'colour'")
    ck c.problems[3] == ".codetracer/build.yaml:12: unknown group 'deploy' " &
      "(build, test or none)"
    ck c.problems[4] == ".codetracer/build.yaml:15: task 'good' is declared twice"
    ck c.problems[5] == ".codetracer/build.yaml:17: indent with spaces, not tabs"
    ck c.problems[6].startsWith(".codetracer/build.yaml:18: unknown key 'settings'")
    ck pickerNote(c).startsWith(".codetracer/build.yaml:2:")

  test "the default task: marked, named, or the only build task":
    var c = parseBuildTasks("tasks:\n  a:\n    command: x\n  b:\n    command: y\n    group: test\n")
    ck c.defaultTask.found
    ck c.defaultTask.task.name == "a"
    c = parseBuildTasks("tasks:\n  a:\n    command: x\n  b:\n    command: y\n")
    ck not c.defaultTask.found
    c = parseBuildTasks("tasks:\n  a:\n    command: x\n    default: true\n  b:\n    command: y\n    default: true\n")
    ck c.defaultTask.task.name == "a"
    ck c.problems == @[".codetracer/build.yaml: 2 tasks say `default: true`; " &
                       "the first is the default"]

  test "§5.2: no file, and the session's own build command":
    let c = loadBuildTasks("", fileFound = false,
                           inferredCommand = "  make app ")
    ck c.inferred
    ck c.tasks.len == 1
    ck c.defaultTask.task.command == "make app"
    ck loadBuildTasks("", false, "").tasks.len == 0
    ck pickerNote(loadBuildTasks("", false, "")) == NoBuildTasksText
    # A file, even an empty one, is the project's word: nothing is inferred.
    ck loadBuildTasks("", true, "make app").tasks.len == 0

suite "the grammar":

  test "`:build`, `:build <command>`, `:build:` and its words":
    ck parseBuildVerb(":build").kind == bvkRunDefault
    ck parseBuildVerb("build  ").kind == bvkRunDefault
    ck parseBuildVerb(":build make all") == BuildVerb(kind: bvkRunCommand,
                                                      argument: "make all")
    ck parseBuildVerb(":build:").kind == bvkPick
    ck parseBuildVerb(":build: tasks").kind == bvkPick
    ck parseBuildVerb(":build: stop").kind == bvkStop
    ck parseBuildVerb(":build:clear").kind == bvkClear
    ck parseBuildVerb(":build: history").kind == bvkHistory
    ck parseBuildVerb(":build: test") == BuildVerb(kind: bvkRunTask,
                                                   argument: "test")
    ck parseBuildVerb(":builder").kind == bvkNone
    ck parseBuildVerb(":cancel").kind == bvkNone
    ck classifyOmnibarQuery(":build: te") == (omBuildTask, "te")
    ck classifyOmnibarQuery(":build make").mode == omCommand

suite "the picker":

  test "the default task first, the pane's words after, a typed name ranked":
    let c = parseBuildTasks(SpecExample.replace("    group: test",
                                                "    group: test\n    default: true"))
    let entries = buildTaskEntries(c)
    var labels: seq[string]
    for e in entries: labels.add e.label
    ck labels == @["test", "default", "clean", "stop", "clear", "history"]
    ck entries[0].target == "task:test"
    ck entries[0].detail == "nim c -r tests/test_all.nim  (default, test, matcher: nim)"
    ck entries[3].detail == "Stop the running build"
    let om = newOmnibarVM()
    om.setIndex(@[OmnibarEntry(kind: omFile, label: "test.nim", target: "test.nim")])
    om.setBuildTasks(entries)
    om.open(BuildTaskQuery)
    ck om.mode == omBuildTask
    ck om.resultLabels == labels
    ck om.selectedResult.entry.target == "task:test"
    om.typeText("cle")
    ck om.resultLabels[0] == "clean"
    om.close()
    ck om.buildTasks.len == 6

suite "acting":

  test "a task, the default, a free command, the words — through the host":
    createRoot proc(dispose: proc()) =
      let vm = createBuildVM(nil)
      let errs = createErrorsVM(nil)
      let log = new seq[string]
      let host = newHostFor(vm, errs, log)
      let c = parseBuildTasks("tasks:\n  fail:\n    command: \"" &
        Plat56FailCommand & "\"\n  pass:\n    command: \"" &
        Plat56PassCommand & "\"\n    default: true\n  quiet:\n    command: \"" &
        Plat56FailCommand & "\"\n    problemMatcher: none\n  sub:\n    command: \"" &
        Plat56PassCommand & "\"\n    cwd: src\n")
      ck c.problems.len == 0
      # A named task: the real failing build, in the project folder.
      ck runBuildVerb(host, c, parseBuildVerb(":build: fail")) ==
        "running task fail: " & Plat56FailCommand
      ck log[^1] == "start " & Plat56FailCommand & " @ " & projectDir & " [fail]"
      ck vm.status.val == bsFailed
      ck vm.taskName.val == "fail"
      ck vm.problems.val.len == 4
      ck errs.problems.val.len == 4
      when not defined(js):
        # THE REAL COMPILER STILL WRITES THE RECORDED TRANSCRIPT.
        var texts: seq[string]
        for l in vm.output.val: texts.add l.text
        var expected: seq[string]
        var r: BuildLineReader
        for raw in Plat56FailTranscript: expected.add r.read(raw, false).line.text
        ck texts == expected
      else:
        ck vm.output.val.len == 15
      # `:build` runs the default.
      ck runBuildVerb(host, c, parseBuildVerb(":build")) ==
        "running task pass: " & Plat56PassCommand
      ck vm.status.val == bsSucceeded
      ck vm.problems.val.len == 1
      # `problemMatcher: none`: the build's lines, no Problems row.
      discard runBuildVerb(host, c, parseBuildVerb(":build: quiet"))
      ck vm.status.val == bsFailed
      ck vm.output.val.len > 0
      ck vm.problems.val.len == 0
      ck errs.problems.val.len == 0
      # A task's `cwd`: run there (a relative path is the build's own).
      discard runBuildVerb(host, c, parseBuildVerb(":build: sub"))
      ck log[^1].endsWith(" @ " & projectDir & "/src [sub]")
      # A free command, as typed.
      ck runBuildVerb(host, c, parseBuildVerb(":build " & Plat56PassCommand)) ==
        "running " & Plat56PassCommand
      ck log[^1] == "start " & Plat56PassCommand & " @ " & projectDir & " []"
      # An unknown task names the ones there are.
      ck runBuildVerb(host, c, parseBuildVerb(":build: deploy")) ==
        "no build task 'deploy' (fail, pass, quiet, sub)"
      # The words.
      ck runBuildVerb(host, c, parseBuildVerb(":build: stop")) ==
        "nothing is running"
      var running = host
      running.running = true
      ck runBuildVerb(running, c, parseBuildVerb(":build: stop")) ==
        "cancelling build …"
      ck runBuildVerb(running, c, parseBuildVerb(":build: pass")) ==
        BuildAlreadyRunningText
      ck runBuildVerb(host, c, parseBuildVerb(":build: clear")) == ""
      ck vm.status.val == bsIdle
      discard runBuildVerb(host, c, parseBuildVerb(":build: history"))
      discard runBuildVerb(host, c, parseBuildVerb(":build: tasks"))
      ck log[^2 .. ^1] == @["history", "picker"]
      # A picker choice is the same act.
      ck runBuildChoice(host, c, buildTaskEntries(c)[0]) ==
        "running task pass: " & Plat56PassCommand
      # No default and several tasks: `:build` opens the picker.
      let two = parseBuildTasks("tasks:\n  a:\n    command: x\n  b:\n    command: y\n")
      discard runBuildVerb(host, two, parseBuildVerb(":build"))
      ck log[^1] == "picker"
      ck runBuildVerb(host, BuildTaskConfig(), parseBuildVerb(":build")) ==
        NoBuildTasksText
      dispose()

  when not defined(js):
    test "the project's file, read from disk":
      createDir(projectDir / ".codetracer")
      writeFile(projectDir / BuildTasksFile,
                "tasks:\n  default:\n    command: \"" & Plat56PassCommand & "\"\n")
      let c = loadBuildTasks(readFile(projectDir / BuildTasksFile),
                             fileExists(projectDir / BuildTasksFile))
      ck c.source == BuildTasksFile
      ck c.defaultTask.task.command == Plat56PassCommand

suite "the reveal rule":

  test "start, failure, clean success, a warning, a touch, a new build":
    createRoot proc(dispose: proc()) =
      let vm = createBuildVM(nil)
      let errs = createErrorsVM(nil)
      let log = new seq[string]
      let host = newHostFor(vm, errs, log)
      var a = initBuildAutoReveal()
      proc see(a: var BuildAutoReveal; now: float): BuildRevealStep =
        a.observe(vm.number.val, vm.status.val, errs.errorCount.val,
                  errs.warningCount.val, now)
      ck a.see(0.0) == brsNone
      # A build starts: reveal; it fails: reveal Problems.
      vm.beginBuild(Plat56FailCommand, 0.0)
      ck a.see(10.0) == brsReveal
      ck a.see(20.0) == brsNone
      for raw in runIn(projectDir, Plat56FailCommand).lines:
        let read = vm.feedOutput(raw, false)
        if read.fed.problem: errs.appendProblem(read.fed.row)
      vm.finishBuild(1, 30.0)
      ck a.see(40.0) == brsRevealProblems
      ck not a.pending
      # A success WITH A WARNING: revealed, never dismissed.
      discard runBuildVerb(host, parseBuildTasks("tasks:\n  p:\n    command: \"" &
        Plat56PassCommand & "\"\n"), parseBuildVerb(":build"))
      ck errs.warningCount.val == 1
      ck a.see(100.0) == brsReveal   # started and ended between two looks
      ck not a.pending
      # A CLEAN success: dismissed two seconds later, once.
      discard runBuildVerb(host, BuildTaskConfig(), parseBuildVerb(
        ":build " & CleanCommand))
      ck vm.status.val == bsSucceeded
      ck errs.totalCount.val == 0
      ck a.see(1000.0) == brsReveal
      ck a.pending
      ck a.due(2999.0) == brsNone
      ck a.due(3000.0) == brsDismiss
      ck a.due(3001.0) == brsNone
      # Touched in between: stays.
      discard runBuildVerb(host, BuildTaskConfig(), parseBuildVerb(
        ":build " & CleanCommand))
      discard a.see(5000.0)
      a.interact()
      ck a.due(9000.0) == brsNone
      # A new build cancels the last one's dismissal.
      discard runBuildVerb(host, BuildTaskConfig(), parseBuildVerb(
        ":build " & CleanCommand))
      discard a.see(10000.0)
      vm.beginBuild(Plat56FailCommand, 10500.0)
      ck a.see(10500.0) == brsReveal
      ck a.due(13000.0) == brsNone
      # A cancelled build leaves the pane as it is.
      vm.finishBuild(143, 11000.0, cancelled = true)
      ck a.see(11000.0) == brsNone
      # Off: no step at all.
      var off = initBuildAutoReveal(BuildRevealSetting(autoReveal: false,
                                                       autoDismissOnSuccess: false))
      vm.beginBuild(CleanCommand, 0.0)
      ck off.observe(vm.number.val, vm.status.val, 0, 0, 0.0) == brsNone
      vm.finishBuild(0, 10.0)
      ck off.observe(vm.number.val, vm.status.val, 0, 0, 10.0) == brsNone
      ck not off.pending
      dispose()

  test "the settings, from a configuration's text":
    let d = buildRevealSettingOfConfigText("theme: x\n")
    ck d.setting == DefaultBuildRevealSetting
    let s = buildRevealSettingOfConfigText(
      "build:\n  autoReveal: false # off\n  autoDismissOnSuccess: maybe\n" &
      "window:\n  autoReveal: true\n")
    ck not s.setting.autoReveal
    ck s.setting.autoDismissOnSuccess
    ck s.problems == @["build.autoDismissOnSuccess is true or false, not 'maybe'"]

suite "the editor's marks":

  test "the failing build's diagnostics in src/main.c":
    createRoot proc(dispose: proc()) =
      let vm = createBuildVM(nil)
      let errs = createErrorsVM(nil)
      let log = new seq[string]
      let host = newHostFor(vm, errs, log)
      discard runBuildVerb(host, BuildTaskConfig(),
                           parseBuildVerb(":build " & Plat56FailCommand))
      let lines = Plat56MainC.splitLines
      let text = proc(line: int): string =
        if line >= 1 and line <= lines.len: lines[line - 1] else: ""
      var d = diagnosticsForFile(errs.problems.val, projectDir,
                                 projectDir & "/src/main.c", projectDir, text)
      var spans: seq[string]
      for x in d:
        spans.add $x.line & ":" & $x.fromColumn & "-" & $x.toColumn & " " &
                  severityWord(x.severity)
      checkpoint(spans.join(" | "))
      # 5:17 is past `return v * 2`'s end: its last character; 4:9 the word
      # `unused`; 10:12 `undefined_name` (the error and the note).
      ck spans == @["5:15-16 error", "4:8-14 warning", "10:11-25 error",
                    "10:11-25 info"]
      ck d[2].problemIndex == 2
      # The same file named relative to the project.
      ck diagnosticsForFile(errs.problems.val, projectDir, "src/main.c",
                            projectDir, text).len == 4
      ck diagnosticsForFile(errs.problems.val, projectDir, "src/ok.c",
                            projectDir, text).len == 0
      # The gutter: the most severe; the hover: every one, most severe first.
      ck gutterSeverity(d, 10) == blsError
      ck gutterIcon(d, 4) == severityIcon(blsWarning)
      ck gutterIcon(d, 6) == ""
      # As gcc worded them (its message carries its word: `note:`, which the
      # row calls info).
      ck hoverText(d, 10) ==
        "error: ‘undefined_name’ undeclared (first use in this function)\n" &
        "note: each undeclared identifier is reported only once for each " &
        "function it appears in"
      ck hoverText(@[EditorDiagnostic(line: 1, severity: blsWarning,
                                      message: "unused")], 1) == "warning: unused"
      ck diagnosticLines(d) == @[4, 5, 10]
      # A NEW BUILD CLEARS THEM (the Problems pane is cleared when it starts).
      discard runBuildVerb(host, BuildTaskConfig(),
                           parseBuildVerb(":build " & CleanCommand))
      d = diagnosticsForFile(errs.problems.val, projectDir,
                             projectDir & "/src/main.c", projectDir, text)
      ck d.len == 0
      dispose()

  test "byte columns over multibyte text; no column; paths":
    # `é` is two bytes: `nam` starts at byte column 14, character 12.
    let line = "  s = \"é\" + nam;"
    ck diagnosticSpan(line, 14) == (12, 15)
    ck charColumnOfByte(line, 14) == 12
    ck diagnosticSpan(line, 0) == (2, 16)
    ck diagnosticSpan("", 3) == (0, 1)
    ck diagnosticSpan("ab", 40) == (1, 2)
    ck diagnosticSpan("a + b", 3) == (2, 3)
    ck sameFile("./src/../src/main.c", "/p", "/p/src/main.c", "/q")
    ck sameFile("/p/src/main.c", "/elsewhere", "src/main.c", "/p")
    ck not sameFile("main.c", "/p", "/p/src/main.c", "/p")

when not defined(js):
  removeDir(projectDir)

suite "the count":
  test "every assertion ran":
    checkpoint("asserted: " & $asserted)
    check asserted == ExpectedAssertions
