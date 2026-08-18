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
## ## How `collect` chooses a collector (RV-3)
##
## DeepReview-GUI.md §1.1: "A collector is chosen by inspecting the recording,
## never by the user naming a backend."  So `collect` surveys `--recordings`
## before it runs anything (:proc:`surveyRecordings`, in
## `trace/trace_kind.nim` — the same rules `ct replay` uses to decide which
## backend opens a trace) and routes on what it finds
## (:proc:`routeReviewCollect`):
##
## =====================  ==========================================================
## Recordings             Route
## =====================  ==========================================================
## all native (rr)        `ct-native-replay review-data collect`
## all materialized       `replay-server review-collect` — the db-backend collector
##                        (RV-4), over the same trace database the debugger reads
## mixed kinds            refused; see the milestone's judgement calls for why the
##                        alternative (collect per kind and merge) was not taken
## none                   refused, distinguishing an empty directory from one that
##                        holds no recordings
## =====================  ==========================================================
##
## The survey runs *before* the native backend is looked up, which is not an
## accident of ordering: a Python user has no `ct-native-replay` installed, and
## answering "the native replay backend is missing" for a Python recording
## would name the wrong problem and imply DeepReview is an rr-only feature —
## the exact coupling §1.1 says must not become architectural.  For the same
## reason the survey is implemented in `ct` rather than delegated to the native
## backend's own trace-kind detection: the machine that most needs the
## diagnostic is the one where that binary is not installed.
##
## Every one of these routes is decided by a *pure* function of the survey, so
## the whole dispatch table is assertable on both Nim backends without a
## recording, a collector or a filesystem.
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
##
## The materialized collector has no binary intermediate at all: it writes
## `<DIR>/review.json` directly, so its route is one subprocess rather than
## two.  Both routes therefore leave the same file in the same place, which is
## what lets `ct review <DIR>` stay indifferent to which one ran.

import std/strutils

import trace/trace_kind
export trace_kind

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

  ReplayServerReviewCollectVerb* = "review-collect"
    ## The db-backend (`replay-server`) subcommand carrying the materialized
    ## collector (RV-4).  Not hidden the way the native group is: the
    ## db-backend binary is internal to CodeTracer and has no published CLI to
    ## retire a command from.

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
      recordingsDir*: string
        ## the directory `--recordings` named.  Held separately from
        ## `collectorArgs` because RV-3's dispatch inspects it *before* any
        ## collector is chosen, and re-parsing the collector's argv to find it
        ## again would be a second source of truth for the same value.
      repoDir*, diffSpec*, diffFile*, preset*: string
      progress*: bool
        ## The collect options as the *user* typed them, kept beside the
        ## native collector's already-translated argv.
        ##
        ## RV-4 adds a second collector whose argv differs (a different verb,
        ## and `--repo`/`--diff` that it can honour without an optional Cargo
        ## feature), so a single pre-translated `collectorArgs` is no longer
        ## enough.  Holding the parsed values means each collector's argv is
        ## derived from the same one parse — `planCollect` — rather than one
        ## being re-parsed out of the other's command line.
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
    # Point at something the person reading this actually has.  This line used
    # to name `codetracer-specs/DeepReview/CLI-Reference.md`, a file that lives
    # in a private specification repository: for every user of the shipped
    # binary it is a dead end, and it advertises internal layout besides.
    "  Run `ct review --help` for the full flag set."

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
  ReviewPlan(kind: rpkCollect, collectorArgs: argv, outputDir: output,
    recordingsDir: recordings, repoDir: repo, diffSpec: diff,
    diffFile: diffFile, preset: preset, progress: progress)

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

type
  ReviewCollector* = enum
    ## Which collector can read a given set of recordings.  RV-3 builds the
    ## seam; RV-4 fills in the second arm.
    rcvNone
      ## no collector can be chosen — the route's `message` says why
    rcvNative
      ## `ct-native-replay review-data collect`, reached as a subprocess
      ## through its hidden `review-data` group (RV-1)
    rcvMaterialized
      ## `replay-server review-collect` — the db-backend collector (RV-4),
      ## reading the same trace database the debugger reads.

  CollectRoute* = object
    ## The outcome of inspecting a recordings directory.
    collector*: ReviewCollector
    message*: string
      ## Empty **iff** the route can be taken today.  A non-empty message on
      ## a named collector means "this is whose job it is, and it cannot do
      ## it yet" — which is what keeps the refusal specific instead of
      ## degenerating into "unsupported".
    kinds*: set[CtTraceKind]
      ## Every kind found among the recordings (excluding `ctkUnknown`
      ## entries, which are not recordings).  Exposed so a caller can report
      ## what was seen without re-deriving it.

func canCollect*(route: CollectRoute): bool =
  ## Whether this route names a collector that exists and can run now.
  route.collector != rcvNone and route.message.len == 0

func namesOfKind(entries: openArray[RecordingSurveyEntry],
                 kind: CtTraceKind): seq[string] =
  result = @[]
  for entry in entries:
    if entry.kind == kind:
      result.add entry.name

func briefList(names: openArray[string]): string =
  ## Name at most three things, then say how many more there were.  A
  ## diagnostic that pastes two hundred directory names is unreadable, and
  ## one that names none makes the user go looking.
  const shown = 3
  if names.len == 0:
    return "none"
  var parts: seq[string] = @[]
  for i in 0 ..< min(shown, names.len):
    parts.add names[i]
  result = parts.join(", ")
  if names.len > shown:
    result &= " and " & $(names.len - shown) & " more"

const
  RecordingShapeHelp* =
    "  A recording is an rr trace directory (one holding a `version` " &
    "file), or a\n" &
    "  materialized trace directory (one holding a `.ct` container or a " &
    "trace_metadata.json)."
    ## What `ct review collect` is looking for, in the terms a user can
    ## check with `ls`.  Repeated in every "nothing here" diagnostic,
    ## because the most likely cause of one is a mistyped path.

func missingRecordingsDirMessage*(recordingsDir: string): string =
  ## `--recordings` names a directory that is not there.
  ##
  ## Diagnosed by `ct` rather than left to the collector, which answered with
  ## a Rust `Debug` rendering of its error type
  ## (`Error: Custom { kind: Other, error: "invalid data: recordings ...`).
  "error: `ct review collect` found no recordings directory at '" &
    recordingsDir & "'.\n" &
    "  --recordings names the directory that HOLDS the recordings, one " &
    "subdirectory each."

func routeReviewCollect*(recordingsDir: string,
                         entries: openArray[RecordingSurveyEntry]):
                        CollectRoute =
  ## Choose the collector for a surveyed recordings directory — the seam
  ## DeepReview-GUI.md §1.1 describes, as a pure function so the whole
  ## dispatch table is assertable without a recording on disk.
  ##
  ## Four outcomes, each deliberate; see the milestone's judgement calls:
  ##
  ## * one kind, native — the existing collector, unchanged.
  ## * one kind, materialized — the db-backend collector (RV-4); named, with
  ##   no message, because it exists and can run.
  ## * more than one kind — refused rather than collected per kind and
  ##   merged.  The two collectors write two datasets and there is no
  ##   dataset-level merge, so "merge" could only mean "collect one kind and
  ##   drop the rest", which is the silent partial dataset this milestone
  ##   exists to prevent.
  ## * nothing to collect — refused, and an empty directory is distinguished
  ##   from one holding no recordings, because those are different mistakes.
  var recordings: seq[RecordingSurveyEntry] = @[]
  for entry in entries:
    if entry.kind != ctkUnknown:
      recordings.add entry
      result.kinds.incl entry.kind

  if recordings.len == 0:
    result.collector = rcvNone
    if entries.len == 0:
      result.message =
        "error: `ct review collect` found no recordings in '" &
        recordingsDir & "': the directory is empty.\n" &
        "  Record the runs you want reviewed first (`ct record …`), then " &
        "point --recordings at\n  the directory holding them."
    else:
      var names: seq[string] = @[]
      for entry in entries:
        names.add entry.name
      result.message =
        "error: `ct review collect` found no recordings in '" &
        recordingsDir & "'.\n" &
        "  It holds " & $entries.len & " entr" &
        (if entries.len == 1: "y" else: "ies") &
        ", none of which is a recording: " & briefList(names) & ".\n" &
        RecordingShapeHelp
    return

  if result.kinds.card > 1:
    result.collector = rcvNone
    var kindLines = ""
    for kind in [ctkNative, ctkMaterialized]:
      if kind in result.kinds:
        let names = namesOfKind(recordings, kind)
        kindLines &= "\n    " & traceKindLabel(kind) & ": " & $names.len &
          " (" & briefList(names) & ")"
    result.message =
      "error: `ct review collect` refuses a mixed recordings directory: '" &
      recordingsDir & "' holds recordings of more than one kind." &
      kindLines & "\n" &
      "  One collector is chosen per run by inspecting the recordings, and " &
      "datasets produced by\n  two different collectors are not merged.  " &
      "Point --recordings at recordings of one kind."
    return

  if ctkNative in result.kinds:
    result.collector = rcvNative
    return

  # RV-4: materialized recordings are collected by the db-backend, so this arm
  # names a collector that exists and carries no message.  Until RV-4 it named
  # the kind and refused; the refusal machinery is deliberately left in place
  # for the kinds that still have no collector (`rcvNone` above), so a future
  # kind cannot be added and silently produce an empty dataset.
  result.collector = rcvMaterialized

func materializedCollectorArgs*(plan: ReviewPlan): seq[string] =
  ## argv for the db-backend collector, in ITS spelling, starting at the
  ## `review-collect` verb.
  ##
  ## The sibling of `plan.collectorArgs`, which is the native collector's argv.
  ## Both are derived from the one parse `planCollect` performed, so the two
  ## collectors cannot disagree about what the user asked for, and both are
  ## pure functions of the plan so the translation is assertable on either Nim
  ## backend with no collector installed.
  ##
  ## The two argv differ in exactly two places, both deliberate:
  ##
  ## * the verb — `collect` under the native binary's hidden `review-data`
  ##   group, `review-collect` on the db-backend;
  ## * `--repo` + `--diff` are passed through as typed.  The native collector
  ##   can only read a repository when it was built with its optional
  ##   `git2-support` Cargo feature (RV-1 judgement call 4), which is why the
  ##   CI templates use `--diff-file`; the db-backend collector shells out to
  ##   `git`, so the flags work on a stock build.
  doAssert plan.kind == rpkCollect
  result = @[ReplayServerReviewCollectVerb]
  if plan.diffFile.len > 0:
    result.add(@["--diff-file", plan.diffFile])
    # `--diff-file` names no commits, but a repository still resolves the
    # patch's relative paths, so it is forwarded when the user gave one.
    if plan.repoDir.len > 0:
      result.add(@["--repo", plan.repoDir])
  else:
    result.add(@["--repo", plan.repoDir, "--diff", plan.diffSpec])
  result.add(@["--recordings", plan.recordingsDir, "--output", plan.outputDir])
  if plan.preset.len > 0:
    result.add(@["--preset", plan.preset])
  if plan.progress:
    result.add("--progress")

when not defined(js):
  import std/[os, osproc]
  import ../common/paths
  import review_session

  const
    NativeReplayExeEnvVar* = "CODETRACER_NATIVE_REPLAY_PATH"
      ## Explicit override for the native replay binary, used by tests and by
      ## installations that keep it outside `PATH`.

    ReplayServerExeEnvVar* = "CODETRACER_REPLAY_SERVER_PATH"
      ## Explicit override for the db-backend binary, the sibling of
      ## `NativeReplayExeEnvVar`.  Used by tests and by installations that keep
      ## the backend outside the CodeTracer prefix.

  proc replayServerExe*(): string =
    ## Locate the binary that carries the materialized DeepReview collector.
    ##
    ## Unlike the native backend, the db-backend ships *with* CodeTracer, so
    ## the install-prefix path (`paths.dbBackendExe`, which the replay launch
    ## already uses) is the normal answer and `PATH` is only the fallback for a
    ## development tree.  Returns "" when it is not installed; callers must
    ## diagnose that rather than spawning an empty path.
    result = getEnv(ReplayServerExeEnvVar, "")
    if result.len > 0:
      return
    if dbBackendExe.len > 0 and fileExists(dbBackendExe):
      return dbBackendExe
    result = findExe("replay-server")

  func missingReplayServerMessage*(): string =
    ## Diagnostic for a materialized collection with no db-backend installed.
    ##
    ## Names the binary CodeTracer ships rather than the rr backend: a user
    ## reviewing a Python recording who is told `ct-native-replay` is missing
    ## has been told DeepReview is an rr-only feature, which is the coupling
    ## DeepReview-GUI.md §1.1 says must not become architectural.
    "error: `ct review collect` needs the CodeTracer replay backend to " &
      "collect from materialized (CTFS) recordings, and no `replay-server` " &
      "binary was found.\n" &
      "  It ships with CodeTracer; add it to PATH, or point " &
      ReplayServerExeEnvVar & " at it."

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

  proc associateCollectedSession(jsonPath: string): int =
    ## RV-6 — record the agent session that produced this dataset, when the
    ## environment names one.
    ##
    ## Called by *both* collector routes, at the point where each has just
    ## written the `review.json` the GUI opens.  The reference is a fact about
    ## the environment the collection ran in, not about the recordings, so it
    ## belongs to `ct` — the one process that sees that environment, and the
    ## one path both collectors go through.  Doing it here rather than in each
    ## collector is what stops the two disagreeing (and keeps the rr collector,
    ## which lives in another repository, from needing to know about agent
    ## sessions at all).
    ##
    ## **Absence is normal.**  A human running `ct review collect` by hand has
    ## none of the variables set; the dataset simply carries no reference and
    ## the review is complete without one (DeepReview-GUI.md §2.1).
    let spec = detectReviewSessionRef(getCurrentDir())
    let failure = stampReviewSessionRef(jsonPath, spec)
    if failure.len > 0:
      # The dataset itself is fine — only the association failed — so this is
      # reported and the collection still counts as a failure, because a user
      # who set the variables asked for the association and did not get it.
      stderr.writeLine("error: " & failure)
      return 1
    if hasSessionRef(spec):
      echo "Associated with agent session: ", spec.sessionId,
        " (", normalizeBackend(spec.backend), ")"
    0

  proc runMaterializedReviewCollect*(plan: ReviewPlan): int =
    ## Collect from materialized (CTFS) recordings, through the db-backend.
    ##
    ## One subprocess, not two: the db-backend writes `review.json` itself, so
    ## there is no binary intermediate to export from.  The success line still
    ## names the same file `ct review <DIR>` opens, so the two routes are
    ## indistinguishable from the outside.
    doAssert plan.kind == rpkCollect
    let exe = replayServerExe()
    if exe.len == 0:
      stderr.writeLine(missingReplayServerMessage())
      return 1
    let process = startProcess(exe, args = materializedCollectorArgs(plan),
      options = {poParentStreams})
    result = waitForExit(process)
    close(process)
    if result != 0:
      return result
    let jsonPath = plan.outputDir / ReviewDatasetJsonName
    if not fileExists(jsonPath):
      # The collector reported success but wrote nothing the GUI can open.
      # Diagnosed here rather than left for `ct review <DIR>` to trip over,
      # because this is the moment the user can still act on it.
      stderr.writeLine("error: the collection reported success but no " &
        ReviewDatasetJsonName & " was written to '" & plan.outputDir &
        "', so `ct review " & plan.outputDir & "` cannot open it.")
      return 1
    let associated = associateCollectedSession(jsonPath)
    if associated != 0:
      return associated
    echo "Open it with: ct review ", plan.outputDir

  proc runReviewCollect*(plan: ReviewPlan): int =
    ## Collect a dataset, then export the JSON the GUI reads.
    ##
    ## Two subprocess calls, one user-visible command: see the module header
    ## for why `collect` is not allowed to stop at the binary chunks.
    doAssert plan.kind == rpkCollect
    # RV-3: inspect the recordings and choose the collector BEFORE looking
    # for any backend.  See the module header for why the order matters.
    if not dirExists(plan.recordingsDir):
      stderr.writeLine(missingRecordingsDirMessage(plan.recordingsDir))
      return 1
    let route = routeReviewCollect(
      plan.recordingsDir, surveyRecordings(plan.recordingsDir))
    if not canCollect(route):
      stderr.writeLine(route.message)
      return 1
    if route.collector == rcvMaterialized:
      return runMaterializedReviewCollect(plan)
    doAssert route.collector == rcvNative,
      "the survey names one of two collectors, and the other was handled above"
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
    result = associateCollectedSession(jsonPath)
    if result != 0:
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
