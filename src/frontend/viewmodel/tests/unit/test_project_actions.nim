## test_project_actions.nim
##
## VN-M3 deliverable 1: "Verno invoked as a **project-defined action**, using
## the mechanism the IDE already surfaces rather than a bespoke one" —
## `Noir-Studio.md` §9.3.
##
## §9.3 names the mechanism and then constrains it twice, and both constraints
## are properties rather than prose:
##
##   "**The shape is `tasks.json` and `package.json` scripts** … which requires
##    the studio to define no schema of its own — the project declares its
##    actions or it does not."
##
##   "**Actions are the project's**, not ours. We surface what a project
##    declares and invent no manifest of our own."
##
## So the suite below checks what is read, and — at least as importantly —
## that nothing is invented: no default action, no guessed command line, and
## no silently dropped declaration.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_project_actions.nim

import std/[options, strutils, unittest]

import ../../store/types
import ../../viewmodels/project_actions

const ExampleTasksJson =
  staticRead("../../../../../test-programs/noir_verification/.vscode/tasks.json")

suite "VN-M3 project actions are read from the two forms §9.3 names":

  test "a real tasks.json in this repository is read into runnable actions":
    let declared = parseTasksJson(ExampleTasksJson)
    check declared.problems.len == 0
    check declared.actions.len == 3

    let verify = declared.actions[0]
    check verify.id == "tasks.json:Verify with Verno"
    check verify.label == "Verify with Verno"
    check verify.command == "verno"
    check verify.args == @["--program-dir", ".", "formal-verify", "--", "--rlimit", "60"]
    check verify.group == pagTest
    check not verify.isBackground
    check verify.detail.len > 0
    check verify.source == pasTasksJson
    check commandLine(verify) == "verno --program-dir . formal-verify -- --rlimit 60"

    check declared.actions[1].isBackground

  test "package.json scripts are read, and kept as whole shell lines":
    # An npm script is a shell string. Splitting `verno fv && echo ok` on
    # whitespace would produce a command the project did not write.
    let declared = parsePackageScripts("""
      {"name": "demo",
       "scripts": {"verify": "verno --program-dir . formal-verify && echo ok"}}
    """)
    check declared.problems.len == 0
    check declared.actions.len == 1
    check declared.actions[0].source == pasPackageJson
    check declared.actions[0].label == "verify"
    check declared.actions[0].command ==
      "verno --program-dir . formal-verify && echo ok"
    check declared.actions[0].args.len == 0

  test "both forms are collected, and neither shadows the other":
    let both = collectProjectActions(
      """{"tasks": [{"label": "verify", "command": "verno", "args": []}]}""",
      """{"scripts": {"verify": "npm run something-else"}}""")
    check both.actions.len == 2
    check both.actions[0].id == "tasks.json:verify"
    check both.actions[1].id == "package.json:verify"
    check actionById(both, "package.json:verify").isSome
    check actionById(both, "nonexistent").isNone

  test "VS Code's object form of `group` is read as well as the string form":
    let declared = parseTasksJson("""
      {"tasks": [{"label": "t", "command": "c",
                  "group": {"kind": "test", "isDefault": true}}]}""")
    check declared.actions.len == 1
    check declared.actions[0].group == pagTest

  test "`options.cwd` is carried, unresolved":
    let declared = parseTasksJson("""
      {"tasks": [{"label": "t", "command": "c", "options": {"cwd": "packages/a"}}]}""")
    check declared.actions[0].cwd == "packages/a"

suite "VN-M3 nothing is invented and nothing is silently dropped":

  test "a project that declares nothing gets nothing":
    check collectProjectActions("", "").actions.len == 0
    check parseTasksJson("{}").actions.len == 0
    check parsePackageScripts("""{"name": "x"}""").actions.len == 0

  test "an unreadable declaration is reported rather than skipped":
    # The worst bug shape available here is an action the developer can see in
    # their own editor and cannot find in ours, with nothing saying why.
    let declared = parseTasksJson("""
      {"tasks": [
        {"command": "verno"},
        {"label": "no command"},
        {"label": "objectified args", "command": "verno",
         "args": [{"value": "-x", "quoting": "escape"}]},
        {"label": "fine", "command": "verno", "args": ["fv"]}
      ]}""")
    check declared.actions.len == 1
    check declared.actions[0].label == "fine"
    check declared.problems.len == 3
    check declared.problems[0].contains("no `label`")
    check declared.problems[1].contains("no `command`")
    check declared.problems[2].contains("cannot read verbatim")

  test "invalid JSON is a stated problem, not an empty action list":
    let broken = parseTasksJson("{ this is not json")
    check broken.actions.len == 0
    check broken.problems.len == 1
    check broken.problems[0].contains("not valid JSON")

    let brokenPackage = parsePackageScripts("{ nope")
    check brokenPackage.actions.len == 0
    check brokenPackage.problems.len == 1

  test "unknown VS Code fields are ignored without complaint":
    # CodeTracer does not implement VS Code's task semantics. Ignoring
    # `dependsOn` quietly is right; *reporting* it as a problem would tell the
    # developer their file is wrong when it is not.
    let declared = parseTasksJson("""
      {"tasks": [{"label": "t", "command": "c",
                  "dependsOn": ["other"], "problemMatcher": ["$tsc"],
                  "presentation": {"reveal": "always"}}]}""")
    check declared.actions.len == 1
    check declared.problems.len == 0

  test "arguments are preserved verbatim, in order, including empty ones":
    let declared = parseTasksJson("""
      {"tasks": [{"label": "t", "command": "verno",
                  "args": ["--program-dir", "a b", "", "--rlimit", "60"]}]}""")
    check declared.actions[0].args == @["--program-dir", "a b", "", "--rlimit", "60"]
    # Display quoting only, and only where it is needed to stay readable.
    check commandLine(declared.actions[0]) ==
      "verno --program-dir \"a b\" \"\" --rlimit 60"

suite "VN-M3 declared actions are reachable from the omnibar":
  ## §9.3: "project-defined actions reachable from the omnibar". The palette's
  ## own vocabulary is the compiled-in `ClientAction` enum, so a runtime-read
  ## action needs a row kind of its own — `cprkProjectAction` — rather than
  ## being disguised as one of the six legacy query kinds.

  test "each declared action becomes one palette row, saying what it will run":
    let entries = paletteEntries(parseTasksJson(ExampleTasksJson))
    check entries.len == 3
    check entries[0].kind == cprkProjectAction
    check entries[0].level == cpnlInfo
    # The label is the developer's, unrewritten...
    check entries[0].value == "Verify with Verno"
    # ...and the row says what picking it will do, before it does it.
    check entries[0].snippetSource ==
      "verno --program-dir . formal-verify -- --rlimit 60"

  test "the query filters over label and command line, in declaration order":
    let declared = parseTasksJson(ExampleTasksJson)
    check paletteEntries(declared, "verno").len == 2
    check paletteEntries(declared, "nargo").len == 1
    check paletteEntries(declared, "nargo")[0].value == "Record with nargo"
    # Matching the command line, not just the label: a developer who remembers
    # the flag and not the name still finds it.
    check paletteEntries(declared, "rlimit 600").len == 1
    check paletteEntries(declared, "no such thing").len == 0
    # Declaration order — the project's, and therefore predictable.
    check paletteEntries(declared)[2].value == "Record with nargo"

  test "an unreadable declaration surfaces as a warning row, where it was looked for":
    let declared = parseTasksJson("""{"tasks": [{"command": "verno"}]}""")
    check paletteEntries(declared).len == 0
    let problems = paletteProblemEntries(declared)
    check problems.len == 1
    check problems[0].kind == cprkProjectAction
    check problems[0].level == cpnlWarning
    check problems[0].value.contains("no `label`")
