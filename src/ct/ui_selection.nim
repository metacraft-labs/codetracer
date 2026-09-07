## ui_selection.nim — `--ui`, as a decision and nothing else. PLAT-1.
##
## Specification: `codetracer-specs/CLI/ct/ui-selection.md`.
##
## ## What this module is
##
## `planUiSelection` turns `argv` — plus the environment value and the
## configured value — into a `UiPlan` and does nothing else: it opens no trace,
## reads no file, spawns nothing, prints nothing and exits nowhere. That is what
## makes the whole selector assertable without a process, and it is the same
## split `src/frontend/tui/app/cli.nim` uses one repository-layer down: the
## DECISION is a value, the EFFECT is `launch/ui_dispatch.nim`'s.
##
## ## THE ONE THING THAT IS EASY TO GET WRONG HERE
##
## §3.1: "the `--ui` decision is taken in the argument-parsing prologue, before
## any window, engine, trace or configuration file is touched … an `--ui` check
## placed after configuration loading still *works*." A selector that is correct
## and late is the defect this milestone's verification gate is a benchmark
## about, so this module is deliberately dependency-free (`std/strutils` only)
## and its caller runs it as the first thing `codetracer.nim` does.
##
## The one apparent exception is the CONFIGURATION layer of §5's resolution
## order, and it is not one: `uiNeedsConfig` answers whether the flag and the
## environment have already decided the question, and the caller reads the
## configuration only when the answer is "no". `--ui=tui` therefore touches no
## file at all, which is the case the gate measures.
##
## ## Values are closed, and `gpui` is closed OUT
##
## §4.2: an unrecognised value is a usage error naming the accepted set — never
## a component name, never guessed at, never a silent fall back to the default.
## §4.1 puts `gpui` on the far side of that line *deliberately*: it is a value
## the vocabulary reserves and this milestone does not accept, so `--ui=gpui`
## today is a refusal that names the accepted set rather than a value that is
## taken and then fails later. PLAT-20 adds it to `AcceptedUiValues`, and no
## earlier milestone does.

import std/strutils

type
  UiFrontEnd* = enum
    ## §4's vocabulary. `gpui` is NOT here — see the module header.
    uiElectron = "electron"
      ## Specifically the Electron desktop application.
    uiGui = "gui"
      ## The native desktop UI, WHICHEVER IT CURRENTLY IS. An alias for
      ## `electron` today and expected to become GPUI; §4.1 keeps the two
      ## spellings apart precisely so a user who needs Electron's process model
      ## is not moved underneath them.
    uiTui = "tui"
      ## The terminal front-end — a separate component, reached by handoff.
    uiWebui = "webui"
      ## Served in a browser over HTTP: the `ct host` code path, and §7.3 says
      ## there is one of those and two spellings of its entry.

  UiSource* = enum
    ## Which layer of §5's resolution order answered. Carried into diagnostics
    ## because "`--headless` contradicts `--ui=electron`" is a confusing message
    ## when the user never wrote `--ui` — the value came from an environment
    ## variable they forgot they exported, which is §9.2's own worry.
    usFlag = "the --ui flag"
    usEnv = "the CODETRACER_UI environment variable"
    usConfig = "the 'ui' setting in your CodeTracer configuration"
    usDefault = "the built-in default"

  UiPlanKind* = enum
    upkInProcess
      ## Nothing to hand off: this binary IS the front-end. §3.2 — `electron`
      ## and `gui` are the Electron host, and `webui` is `ct host`, which is
      ## also this binary.
    upkHandoff
      ## `exec` another component's binary with `handoffArgs`.
    upkRewrite
      ## Re-enter THIS binary's own dispatch with a different argv. §7.2's
      ## `ct replay --ui=webui` ≡ `ct host`, implemented as the second spelling
      ## of one entry rather than as a second implementation of hosting (§7.3).
    upkUsageError

  UiPlan* = object
    frontEnd*: UiFrontEnd
    source*: UiSource
      ## Meaningless when `kind == upkUsageError` and read by nobody then.
    case kind*: UiPlanKind
    of upkInProcess:
      ctArgs*: seq[string]
        ## `argv` with `--ui` (and its separated value) removed, for confutils.
        ## Identical to the input when no `--ui` token was present, which is
        ## what makes adopting this flag change nothing for an existing user.
    of upkHandoff:
      componentName*: string   ## e.g. "codetracer-tui"
      componentBin*: string    ## e.g. "codetracer-tui"
      handoffArgs*: seq[string]
        ## The arguments for the exec'd binary, WITHOUT argv[0].
    of upkRewrite:
      rewrittenArgs*: seq[string]
    of upkUsageError:
      message*: string
        ## One line, already prefixed with `ct: `, for stderr.

const
  AcceptedUiValues*: array[4, string] = ["electron", "gui", "tui", "webui"]
    ## §4's table, as the closed set §4.2 requires. The ORDER is the table's.

  UiSelectingCommands*: array[4, string] = ["replay", "run", "edit", "review"]
    ## §6: the commands that PRESENT a session.

  UiEnvVar* = "CODETRACER_UI"
  UiConfigKey* = "ui"

  ReservedUiValues*: array[1, string] = ["gpui"]
    ## §4.1: in the vocabulary, not in the accepted set. Named in the refusal so
    ## a user reading it learns the difference between "that is not a front-end"
    ## and "that one is not shipping yet" — without either being accepted.

func acceptedUiValuesText*(): string =
  AcceptedUiValues.join(", ")

func uiSelectingCommandsText*(): string =
  UiSelectingCommands.join(", ")

func parseUiFrontEnd*(value: string): (bool, UiFrontEnd) =
  ## `("tui")` -> `(true, uiTui)`. `(false, uiElectron)` for anything else,
  ## INCLUDING `gpui` and including the empty string.
  ##
  ## Case-sensitive, like every other value in this CLI: `--ui=TUI` is refused
  ## rather than accepted, because a selector that normalises silently is one
  ## more thing that behaves differently from what was typed.
  for i, name in AcceptedUiValues:
    if value == name:
      return (true, UiFrontEnd(i))
  (false, uiElectron)

func effectiveFrontEnd*(frontEnd: UiFrontEnd): UiFrontEnd =
  ## §4.1: `gui` names a ROLE and resolves to whatever we currently ship as the
  ## native desktop experience. Today that is Electron. **This is the one line
  ## PLAT-20 changes**, and it is a line rather than a scattering of `== uiGui`
  ## comparisons for exactly that reason.
  if frontEnd == uiGui: uiElectron else: frontEnd

func unknownValueMessage(value, sourceText: string): string =
  ## §4.2's refusal, in one line, naming the accepted set.
  result = "ct: unknown " & sourceText & " value '" & value &
           "'; the accepted values are " & acceptedUiValuesText()
  for reserved in ReservedUiValues:
    if value == reserved:
      result.add ". '" & reserved & "' is a reserved front-end name that is" &
                 " not shipping yet, so it is refused rather than silently" &
                 " treated as '" & $uiElectron & "'"

# ---------------------------------------------------------------------------
# The command line, read weakly
# ---------------------------------------------------------------------------

type
  UiScan* = object
    ## What the command line SAYS about `--ui`, before anything is resolved.
    ##
    ## Deliberately weak: it classifies the first token as a command word and
    ## picks two options out of the rest. Every other token is carried through
    ## untouched, because confutils owns ct's grammar and a second parser that
    ## believed it understood the whole line is how `--ui` would come to
    ## disagree with it.
    command*: string
      ## `argv[0]`, or "" when argv is empty or begins with a dash.
    hasUiFlag*: bool
    uiFlagValue*: string
    uiFlagValueMissing*: bool
      ## `--ui` written with nothing after it.
    hasHeadless*: bool
    strippedArgs*: seq[string]
      ## `argv` with the `--ui` option (and its separated value) removed, and
      ## `--headless` removed. `--headless` is NOT one of ct's own options — it
      ## is CTUI-14's TUI flag (§8) — so leaving it in would reach confutils as
      ## "Unrecognized option 'headless'" whatever this module decided.

func optionValue(arg, name: string): (bool, bool, string) =
  ## `(matched, attached, value)` for `--name`, `--name=v` and `--name:v`.
  ##
  ## The `:` spelling is accepted because confutils accepts it for every other
  ## option of this binary, and a flag that is spelled differently from its
  ## neighbours is a flag people get wrong.
  if arg == name:
    return (true, false, "")
  if arg.startsWith(name & "="):
    return (true, true, arg[name.len + 1 .. ^1])
  if arg.startsWith(name & ":"):
    return (true, true, arg[name.len + 1 .. ^1])
  (false, false, "")

const
  WholeLineCommands*: array[4, string] = ["replay", "edit", "review", "host"]
    ## The commands whose whole command line belongs to `ct`.
    ##
    ## THE OTHERS HAVE A TAIL THAT IS SOMEBODY ELSE'S, and reading `--ui` out of
    ## it would steal an argument from a recorded program. `ct record foo.py
    ## --ui=tui` and `ct run prog.py --ui=tui` pass `--ui=tui` to the CHILD:
    ## `recordArgs` and `runArgs` are `restOfArgs`, so everything after the
    ## first positional is the program's. `codetracer.nim` makes the same
    ## distinction one level up for POSIX `--`, and for the same reason — see
    ## its `RecordChildProgramPlaceholder` note, which records what happened
    ## when `ct record php -S localhost:8000` had its `-S` read as ct's.
    ##
    ## So for every other command the scan stops at the first positional after
    ## the command word, and `ct run --ui=tui prog.py` — options before the
    ## program, the ordinary shape — is the spelling that reaches this module.

func scanUiArgs*(args: openArray[string]): UiScan =
  ## Read `--ui` and `--headless` out of `args` without interpreting anything
  ## else.
  ##
  ## Scanning stops at the first bare `--` always, and at the first positional
  ## after the command word for every command outside `WholeLineCommands`.
  ## Everything past the stop is copied into `strippedArgs` verbatim.
  if args.len == 0:
    return
  if not args[0].startsWith("-"):
    result.command = args[0]
  let wholeLine = result.command in WholeLineCommands
  var i = 0
  var stopped = false
  while i <= args.high:
    let arg = args[i]
    if stopped:
      result.strippedArgs.add arg
      inc i
      continue
    if arg == "--":
      # POSIX end-of-options. Everything after it is the child program's, and
      # the separator itself has to survive: `codetracer.nim` splits `ct record
      # … -- …` on it.
      stopped = true
      result.strippedArgs.add arg
      inc i
      continue
    if i > 0 and not wholeLine and not arg.startsWith("-"):
      stopped = true
      result.strippedArgs.add arg
      inc i
      continue
    let (isUi, attached, attachedValue) = optionValue(arg, "--ui")
    if isUi:
      result.hasUiFlag = true
      if attached:
        result.uiFlagValue = attachedValue
      elif i < args.high:
        inc i
        result.uiFlagValue = args[i]
      else:
        result.uiFlagValueMissing = true
      inc i
      continue
    if arg == "--headless":
      result.hasHeadless = true
      inc i
      continue
    result.strippedArgs.add arg
    inc i

func uiNeedsConfig*(scan: UiScan; envValue: string): bool =
  ## Whether §5's CONFIGURATION layer has to be consulted at all.
  ##
  ## False whenever the flag or the environment already answered, and false for
  ## a command that does not accept `--ui` — so `ct record foo.py` reads no
  ## configuration on this path, and neither does `ct replay --ui=tui <trace>`,
  ## which is the invocation §3.1's benchmark is about.
  if scan.command.len == 0:
    return false
  if scan.command notin UiSelectingCommands and scan.command != "host":
    return false
  if scan.hasUiFlag or envValue.len > 0:
    return false
  true

# ---------------------------------------------------------------------------
# Resolution — §5
# ---------------------------------------------------------------------------

type
  UiResolution* = object
    ok*: bool
    frontEnd*: UiFrontEnd
    source*: UiSource
    message*: string   ## set when `ok` is false

func resolveUi*(scan: UiScan; envValue, configValue: string): UiResolution =
  ## §5, in order: the flag, then `CODETRACER_UI`, then configuration, then the
  ## built-in default `electron`.
  ##
  ## AN EXPLICIT FLAG ALWAYS BEATS A STORED PREFERENCE, and an unparseable value
  ## at ANY layer is a refusal rather than a fall-through to the next one. A
  ## typo in `CODETRACER_UI` that quietly resolved to Electron would be §4.2's
  ## "silently launches the wrong front-end" wearing a different hat.
  if scan.hasUiFlag:
    if scan.uiFlagValueMissing:
      return UiResolution(ok: false,
        message: "ct: '--ui' needs a value; the accepted values are " &
                 acceptedUiValuesText())
    let (ok, frontEnd) = parseUiFrontEnd(scan.uiFlagValue)
    if not ok:
      return UiResolution(ok: false,
        message: unknownValueMessage(scan.uiFlagValue, "--ui"))
    return UiResolution(ok: true, frontEnd: frontEnd, source: usFlag)

  if envValue.len > 0:
    let (ok, frontEnd) = parseUiFrontEnd(envValue)
    if not ok:
      return UiResolution(ok: false,
        message: unknownValueMessage(envValue, UiEnvVar))
    return UiResolution(ok: true, frontEnd: frontEnd, source: usEnv)

  if configValue.len > 0:
    let (ok, frontEnd) = parseUiFrontEnd(configValue)
    if not ok:
      return UiResolution(ok: false,
        message: unknownValueMessage(configValue,
                                     "'" & UiConfigKey & "' configuration"))
    return UiResolution(ok: true, frontEnd: frontEnd, source: usConfig)

  UiResolution(ok: true, frontEnd: uiElectron, source: usDefault)

# ---------------------------------------------------------------------------
# Argument rewriting for the two front-ends that are not this process
# ---------------------------------------------------------------------------

type
  ArgTarget = enum
    ## Which front-end's grammar the translated argv is for.
    atTui
    atHost

  ArgTranslation = object
    ok: bool
    message: string
    args: seq[string]
    trailing: seq[string]
      ## Tokens that must go at the END of the result: a value that changed
      ## from a named option into a positional one has no place to sit where it
      ## was.

func translateArgs(command: string; args: openArray[string];
                   target: ArgTarget): ArgTranslation =
  ## Translate `replay`'s trace selection into `target`'s spelling of it, IN
  ## ORDER, and leave every other token exactly where it was.
  ##
  ## ## ORDER IS PRESERVED BECAUSE THE POSITION OF A TOKEN IS INFORMATION
  ##
  ## The first version of this function pulled the trace selection out and
  ## re-emitted the remainder. That is wrong for a reason worth writing down:
  ## a separated option value is a bare token, so `--port 8901` puts `8901`
  ## where a "positional argument" scan finds it, and `ct replay --ui=webui
  ## --port 8901 -t <dir>` reached `ct host` with the port GONE and `8901`
  ## offered as the trace. Recognising it would mean knowing every option of
  ## every command that takes a value — a second copy of ct's grammar, which
  ## confutils owns and which this module must not have.
  ##
  ## So the only tokens this function claims are the ones `replay` spells for
  ## the TRACE ITSELF, and they are claimed by NAME, never by position. §9.3's
  ## recommendation is what the rest is: options stay global and are refused by
  ## the front-end that cannot honour them, so `--port`, `--idle-timeout` and
  ## the storage options carry over to `--ui=webui` unchanged (§7.2), and
  ## `--goto`, `--theme` and `--no-color` reach the terminal front-end.
  result.ok = true
  var i = 0
  # `args[0]` is the command word; the caller supplies the new one.
  if args.len > 0 and args[0] == command:
    i = 1

  proc valueOf(args: openArray[string]; i: var int;
               attached: bool; attachedValue: string): string =
    ## The value of the option at `args[i]`, advancing `i` past a separated
    ## one. Returns "" for an option written last with nothing after it — which
    ## confutils would refuse anyway, and refusing it here as well would
    ## produce a second, different diagnostic for one mistake.
    if attached:
      return attachedValue
    if i < args.high:
      inc i
      return args[i]
    ""

  while i <= args.high:
    let arg = args[i]

    let (isFolder, folderAttached, folderValue) =
      optionValue(arg, "--trace-folder")
    var folder = ""
    var isShortFolder = false
    if arg == "-t":
      isShortFolder = true
      folder = valueOf(args, i, false, "")
    elif arg.startsWith("-t=") or arg.startsWith("-t:"):
      isShortFolder = true
      folder = arg[3 .. ^1]
    elif isFolder:
      folder = valueOf(args, i, folderAttached, folderValue)
    if isFolder or isShortFolder:
      # `-t` / `--trace-folder` NAMES A FOLDER in every spelling.
      case target
      of atTui:
        # The terminal front-end takes a folder as its positional argument and
        # has no option for it.
        if folder.len > 0:
          result.args.add folder
      of atHost:
        # `--trace-path` is `host`'s spelling for "a folder — import it and
        # serve it". Its POSITIONAL is a recording id first and a folder only
        # as a fallback, so the folder must not go there.
        if folder.len > 0:
          result.args.add "--trace-path"
          result.args.add folder
      inc i
      continue

    let (isId, idAttached, idValue) = optionValue(arg, "--id")
    if isId:
      let id = valueOf(args, i, idAttached, idValue)
      case target
      of atTui:
        # NOT resolved here, deliberately. Turning a recording id into a folder
        # means opening the trace index, and §3.1 puts the whole trace layer on
        # the far side of this decision.
        return ArgTranslation(ok: false, message:
          "ct: '--id' cannot be resolved by the terminal front-end; pass the" &
          " recording folder instead (ct replay --ui=tui <trace-folder>)")
      of atHost:
        # `host`'s positional argument IS a recording id.
        if id.len > 0:
          result.trailing.add id
      inc i
      continue

    if arg == "-i" or arg == "--interactive":
      let which = if target == atTui: "the terminal front-end opens a" &
                    " recording folder, so name one" &
                    " (ct replay --ui=tui <trace-folder>)"
                  else: "a server serves one named recording" &
                    " (ct replay --ui=webui <trace>)"
      return ArgTranslation(ok: false, message:
        "ct: '--interactive' is not available with '--ui=" &
        (if target == atTui: "tui" else: "webui") & "'; " & which)

    result.args.add arg
    inc i


# ---------------------------------------------------------------------------
# The plan — §3, §6, §7, §8
# ---------------------------------------------------------------------------

func usageError(message: string): UiPlan =
  UiPlan(kind: upkUsageError, message: message)

func gapMessage(command: string; frontEnd: UiFrontEnd; gap: string): string =
  "ct: 'ct " & command & " --ui=" & $frontEnd & "' is not available: " & gap &
  ". Use --ui=electron or --ui=gui"

func planUiSelection*(args: openArray[string];
                      envValue, configValue: string): UiPlan =
  ## The whole of `--ui`, as one value. See the module header for what this
  ## deliberately does NOT do.
  let scan = scanUiArgs(args)

  # §6: a command that does not present a session refuses the flag, naming the
  # conflict. Checked BEFORE the value is parsed, because `ct record
  # --ui=banana` is wrong about the command first and about the value second,
  # and the first message is the useful one.
  if scan.hasUiFlag and scan.command notin UiSelectingCommands and
     scan.command != "host":
    let named = if scan.command.len > 0: "'ct " & scan.command & "'"
                else: "this command line"
    return usageError(
      "ct: '--ui' is not accepted by " & named & "; it selects the front-end" &
      " that presents a session, and " & named & " does not present one. The" &
      " commands that accept it are: " & uiSelectingCommandsText())

  # A command that accepts no `--ui` and carries none is not this module's
  # business at all: hand the argv back untouched so nothing about `ct record`
  # or `ct list` moves.
  if scan.command.len == 0 or
     (scan.command notin UiSelectingCommands and scan.command != "host"):
    return UiPlan(kind: upkInProcess, frontEnd: uiElectron,
                  source: usDefault, ctArgs: @args)

  let resolution = resolveUi(scan, envValue, configValue)
  if not resolution.ok:
    return usageError(resolution.message)

  let declared = resolution.frontEnd
  let frontEnd = effectiveFrontEnd(declared)

  # §7.2, the SECOND direction of the equivalence, said at the point of use:
  # `ct host` IS the web front-end, so naming another one on it is a
  # contradiction rather than a selection.
  if scan.command == "host":
    if scan.hasUiFlag and frontEnd != uiWebui:
      return usageError(
        "ct: 'ct host' is already the web front-end ('ct host <trace>' is" &
        " 'ct replay --ui=webui <trace>'), so '--ui=" & $declared &
        "' contradicts it. Write 'ct replay --ui=" & $declared &
        " <trace>' instead")
    if scan.hasHeadless:
      return usageError(
        "ct: '--headless' renders one settled screen in the terminal" &
        " front-end and 'ct host' is the web front-end; the spelling is" &
        " 'ct replay --ui=tui --headless <trace>'")
    return UiPlan(kind: upkInProcess, frontEnd: uiWebui,
                  source: (if scan.hasUiFlag: usFlag else: usDefault),
                  ctArgs: scan.strippedArgs)

  # §8: `--headless` is a property of the TUI, not a fifth front-end. Refused
  # with any other value, NAMING BOTH SIDES — and naming where the other side
  # came from, because the user may not have written `--ui` at all.
  if scan.hasHeadless and frontEnd != uiTui:
    return usageError(
      "ct: '--headless' and '--ui=" & $declared & "' contradict each other;" &
      " --headless renders one settled screen and exits, which only the" &
      " terminal front-end does, so the spelling is '--ui=tui --headless'." &
      " '" & $declared & "' came from " & $resolution.source)

  case frontEnd
  of uiElectron, uiGui:
    # §3.2: no handoff — this binary is the Electron host.
    #
    # `declared` rather than `frontEnd`, so the plan reports what the user
    # WROTE. §4.1 keeps `gui` and `electron` apart deliberately; collapsing the
    # two here would make `ct run --ui=gui` restate itself to its own replay as
    # `--ui=electron` and pin a user who asked for "the desktop app" to a
    # specific implementation — the exact substitution the distinction exists
    # to prevent.
    UiPlan(kind: upkInProcess, frontEnd: declared, source: resolution.source,
           ctArgs: scan.strippedArgs)

  of uiTui:
    if scan.command == "edit":
      return usageError(gapMessage(scan.command, declared,
        "the terminal front-end has no edit mode yet (see" &
        " codetracer-specs/GUI/Layout-And-Navigation/Mode-Transitions.md)"))
    if scan.command == "review":
      return usageError(gapMessage(scan.command, declared,
        "the terminal front-end has no review mode yet"))
    if scan.command == "run":
      # `ct run` RECORDS and only then presents. The handoff cannot happen in
      # the prologue because there is nothing to present yet, so the resolved
      # front-end is carried into the replay `run` spawns for itself
      # (`trace/run.nim`), which arrives back here as `ct replay --ui=tui`.
      return UiPlan(kind: upkInProcess, frontEnd: uiTui,
                    source: resolution.source, ctArgs: scan.strippedArgs)
    let translated = translateArgs(scan.command, scan.strippedArgs, atTui)
    if not translated.ok:
      return usageError(translated.message)
    var handoff = translated.args
    handoff.add translated.trailing
    if scan.hasHeadless:
      handoff.add "--headless"
    UiPlan(kind: upkHandoff, frontEnd: uiTui, source: resolution.source,
           componentName: "codetracer-tui", componentBin: "codetracer-tui",
           handoffArgs: handoff)

  of uiWebui:
    if scan.command == "edit":
      return usageError(gapMessage(scan.command, declared,
        "the web front-end serves a recording, not an editor session"))
    if scan.command == "review":
      return usageError(gapMessage(scan.command, declared,
        "the web front-end serves a recording, not a review dataset"))
    if scan.command == "run":
      return UiPlan(kind: upkInProcess, frontEnd: uiWebui,
                    source: resolution.source, ctArgs: scan.strippedArgs)
    let translated = translateArgs(scan.command, scan.strippedArgs, atHost)
    if not translated.ok:
      return usageError(translated.message)
    # §7.2 / §7.3: ONE code path, two spellings of its entry. `ct host`'s own
    # options came through `translateArgs` untouched and keep their spellings,
    # so this is `ct host`'s command line and not a second hosting front door.
    var rewritten = @["host"]
    rewritten.add translated.args
    rewritten.add translated.trailing
    UiPlan(kind: upkRewrite, frontEnd: uiWebui, source: resolution.source,
           rewrittenArgs: rewritten)
