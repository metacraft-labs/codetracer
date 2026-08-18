## The `ct review` command group — DeepReview's entire command-line surface.
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §1.1 and RV-1 of
## `codetracer-specs/DeepReview/Review-Command.milestones.org` make `ct review`
## the *only* way a user reaches DeepReview from a shell:
##
## ===========================  =================================================
## Command                      Role
## ===========================  =================================================
## ``ct review <PATH>``         Launch CodeTracer over an exported review dataset
## ``ct review collect …``      Produce a review dataset from recordings + a diff
## ``ct review inspect <PATH>`` Summarise a dataset without opening a GUI
## ===========================  =================================================
##
## The former spellings — the global ``ct --deepreview`` option and the
## ``ct-native-replay deepreview {collect,export,inspect}`` command group — are
## retired outright rather than aliased, the convention the workspace applies
## elsewhere (``reprobuild-specs/Retired-Names.md``).  They fail with a message
## naming ``ct review``; :proc:`retiredDeepReviewArgIndex` and
## :proc:`retiredDeepReviewMessage` are the ct-side half of that.
##
## ## Why this module is split into a planner and an executor
##
## Everything that decides *what* a `ct review` line means is a pure function
## of argv (:proc:`planReviewCli`), with no filesystem, no environment and no
## subprocess.  That is what makes the dispatch assertable headlessly on both
## the C and the JavaScript Nim backends — the whole ViewModel test lane — and
## it is deliberate: the previous surface was a single confutils field whose
## behaviour could only be observed by launching Electron.
##
## The `when not defined(js)` half below performs a plan: it resolves the
## dataset on disk and shells out to the native collector.  Callers:
##
## * `src/ct/codetracer.nim` intercepts `ct review collect|inspect` *before*
##   confutils parses argv, because those verbs carry flags that are not ct's
##   own (`--repo`, `--diff-file`, `--preset`, …) and confutils rejects any
##   dash-prefixed token it does not recognise.  This is the same interception
##   `ct-complete` and `ct record --` already use.
## * `src/ct/launch/launch.nim` handles the launch form, which *is* an ordinary
##   confutils command (`StartupCommand.review`) so it keeps ct's global
##   options (`--inspect`, `--remote-debugging-port`, …) that Playwright and
##   the Electron tooling inject.
##
## ## Why `collect` writes JSON as well as `.dr`
##
## The native collector writes a binary `.dr` dataset; the GUI reads JSON.
## Before RV-1 that gap was bridged by a separate `deepreview export` step,
## and RV-1 retires `export` as a user-facing command.  Leaving `collect` to
## emit only `.dr` would therefore leave a user with a dataset no documented
## command could open.  So `ct review collect --output <DIR>` writes the `.dr`
## chunks *and* `<DIR>/review.json`, and `ct review <DIR>` accepts the
## directory (resolving the JSON inside it) as well as the JSON file itself.
## One command in, one command out, no undocumented intermediate step.

import std/strutils

const
  ReviewDatasetJsonName* = "review.json"
    ## The JSON dataset `ct review collect` writes inside its output
    ## directory, and the file `ct review <DIR>` resolves to.

  RetiredDeepReviewFlag* = "--deepreview"
    ## The retired global option `ct review <PATH>` replaces.

  NativeReplayReviewDataGroup* = "review-data"
    ## The hidden `ct-native-replay` subcommand group that carries the native
    ## collector.  Hidden, not removed: RV-1 retires the *user-facing*
    ## `deepreview` group while keeping the implementation reachable as a
    ## subprocess, exactly as the milestone's deliverable requires.

type
  ReviewPlanKind* = enum
    ## What a `ct review …` command line resolved to.
    rpkLaunch      ## open CodeTracer over an exported dataset
    rpkCollect     ## produce a dataset from recordings + a diff
    rpkInspect     ## summarise a dataset without a GUI
    rpkUsage       ## the user asked for help
    rpkError       ## the line does not name a valid command

  ReviewPlan* = object
    case kind*: ReviewPlanKind
    of rpkLaunch:
      datasetPath*: string
        ## as typed: either a JSON dataset or a directory holding one.
    of rpkCollect:
      collectorArgs*: seq[string]
        ## argv for the native collector, in ITS spelling, starting at the
        ## `collect` verb.  Held as data so the translation is assertable
        ## without a native backend installed.
      outputDir*: string
        ## where the dataset lands; also where `review.json` is written.
    of rpkInspect:
      inspectPath*: string
      inspectFormat*: string   ## "text" (default) or "json"
    of rpkUsage:
      discard
    of rpkError:
      message*: string

const
  ReviewUsage* = """
`ct review` — review a diff with its recorded executions (DeepReview).

Usage:
  ct review <PATH>                    open a review over an exported dataset
                                      (a review.json file, or a directory
                                      produced by `ct review collect`)
  ct review collect [OPTIONS]         produce a review dataset
  ct review inspect <PATH> [--format text|json]
                                      summarise a dataset without a GUI

`ct review collect` options:
  --repo <DIR>          git repository the diff is read from
  --diff <BASE..HEAD>   diff specification, e.g. main..HEAD
  --diff-file <PATH>    a unified diff file instead of --repo/--diff
  --recordings <DIR>    directory of recordings to collect from
  --output, -o <DIR>    output directory for the dataset (required)
  --preset <NAME>       default | minimal | comprehensive
  --progress            emit JSON Lines progress events on stderr

`collect` writes the dataset chunks and a `review.json` beside them, so
`ct review <the same DIR>` opens what it just produced.
"""

func retiredDeepReviewMessage*(): string =
  ## The diagnostic for the retired `ct --deepreview <PATH>` option.
  ##
  ## RV-1 requires this to be produced *deliberately*: `ct review` is
  ## intercepted before confutils parses argv, and leaving the retired option
  ## to confutils would print a bare "Unrecognized option" that names no
  ## replacement.
  "error: `ct --deepreview <PATH>` was retired: use `ct review <PATH>` " &
    "instead.\n" &
    "  DeepReview's whole command-line surface is the `ct review` command " &
    "group:\n" &
    "    ct review <PATH>            open a review over an exported dataset\n" &
    "    ct review collect …         produce a dataset from recordings\n" &
    "    ct review inspect <PATH>    summarise a dataset\n" &
    "  See codetracer-specs/DeepReview/CLI-Reference.md."

func retiredDeepReviewArgIndex*(args: openArray[string]): int =
  ## Index of a retired `--deepreview` **global option** in argv, or -1.
  ##
  ## `--deepreview` was a global option of `ct` itself, and confutils accepts
  ## global options only ahead of the subcommand, so the leading run of argv
  ## is the only place it could ever have been honoured.  Scanning only there
  ## is what keeps a *child* program's identically-spelled flag out of scope:
  ## `ct record ./prog --deepreview x` passes `--deepreview` to `./prog`, and
  ## reporting that as a retired ct option would be wrong.  The scan also
  ## stops at the POSIX `--` separator for the same reason.
  result = -1
  for i in 0 ..< args.len:
    let arg = args[i]
    if arg == "--":
      return -1
    if arg == RetiredDeepReviewFlag or
        arg.startsWith(RetiredDeepReviewFlag & "="):
      return i
    if i == 0 and not arg.startsWith("-"):
      # argv leads with a subcommand, so ct's own global options are already
      # behind us and everything here belongs to that subcommand.
      return -1

func errorPlan(message: string): ReviewPlan =
  ReviewPlan(kind: rpkError, message: message)

func isHelpToken(arg: string): bool =
  arg in ["--help", "-h", "help"]

type
  FlagValue = object
    ## One parsed `--name value` / `--name=value` pair.
    name: string
    value: string
    hasValue: bool

func splitFlag(arg: string): FlagValue =
  ## Split `--name=value` into its parts; a bare `--name` has no value yet.
  let eq = arg.find('=')
  if eq >= 0:
    FlagValue(name: arg[0 ..< eq], value: arg[eq + 1 .. ^1], hasValue: true)
  else:
    FlagValue(name: arg, value: "", hasValue: false)

func planCollect(rest: openArray[string]): ReviewPlan =
  ## Translate `ct review collect …` into the native collector's argv.
  ##
  ## The flag set is deliberately the collector's own, minus `--backend`:
  ## DeepReview-GUI.md §1.1 is explicit that "a collector is chosen by
  ## inspecting the recording, never by the user naming a backend".  RV-3
  ## adds that inspection; until then this delegates unconditionally to the
  ## native collector.
  var
    repo, diff, diffFile, recordings, output, preset = ""
    progress = false
    i = 0
  while i < rest.len:
    let arg = rest[i]
    if isHelpToken(arg):
      return ReviewPlan(kind: rpkUsage)
    if not arg.startsWith("-"):
      return errorPlan("error: `ct review collect` takes no positional " &
        "arguments, but got '" & arg & "'.\n" &
        "  Name the dataset directory with --output <DIR>.")
    let flag = splitFlag(arg)
    var value = flag.value
    let wantsValue = flag.name != "--progress"
    if wantsValue and not flag.hasValue:
      if i + 1 >= rest.len:
        return errorPlan("error: " & flag.name & " expects a value.")
      value = rest[i + 1]
      inc i
    case flag.name
    of "--repo": repo = value
    of "--diff": diff = value
    of "--diff-file": diffFile = value
    of "--recordings": recordings = value
    of "--output", "-o": output = value
    of "--preset": preset = value
    of "--progress":
      if flag.hasValue:
        return errorPlan("error: --progress is a switch and takes no value.")
      progress = true
    else:
      return errorPlan("error: unknown option '" & flag.name &
        "' for `ct review collect`.\n" & ReviewUsage)
    inc i

  if output.len == 0:
    return errorPlan("error: `ct review collect` requires --output <DIR>, " &
      "the directory the dataset is written to.")
  if recordings.len == 0:
    return errorPlan("error: `ct review collect` requires --recordings " &
      "<DIR>, the directory holding the recordings to collect from.")
  if diffFile.len == 0 and (repo.len == 0 or diff.len == 0):
    return errorPlan("error: `ct review collect` needs a diff: pass " &
      "--repo <DIR> together with --diff <BASE..HEAD>, or --diff-file " &
      "<PATH>.")
  if diffFile.len > 0 and (repo.len > 0 or diff.len > 0):
    return errorPlan("error: --diff-file cannot be combined with --repo or " &
      "--diff; they are two ways of naming the same diff.")
  if diff.len > 0 and not diff.contains(".."):
    return errorPlan("error: invalid --diff '" & diff &
      "': expected BASE..HEAD, e.g. main..HEAD.")

  var argv = @["collect"]
  if diffFile.len > 0:
    argv.add(@["--diff-file", diffFile])
  else:
    argv.add(@["--repo", repo, "--diff", diff])
  argv.add(@["--recordings", recordings, "--output", output])
  if preset.len > 0:
    argv.add(@["--preset", preset])
  if progress:
    argv.add("--progress")
  ReviewPlan(kind: rpkCollect, collectorArgs: argv, outputDir: output)

func planInspect(rest: openArray[string]): ReviewPlan =
  ## Translate `ct review inspect <PATH> [--format …]`.
  var
    path = ""
    format = "text"
    i = 0
  while i < rest.len:
    let arg = rest[i]
    if isHelpToken(arg):
      return ReviewPlan(kind: rpkUsage)
    if not arg.startsWith("-"):
      if path.len > 0:
        return errorPlan("error: `ct review inspect` takes exactly one " &
          "dataset path, but got both '" & path & "' and '" & arg & "'.")
      path = arg
      inc i
      continue
    let flag = splitFlag(arg)
    var value = flag.value
    if not flag.hasValue:
      if i + 1 >= rest.len:
        return errorPlan("error: " & flag.name & " expects a value.")
      value = rest[i + 1]
      inc i
    case flag.name
    of "--format":
      if value notin ["text", "json"]:
        return errorPlan("error: unknown --format '" & value &
          "': expected 'text' or 'json'.")
      format = value
    else:
      return errorPlan("error: unknown option '" & flag.name &
        "' for `ct review inspect`.\n" & ReviewUsage)
    inc i
  if path.len == 0:
    return errorPlan("error: `ct review inspect` needs the path of a " &
      "dataset to summarise.")
  ReviewPlan(kind: rpkInspect, inspectPath: path, inspectFormat: format)

func planReviewCli*(args: openArray[string]): ReviewPlan =
  ## Resolve a full `ct review …` argv (including the leading `review`) into
  ## the one thing it means.  Pure: no filesystem, no environment.
  if args.len == 0 or args[0] != "review":
    return errorPlan("error: not a `ct review` command line.")
  if args.len == 1:
    return errorPlan("error: `ct review` needs a dataset path or a " &
      "subcommand.\n" & ReviewUsage)
  let verb = args[1]
  if verb.len == 0:
    # confutils fills an omitted `reviewPath` argument with "", so `ct review`
    # with nothing after it arrives here rather than as a one-element argv.
    return errorPlan("error: `ct review` needs a dataset path or a " &
      "subcommand.\n" & ReviewUsage)
  if isHelpToken(verb):
    return ReviewPlan(kind: rpkUsage)
  case verb
  of "collect":
    return planCollect(args.toOpenArray(2, args.len - 1))
  of "inspect":
    return planInspect(args.toOpenArray(2, args.len - 1))
  of "export":
    return errorPlan("error: `ct review export` does not exist: " &
      "`ct review collect` writes " & ReviewDatasetJsonName &
      " itself, so there is nothing left to export.")
  else:
    discard
  if verb == RetiredDeepReviewFlag or
      verb.startsWith(RetiredDeepReviewFlag & "="):
    return errorPlan(retiredDeepReviewMessage())
  if verb.startsWith("-"):
    return errorPlan("error: unknown option '" & verb &
      "' for `ct review`.\n" & ReviewUsage)
  if args.len > 2:
    return errorPlan("error: `ct review <PATH>` takes exactly one dataset " &
      "path, but got '" & args[2] & "' as well.\n" & ReviewUsage)
  ReviewPlan(kind: rpkLaunch, datasetPath: verb)

func reviewNeedsRawDispatch*(args: openArray[string]): bool =
  ## Whether a `ct review …` line must be handled before confutils sees argv.
  ##
  ## The flag-carrying verbs and the help tokens, and nothing else.
  ## `collect` and
  ## `inspect` take options that are not ct's own (`--repo`, `--diff-file`,
  ## `--preset`, …) and confutils rejects every dash-prefixed token it does not
  ## recognise, so they are intercepted; `export` is here only to be refused
  ## with a pointer at `collect` rather than read as a dataset path.
  ##
  ## The launch form is *never* intercepted, whatever follows the path.  It is
  ## an ordinary command with one argument, and going through the parser is
  ## what keeps ct's global options — `--inspect`, `--remote-debugging-port`,
  ## `--remote-debugging-pipe`, `--cwd`, the `--env-file` family — working for
  ## it exactly as they work for `ct edit`, which is what CLI-Reference.md §3.1
  ## promises.  Claiming the line as soon as a second token appeared would take
  ## that promise back: `ct review DIR --remote-debugging-port=0` would be
  ## refused as "exactly one dataset path" instead of launching.  Extra
  ## positionals are still refused — confutils answers them with "The
  ## subcommand 'review' does not accept additional arguments", the same
  ## diagnostic `ct edit` gives.
  ##
  ## The help tokens are intercepted for the same reason the flag-carrying
  ## verbs are: confutils only knows the shape it was declared with, so
  ## `ct review --help` printed `ct review <reviewPath>` and never mentioned
  ## `collect` or `inspect` at all.  A user who asks a command group for help
  ## and is shown one third of it has been told the other two do not exist.
  ## `ReviewUsage` — which bare `ct review` already prints — is the whole
  ## group, so routing help at it is the fix rather than teaching confutils to
  ## describe subcommands it does not have.
  if args.len < 2 or args[0] != "review":
    return false
  args[1] in ["collect", "inspect", "export"] or isHelpToken(args[1])

when not defined(js):
  import std/[os, osproc]

  const
    NativeReplayExeEnvVar* = "CODETRACER_NATIVE_REPLAY_PATH"
      ## Explicit override for the native replay binary, used by tests and by
      ## installations that keep it outside `PATH`.

  proc nativeReplayExe*(): string =
    ## Locate the binary that carries the native DeepReview collector.
    ##
    ## Same discovery order the rest of ct uses for this backend (see
    ## `common/config.nim`, which auto-discovers it into `rrBackend.path`):
    ## an explicit override, then the current name on `PATH`, then the legacy
    ## name.  Returns "" when it is not installed; callers must diagnose that
    ## rather than spawning an empty path.
    result = getEnv(NativeReplayExeEnvVar, "")
    if result.len > 0:
      return
    result = findExe("ct-native-replay")
    if result.len > 0:
      return
    result = findExe("ct-rr-support")

  func missingNativeReplayMessage*(verb: string): string =
    ## Diagnostic for `ct review <verb>` with no native backend installed.
    ## Names what is missing and how to supply it — an environmental gap must
    ## say what it is, not fail as a generic spawn error.
    "error: `ct review " & verb & "` needs the native replay backend, and " &
      "no `ct-native-replay` binary was found.\n" &
      "  Add it to PATH, or point " & NativeReplayExeEnvVar & " at it."

  proc resolveReviewDatasetJson*(path: string): tuple[jsonPath, error: string] =
    ## Resolve what the user typed into the JSON dataset the frontend loads.
    ##
    ## Accepts the JSON file itself, or a directory `ct review collect`
    ## produced (in which case the `review.json` written beside the `.dr`
    ## chunks is used).  A path that does not exist is diagnosed here rather
    ## than handed to Electron, which used to `JSON.parse` a failed read and
    ## die with a stack trace naming nothing the user typed.
    if path.len == 0:
      return ("", "error: `ct review` needs the path of a review dataset.")
    if dirExists(path):
      let candidate = path / ReviewDatasetJsonName
      if fileExists(candidate):
        return (candidate, "")
      return ("", "error: '" & path & "' is a directory with no " &
        ReviewDatasetJsonName & " in it.\n" &
        "  `ct review collect --output " & path & "` writes one; a dataset " &
        "collected before that wrote only the binary chunks.")
    if fileExists(path):
      return (path, "")
    ("", "error: no review dataset at '" & path & "'.")

  proc runNativeReviewData(args: openArray[string]): int =
    ## Run the hidden `review-data` group of the native replay binary,
    ## inheriting stdio so progress and diagnostics reach the user unbuffered.
    let exe = nativeReplayExe()
    if exe.len == 0:
      return -1
    var argv = @[NativeReplayReviewDataGroup]
    for a in args:
      argv.add(a)
    let process = startProcess(exe, args = argv,
      options = {poParentStreams})
    result = waitForExit(process)
    close(process)

  proc runReviewCollect*(plan: ReviewPlan): int =
    ## Collect a dataset, then export the JSON the GUI reads.
    ##
    ## Two subprocess calls, one user-visible command: see the module header
    ## for why `collect` is not allowed to stop at the binary chunks.
    doAssert plan.kind == rpkCollect
    if nativeReplayExe().len == 0:
      stderr.writeLine(missingNativeReplayMessage("collect"))
      return 1
    result = runNativeReviewData(plan.collectorArgs)
    if result != 0:
      return result
    let jsonPath = plan.outputDir / ReviewDatasetJsonName
    result = runNativeReviewData(
      @["export", plan.outputDir, "--format", "json", "-o", jsonPath])
    if result != 0:
      stderr.writeLine("error: the dataset was collected into '" &
        plan.outputDir & "' but could not be written as " &
        ReviewDatasetJsonName & ", so `ct review " & plan.outputDir &
        "` cannot open it.")
      return result
    echo "Review dataset ready: ", jsonPath
    echo "Open it with: ct review ", plan.outputDir

  proc runReviewInspect*(plan: ReviewPlan): int =
    ## Summarise a dataset without opening a GUI.
    doAssert plan.kind == rpkInspect
    if nativeReplayExe().len == 0:
      stderr.writeLine(missingNativeReplayMessage("inspect"))
      return 1
    runNativeReviewData(
      @["inspect", plan.inspectPath, "--format", plan.inspectFormat])

  proc runReviewCli*(args: openArray[string]): int =
    ## Execute the non-launch verbs of `ct review`.  The launch form is
    ## handled by `launch.nim` so it keeps ct's global options; see the
    ## module header.
    let plan = planReviewCli(args)
    case plan.kind
    of rpkCollect:
      runReviewCollect(plan)
    of rpkInspect:
      runReviewInspect(plan)
    of rpkUsage:
      echo ReviewUsage
      QuitSuccess
    of rpkError:
      stderr.writeLine(plan.message)
      QuitFailure
    of rpkLaunch:
      # Unreachable through `reviewNeedsRawDispatch`, which routes the launch
      # form to confutils.  Diagnosed rather than silently ignored so a future
      # caller that dispatches everything here fails loudly.
      stderr.writeLine("error: internal: the `ct review <PATH>` launch form " &
        "is handled by the launch path, not by the raw dispatcher.")
      QuitFailure
