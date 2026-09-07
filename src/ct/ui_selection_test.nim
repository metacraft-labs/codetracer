## ui_selection_test.nim — PLAT-1, the DECISION.
##
## Subject: `src/ct/ui_selection.nim`, the pure half of `--ui`
## (`codetracer-specs/CLI/ct/ui-selection.md`).
##
## ## NO MOCKS, AND NOTHING TO MOCK
##
## `planUiSelection` is a function of three strings-and-a-seq: the argv, the
## environment value and the configured value. It reads no file, spawns
## nothing, and has no collaborator to stand in for — so every case below hands
## it real values and reads back the real decision. The workspace rule that
## every mock be justified in a header is satisfied vacuously here; the
## PROCESS-level half of the same milestone (`ct` really refusing, the real
## launcher really routing, `ct host` and `ct replay --ui=webui` really serving)
## lives in `src/ct/launch/ui_dispatch_test.nim`,
## `src/tests/ui_selection/test_ct_ui_resolution.nim` and
## `src/tests/ui_selection/test_webui_equivalence.nim`.
##
## ## WHAT THIS FILE IS WRITTEN AGAINST
##
## `codetracer-specs/Testing/Verification-Harness-Traps.md` §4b: where the
## membership of a set is knowable, assert the COUNT rather than its
## non-emptiness. Three sweeps here do that — every accepted value, every
## refused value, every command that must refuse the flag — because "at least
## one value was accepted" is satisfied by a table with one row in it.
##
## And the traps document's `assertX` entry: every case below asserts a
## POSITIVE fact about the plan (its kind, its argv, its message text) rather
## than only that nothing went wrong. A plan that came back `upkInProcess` with
## an empty argv would satisfy "no usage error" for free.

import std/[strutils, unittest]

import ui_selection

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 252

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Trace = "/tmp/ctui/calc-2f0db4f45192"

  RefusingCommands: array[8, string] = [
    "record", "import", "upload", "download", "login", "list", "print", "ci"]
    ## §6's own list of commands that do not present a session, verbatim.

  BadValues: array[6, string] = [
    "gpui", "banana", "Electron", "TUI", "web-ui", "electron "]
    ## Every one of these must be REFUSED naming the accepted set. `gpui` is
    ## §4.1's reserved-but-not-shipping name; `Electron` and `TUI` are the case
    ## variants a normaliser would have silently accepted; `electron ` has a
    ## trailing space, which is what a quoted shell variable produces.

proc planOf(args: openArray[string]; env = ""; config = ""): UiPlan =
  planUiSelection(args, env, config)

suite "PLAT-1 §4: the value set is closed":

  test "every accepted value resolves, and the set has exactly four members":
    var compared = 0
    for value in AcceptedUiValues:
      inc compared
      let (ok, frontEnd) = parseUiFrontEnd(value)
      ck ok
      ck $frontEnd == value
    # The sweep's own size against its parameter: a loop that ran once would
    # leave three values unasserted and say nothing about them.
    ck compared == AcceptedUiValues.len
    ck AcceptedUiValues.len == 4
    ck acceptedUiValuesText() == "electron, gui, tui, webui"

  test "every refused value is a usage error NAMING the accepted set":
    var compared = 0
    for value in BadValues:
      inc compared
      let plan = planOf(["replay", "--ui=" & value, Trace])
      checkpoint(value & " -> " & (if plan.kind == upkUsageError:
                                     plan.message else: "kind " & $plan.kind))
      ck plan.kind == upkUsageError
      # §4.2: "a usage error naming the accepted set".
      ck plan.message.contains(acceptedUiValuesText())
      # …and it QUOTES what was typed, so a user can see the typo.
      ck plan.message.contains("'" & value & "'")
    ck compared == BadValues.len

  test "`gpui` is refused as reserved, and is NOT in the accepted set":
    # §4.1: "Until it ships, `--ui=gpui` is a usage error naming the accepted
    # set — **not** a value that is accepted and then fails later, and not one
    # that quietly falls back to Electron." All three halves, separately.
    ck "gpui" notin AcceptedUiValues
    let (ok, _) = parseUiFrontEnd("gpui")
    ck not ok
    let plan = planOf(["replay", "--ui=gpui", Trace])
    ck plan.kind == upkUsageError
    ck plan.message.contains("gpui")
    ck plan.message.contains(acceptedUiValuesText())
    # NOT quietly Electron. The positive twin: the same line with a value that
    # IS accepted produces a plan rather than a refusal, so this refusal is
    # about `gpui` and not about the line.
    let accepted = planOf(["replay", "--ui=electron", Trace])
    ck accepted.kind == upkInProcess
    ck accepted.frontEnd == uiElectron

  test "`gui` is an alias for electron TODAY and a separate spelling":
    # §4.1: `gui` names a role, `electron` names an implementation, and the
    # difference is a value rather than a comment — `effectiveFrontEnd` is the
    # one line PLAT-20 changes.
    ck effectiveFrontEnd(uiGui) == uiElectron
    ck effectiveFrontEnd(uiElectron) == uiElectron
    ck effectiveFrontEnd(uiTui) == uiTui
    ck effectiveFrontEnd(uiWebui) == uiWebui
    let plan = planOf(["replay", "--ui=gui", Trace])
    ck plan.kind == upkInProcess
    ck plan.frontEnd == uiGui
    # The DECLARED value survives into the plan; only the EFFECT is collapsed.
    ck $plan.frontEnd == "gui"

suite "PLAT-1 §5: the resolution order, layer by layer":

  test "the flag answers, and beats the environment AND the configuration":
    let plan = planOf(["replay", "--ui=webui", Trace],
                      env = "tui", config = "electron")
    ck plan.kind == upkRewrite
    ck plan.frontEnd == uiWebui
    ck plan.source == usFlag

  test "the environment answers when there is no flag, and beats configuration":
    let plan = planOf(["replay", Trace], env = "tui", config = "webui")
    ck plan.kind == upkHandoff
    ck plan.frontEnd == uiTui
    ck plan.source == usEnv

  test "the configuration answers when neither flag nor environment does":
    let plan = planOf(["replay", Trace], env = "", config = "tui")
    ck plan.kind == upkHandoff
    ck plan.frontEnd == uiTui
    ck plan.source == usConfig

  test "the default is electron, and it is the SOURCE that says so":
    let plan = planOf(["replay", Trace])
    ck plan.kind == upkInProcess
    ck plan.frontEnd == uiElectron
    ck plan.source == usDefault
    # §5: "adopting this flag changes nothing for an existing user" — the argv
    # confutils parses is the argv that arrived, element for element.
    ck plan.ctArgs == @["replay", Trace]

  test "the four layers are strictly ordered, asserted as one table":
    # THE PRECEDENCE ITSELF, not four separate facts about four commands. Each
    # row states what every layer says and which one must win; the table is
    # swept and its size asserted, so a row that stopped being exercised would
    # be visible.
    const Rows: array[6, (string, string, string, UiFrontEnd, UiSource)] = [
      ("webui", "tui",  "electron", uiWebui,    usFlag),
      ("tui",   "",     "webui",    uiTui,      usFlag),
      ("",      "tui",  "electron", uiTui,      usEnv),
      ("",      "webui", "",        uiWebui,    usEnv),
      ("",      "",     "tui",      uiTui,      usConfig),
      ("",      "",     "",         uiElectron, usDefault)]
    var compared = 0
    for (flag, env, config, wanted, source) in Rows:
      inc compared
      var args = @["replay"]
      if flag.len > 0:
        args.add "--ui=" & flag
      args.add Trace
      let plan = planOf(args, env = env, config = config)
      checkpoint("flag='" & flag & "' env='" & env & "' config='" & config &
                 "' -> " & $plan.frontEnd & " from " & $plan.source)
      ck plan.kind != upkUsageError
      ck plan.frontEnd == wanted
      ck plan.source == source
    ck compared == Rows.len

  test "a bad value at ANY layer is refused rather than falling through":
    # The failure this prevents is §4.2's, arrived at from the environment: a
    # typo that quietly resolved to Electron would launch the wrong front-end
    # and say nothing.
    const Layers: array[2, (string, string)] = [
      ("nope", ""),   # CODETRACER_UI
      ("", "nope")]   # configuration
    var compared = 0
    for (env, config) in Layers:
      inc compared
      let plan = planOf(["replay", Trace], env = env, config = config)
      checkpoint("env='" & env & "' config='" & config & "' -> " &
                 (if plan.kind == upkUsageError: plan.message
                  else: "kind " & $plan.kind))
      ck plan.kind == upkUsageError
      ck plan.message.contains("nope")
      ck plan.message.contains(acceptedUiValuesText())
    ck compared == Layers.len
    # …and each names ITS OWN layer, so the user knows where to look.
    ck planOf(["replay", Trace], env = "nope").message.contains(UiEnvVar)
    ck planOf(["replay", Trace], config = "nope").message.contains(
         "'" & UiConfigKey & "'")

  test "the configuration is consulted ONLY when it has to be":
    # §3.1's budget in one predicate: `ct replay --ui=tui <trace>` — the
    # invocation the verification gate measures — reads no configuration file
    # at all, and neither does any command that does not accept the flag.
    ck not uiNeedsConfig(scanUiArgs(["replay", "--ui=tui", Trace]), "")
    ck not uiNeedsConfig(scanUiArgs(["replay", Trace]), "tui")
    ck not uiNeedsConfig(scanUiArgs(["record", "prog.py"]), "")
    ck not uiNeedsConfig(scanUiArgs(["list"]), "")
    ck not uiNeedsConfig(scanUiArgs([]), "")
    # …and IS consulted when neither of the first two layers answered, which
    # is what stops this predicate from being a check that cannot fail.
    ck uiNeedsConfig(scanUiArgs(["replay", Trace]), "")
    ck uiNeedsConfig(scanUiArgs(["run", "prog.py"]), "")
    ck uiNeedsConfig(scanUiArgs(["edit", "."]), "")
    ck uiNeedsConfig(scanUiArgs(["review", "."]), "")
    ck uiNeedsConfig(scanUiArgs(["host", Trace]), "")

suite "PLAT-1 §6: which commands accept `--ui`":

  test "all four session-presenting commands accept it":
    var compared = 0
    for command in UiSelectingCommands:
      inc compared
      let plan = planOf([command, "--ui=electron", Trace])
      checkpoint(command & " -> " & $plan.kind)
      ck plan.kind == upkInProcess
      ck plan.frontEnd == uiElectron
    ck compared == UiSelectingCommands.len
    ck UiSelectingCommands.len == 4
    ck uiSelectingCommandsText() == "replay, run, edit, review"

  test "every other command refuses it, naming the conflict AND the four":
    var compared = 0
    for command in RefusingCommands:
      inc compared
      let plan = planOf([command, "--ui=tui", Trace])
      checkpoint(command & " -> " & (if plan.kind == upkUsageError:
                                       plan.message else: $plan.kind))
      ck plan.kind == upkUsageError
      # "a usage error naming the conflict": the command that cannot take it…
      ck plan.message.contains("ct " & command)
      # …and the ones that can.
      ck plan.message.contains(uiSelectingCommandsText())
    ck compared == RefusingCommands.len

  test "a command with a pass-through tail does not lose the child's flags":
    # `recordArgs` and `runArgs` are `restOfArgs`, so everything after the
    # first positional belongs to the recorded program. `ct record prog.py
    # --ui=tui` is a program being given `--ui=tui`, and reading it as ct's
    # would be the same defect `codetracer.nim`'s `--` handling exists to
    # prevent (`ct record php -S localhost:8000` losing its `-S`).
    let recordTail = planOf(["record", "prog.py", "--ui=tui"])
    ck recordTail.kind == upkInProcess
    ck recordTail.ctArgs == @["record", "prog.py", "--ui=tui"]
    let runTail = planOf(["run", "prog.py", "--ui=tui"])
    ck runTail.kind == upkInProcess
    ck runTail.frontEnd == uiElectron
    ck runTail.ctArgs == @["run", "prog.py", "--ui=tui"]
    # …and everything after a POSIX `--` likewise, separator included.
    let afterSep = planOf(["record", "--", "php", "--ui=tui"])
    ck afterSep.kind == upkInProcess
    ck afterSep.ctArgs == @["record", "--", "php", "--ui=tui"]
    # THE POSITIVE TWIN, without which the three above are satisfied by a
    # module that never reads `--ui` at all: written BEFORE the program, it is
    # ct's and it is honoured.
    let beforeProgram = planOf(["run", "--ui=tui", "prog.py"])
    ck beforeProgram.kind == upkInProcess
    ck beforeProgram.frontEnd == uiTui
    ck beforeProgram.ctArgs == @["run", "prog.py"]
    # And a `replay` line has no child, so `--ui` is read wherever it sits.
    let afterTrace = planOf(["replay", Trace, "--ui=tui"])
    ck afterTrace.kind == upkHandoff
    ck afterTrace.handoffArgs == @[Trace]

suite "PLAT-1 §8: `--headless` belongs to the TUI":

  test "`--ui=tui --headless` is the spelling, and the flag reaches the TUI":
    let plan = planOf(["replay", "--ui=tui", "--headless", Trace])
    ck plan.kind == upkHandoff
    ck plan.componentName == "codetracer-tui"
    ck plan.handoffArgs == @[Trace, "--headless"]

  test "`--headless` with any other value is a usage error naming both sides":
    var compared = 0
    for value in ["electron", "gui", "webui"]:
      inc compared
      let plan = planOf(["replay", "--ui=" & value, "--headless", Trace])
      checkpoint(value & " -> " & (if plan.kind == upkUsageError:
                                     plan.message else: $plan.kind))
      ck plan.kind == upkUsageError
      # BOTH SIDES, named: the flag…
      ck plan.message.contains("--headless")
      # …and the value it contradicts.
      ck plan.message.contains("--ui=" & value)
    ck compared == 3

  test "`--headless` with NO `--ui` names where 'electron' came from":
    # §9.2's worry, met: the value may come from an environment variable the
    # user forgot they exported, and "'--headless' contradicts '--ui=electron'"
    # is a baffling message to a user who never wrote `--ui`.
    let default = planOf(["replay", "--headless", Trace])
    ck default.kind == upkUsageError
    ck default.message.contains($usDefault)
    let fromEnv = planOf(["replay", "--headless", Trace], env = "electron")
    ck fromEnv.kind == upkUsageError
    ck fromEnv.message.contains($usEnv)
    let fromConfig = planOf(["replay", "--headless", Trace], config = "webui")
    ck fromConfig.kind == upkUsageError
    ck fromConfig.message.contains($usConfig)

  test "`--headless` is never handed to confutils, which has no such option":
    # It is CTUI-14's TUI flag, not one of ct's. Left in the argv it would
    # reach confutils as "Unrecognized option 'headless'" whatever this module
    # decided — so the scan takes it out.
    let scan = scanUiArgs(["replay", "--ui=tui", "--headless", Trace])
    ck scan.hasHeadless
    ck scan.strippedArgs == @["replay", Trace]

suite "PLAT-1 §3: the TUI is reached by handoff":

  test "the plan names the component and carries the trace, not the flag":
    let plan = planOf(["replay", "--ui=tui", Trace])
    ck plan.kind == upkHandoff
    ck plan.componentName == "codetracer-tui"
    ck plan.componentBin == "codetracer-tui"
    ck plan.handoffArgs == @[Trace]
    # `--ui` itself does NOT travel: the TUI has no such option and would
    # refuse it by name.
    ck "--ui=tui" notin plan.handoffArgs

  test "`-t` and `--trace-folder` become the TUI's positional argument":
    var compared = 0
    for spelling in [@["-t", Trace], @["--trace-folder", Trace],
                     @["--trace-folder=" & Trace], @["-t=" & Trace]]:
      inc compared
      let plan = planOf(@["replay", "--ui=tui"] & spelling)
      checkpoint($spelling & " -> " & $plan.kind)
      ck plan.kind == upkHandoff
      ck plan.handoffArgs == @[Trace]
    ck compared == 4

  test "the TUI's own options travel, in order, and are not interpreted":
    # §9.3: options are global and refused per front-end. `--goto`, `--theme`
    # and `--no-color` mean something to the terminal front-end, and this
    # module knows nothing about any of them — which is the point.
    let plan = planOf(["replay", "--ui=tui", "--goto=200", "--theme=light",
                       "--no-color", Trace])
    ck plan.kind == upkHandoff
    ck plan.handoffArgs == @["--goto=200", "--theme=light", "--no-color", Trace]

  test "a separated option VALUE is never mistaken for the trace":
    # The defect this case exists for: a scan that looked for "the first bare
    # token" found `8901` in `--port 8901` and offered it as the recording.
    # Order is preserved and nothing is claimed by position.
    let plan = planOf(["replay", "--ui=tui", "--inspect", "9229", Trace])
    ck plan.kind == upkHandoff
    ck plan.handoffArgs == @["--inspect", "9229", Trace]

  test "`--id` and `--interactive` are refused, naming the gap":
    # Resolving a recording id means opening the trace index, and §3.1 puts the
    # whole trace layer on the far side of this decision. Refused rather than
    # silently opening the working directory.
    let byId = planOf(["replay", "--ui=tui", "--id", "0198-abc"])
    ck byId.kind == upkUsageError
    ck byId.message.contains("--id")
    ck byId.message.contains("<trace-folder>")
    let interactive = planOf(["replay", "--ui=tui", "-i"])
    ck interactive.kind == upkUsageError
    ck interactive.message.contains("--interactive")

  test "`edit` and `review` accept the flag and refuse the COMBINATION":
    # §9.1's recommendation, taken: the flag is accepted on `edit` so it does
    # not have to be added later, and the combination is refused with a message
    # naming the gap rather than omitted from §6.
    var compared = 0
    for command in ["edit", "review"]:
      for value in ["tui", "webui"]:
        inc compared
        let plan = planOf([command, "--ui=" & value, "."])
        checkpoint(command & " " & value & " -> " &
                   (if plan.kind == upkUsageError: plan.message else: "?"))
        ck plan.kind == upkUsageError
        ck plan.message.contains("ct " & command & " --ui=" & value)
        ck plan.message.contains("--ui=electron")
      # …and the desktop values are accepted on the same command, so the four
      # refusals above are about the COMBINATION and not about the command.
      let desktop = planOf([command, "--ui=gui", "."])
      ck desktop.kind == upkInProcess
      ck desktop.ctArgs == @[command, "."]
    ck compared == 4

  test "`run` resolves the value and defers the handoff to its own replay":
    # `ct run` has nothing to present until it has recorded, so the prologue
    # cannot hand off. It resolves, and `trace/run.nim` restates the value on
    # the `ct replay --id=<id>` it spawns for itself.
    let plan = planOf(["run", "--ui=tui", "prog.py"])
    ck plan.kind == upkInProcess
    ck plan.frontEnd == uiTui
    ck plan.ctArgs == @["run", "prog.py"]

suite "PLAT-1 §7.2: `ct host` and `ct replay --ui=webui` are one entry":

  test "`replay --ui=webui` is rewritten into `ct host`'s own command line":
    let plan = planOf(["replay", "--ui=webui", "-t", Trace])
    ck plan.kind == upkRewrite
    ck plan.rewrittenArgs == @["host", "--trace-path", Trace]

  test "`host`'s options carry over verbatim, values and all":
    # §7.2: "`host`-specific options (bind address, port, session limits) become
    # `--ui=webui`'s options and keep their spellings."
    let plan = planOf(["replay", "--ui=webui", "--port", "8901",
                       "--idle-timeout", "30s", "--backend-socket-port=5001",
                       "-t", Trace])
    ck plan.kind == upkRewrite
    ck plan.rewrittenArgs == @["host", "--port", "8901", "--idle-timeout",
                               "30s", "--backend-socket-port=5001",
                               "--trace-path", Trace]

  test "a bare argument and `--id` both become `host`'s positional":
    # `replay`'s bare argument is a program-name pattern that may be a path;
    # `host`'s is a recording id that may be a folder. They are the same
    # "work out what this is" argument, so it is carried across as one rather
    # than reinterpreted.
    ck planOf(["replay", "--ui=webui", "calc"]).rewrittenArgs ==
       @["host", "calc"]
    ck planOf(["replay", "--ui=webui", "--id", "0198-abc"]).rewrittenArgs ==
       @["host", "0198-abc"]
    # …and a port written BEFORE the bare argument keeps both.
    ck planOf(["replay", "--ui=webui", "--port", "8901", "calc"]).rewrittenArgs ==
       @["host", "--port", "8901", "calc"]

  test "`ct host` needs no flag, and refuses one that contradicts it":
    # The equivalence in its second direction, said at the point of use.
    let plain = planOf(["host", "--port", "8901", Trace])
    ck plain.kind == upkInProcess
    ck plain.frontEnd == uiWebui
    ck plain.ctArgs == @["host", "--port", "8901", Trace]
    let redundant = planOf(["host", "--ui=webui", Trace])
    ck redundant.kind == upkInProcess
    ck redundant.ctArgs == @["host", Trace]
    var compared = 0
    for value in ["tui", "electron", "gui"]:
      inc compared
      let plan = planOf(["host", "--ui=" & value, Trace])
      checkpoint("host --ui=" & value & " -> " &
                 (if plan.kind == upkUsageError: plan.message else: "?"))
      ck plan.kind == upkUsageError
      ck plan.message.contains("ct replay --ui=" & value)
    ck compared == 3

  test "`ct host` is NOT affected by CODETRACER_UI or by the configuration":
    # Otherwise a user who had configured `ui: tui` could not run `ct host` at
    # all, which would make a preference into a prohibition.
    let plan = planOf(["host", Trace], env = "tui", config = "tui")
    ck plan.kind == upkInProcess
    ck plan.frontEnd == uiWebui
    ck plan.ctArgs == @["host", Trace]

suite "PLAT-1: the flag's spellings, and what is left for confutils":

  test "`--ui=v`, `--ui:v` and `--ui v` all resolve, and all disappear":
    var compared = 0
    for spelling in [@["--ui=tui"], @["--ui:tui"], @["--ui", "tui"]]:
      inc compared
      let plan = planOf(@["replay"] & spelling & @[Trace])
      checkpoint($spelling & " -> " & $plan.kind)
      ck plan.kind == upkHandoff
      ck plan.handoffArgs == @[Trace]
    ck compared == 3
    # …and on a command that keeps its argv, the option and its separated value
    # are BOTH removed. Leaving the value behind would hand confutils a stray
    # positional argument.
    let plan = planOf(["replay", "--ui", "electron", Trace])
    ck plan.kind == upkInProcess
    ck plan.ctArgs == @["replay", Trace]

  test "`--ui` with nothing after it is refused, naming the accepted set":
    let plan = planOf(["replay", "--ui"])
    ck plan.kind == upkUsageError
    ck plan.message.contains("'--ui' needs a value")
    ck plan.message.contains(acceptedUiValuesText())

  test "an argv this module has no business in comes back byte for byte":
    var compared = 0
    for args in [@["list"], @["print", "--format", "json", Trace],
                 @["record", "prog.py", "--flag"], @["ct-complete", "--b"],
                 @[]]:
      inc compared
      let plan = planOf(args)
      ck plan.kind == upkInProcess
      ck plan.ctArgs == args
    ck compared == 5

suite "assertion count":

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
