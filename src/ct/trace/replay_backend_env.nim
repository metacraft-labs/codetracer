## replay_backend_env — how `ct replay` hands replay options to the native
## (MCR) replay backend.
##
## NORMATIVE SOURCE: `codetracer-specs/CLI/ct/replay.md`, "Options", and
## `codetracer-specs/CLI/ct-mcr/replay-worker.md` ("Replay Mode —
## `--os-simulation`", "Ordering granularity — `--thread-sync-order`").
##
## ## Why the environment, and not a flag
##
## A GUI replay runs `ct` -> Electron -> backend-manager -> db-backend
## (`dap-server`) -> `ct-native-replay replay-worker` -> `ct-mcr`.  None of the
## hops in between knows the replay engine's options, and none of them has an
## argument slot for them.  Every hop DOES pass its environment on unchanged:
## `launch/electron.nim` copies it into the Electron child, the Electron index
## copies `process.env` into backend-manager (`frontend/index/ipc_utils.nim`,
## `ready`), and the Rust spawns in db-backend and `ct-native-replay` inherit
## it.  And every option here has an environment twin under
## CLI-Parameter-Patterns Rule 3 (`CT_<NAME>`), which `ct-mcr` reads with the
## same meaning as the flag.  So `ct replay` forwards these options as their
## twins, exactly as `ct record` does for the recorder (`recorder_env.nim`).
##
## ## Rule 3, as `ct-mcr` implements it, applied one hop earlier
##
## The variable seeds the choice and the flag wins.  An invalid value from
## either is an error that names its source, and it is reported before
## anything is launched: a typo must not open a window and then fail inside a
## worker log.  An unset or empty variable is "no choice given".
##
## NOTHING IS PUBLISHED WHEN NOTHING IS GIVEN.  The default belongs to the
## replay engine, and "no choice" is not the same as the default everywhere:
## for a Linux or macOS recording, a replay given no `--thread-sync-order`
## enforces the policy the recording declares, while one given `total` must
## agree with it or be refused (replay-worker.md, "Scope").  Writing the
## default into the environment would turn the first case into the second.
##
## ## A running window cannot take them
##
## Under the default "tab" policy, a second `ct replay` hands its trace to an
## open CodeTracer window through Electron's single-instance lock.  Only the
## argument list crosses over, and that window's replay backend was started
## with ITS environment.  So a replay that publishes a twin always opens its
## own window (`launch/launch.nim`); otherwise the option would be dropped
## without a word.
##
## PURE: a function of the given flag values and an environment lookup,
## asserted by `src/tests/cli/replay_backend_env_test.nim`; the publication
## through the real `ct` is `src/tests/cli/replay_backend_env_e2e_test.nim`.

import std/[options, strutils]

type
  ReplayBackendOption* = object
    flag*: string               ## the `ct replay` option, e.g. "--os-simulation"
    envVar*: string             ## its Rule 3 twin, read by the replay engine
    values*: seq[string]        ## the closed set of accepted values

  ReplayBackendForwarding* = object
    env*: seq[(string, string)] ## publish these for the replay process chain
    refusal*: seq[string]       ## non-empty: print and exit 1, replay nothing

const
  ThreadSyncOrderFlag* = "--thread-sync-order"
  ThreadSyncOrderEnv* = "CT_THREAD_SYNC_ORDER"
  OsSimulationFlag* = "--os-simulation"
  OsSimulationEnv* = "CT_OS_SIMULATION"

  ReplayBackendOptions* = [
    ## The value sets are the replay engine's own
    ## (`ct_cli/thread_sync_order.nim` `parseThreadSyncOrder`, and
    ## `parseReplayOsSimMode`).  They are repeated here so that a mistake is
    ## refused before any process starts; the engine checks them again.
    ReplayBackendOption(flag: ThreadSyncOrderFlag, envVar: ThreadSyncOrderEnv,
                        values: @["total", "per-object"]),
    ReplayBackendOption(flag: OsSimulationFlag, envVar: OsSimulationEnv,
                        values: @["weak-userspace", "strong-userspace",
                                  "strong-kernel"]),
  ]

proc acceptedValues(opt: ReplayBackendOption): string =
  "'" & opt.values.join("' or '") & "'"

proc checkValue(opt: ReplayBackendOption, value, source: string): string =
  ## "" when `value` is accepted, else the refusal naming `source`.
  if value in opt.values:
    return ""
  if value.len == 0:
    return "error: " & source & " requires a value (" & opt.values.join(" | ") &
      ")"
  "error: " & source & "='" & value & "' is not accepted by `ct replay " &
    opt.flag & "`; expected " & acceptedValues(opt)

proc replayBackendForwarding*(
    given: openArray[(string, Option[string])],
    lookupEnv: proc (name: string): string {.closure.}): ReplayBackendForwarding =
  ## The environment that carries `ct replay`'s replay options to the replay
  ## engine, or the refusals naming each bad value and where it came from.
  ##
  ## `given` holds, per option flag, the value written on the command line
  ## (`none` when the flag was not written).  `lookupEnv` reads the invoking
  ## environment ("" when unset); it is a parameter so the decision can be
  ## asserted without touching the process environment.
  ##
  ## A flag in `given` that this table does not know is refused by name: it
  ## would otherwise be dropped, and a dropped option is the defect this
  ## module exists to prevent.
  for (flag, _) in given:
    var known = false
    for opt in ReplayBackendOptions:
      if opt.flag == flag:
        known = true
    if not known:
      result.refusal.add("error: `ct replay " & flag & "` has no way to " &
        "reach the replay backend: it has no environment twin in " &
        "src/ct/trace/replay_backend_env.nim")

  for opt in ReplayBackendOptions:
    # Rule 3: the variable seeds.  It is checked even when the flag overrides
    # it, as the replay engine does: an invalid value is never silently
    # replaced, and the engine would see it anyway if the flag were dropped.
    let envValue = lookupEnv(opt.envVar)
    var chosen = ""
    if envValue.len > 0:
      let refusal = checkValue(opt, envValue, opt.envVar)
      if refusal.len > 0:
        result.refusal.add refusal
      else:
        chosen = envValue
    # ... and the flag wins.
    for (flag, value) in given:
      if flag == opt.flag and value.isSome:
        let refusal = checkValue(opt, value.get, opt.flag)
        if refusal.len > 0:
          result.refusal.add refusal
          chosen = ""
        else:
          chosen = value.get
    if chosen.len > 0:
      result.env.add((opt.envVar, chosen))

  # A refused invocation publishes nothing, so a caller that forgets to stop
  # on the refusal still cannot forward half of a request.
  if result.refusal.len > 0:
    result.env = @[]

type
  ReplayBackendClaim* = object
    given*: seq[(string, Option[string])]
      ## one entry per option in `ReplayBackendOptions`: the value written
      ## last, or `none` when the option was not written
    rest*: seq[string]          ## the other arguments, in their order

proc claimReplayBackendOptions*(args: openArray[string]): ReplayBackendClaim =
  ## Take this module's options out of a `ct replay` argument list that goes
  ## to another front-end (`--ui=tui`, `--ui=gpui`, `--ui=webui`), by NAME, in
  ## every spelling confutils accepts: `--flag value`, `--flag=value` and
  ## `--flag:value`.  Every other token stays where it was.
  ##
  ## Those front-ends have no slot for these options and refuse them as
  ## unknown.  They do not need one: like Electron, they reach the replay
  ## engine only through processes that inherit the environment.  So `ct`
  ## claims these options there too, and publishes their twins
  ## (`replayBackendForwarding`).  A flag written last with no value is
  ## claimed as an empty value, which the decision refuses by name.
  for opt in ReplayBackendOptions:
    result.given.add((opt.flag, none(string)))
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--":
      # Everything after a bare `--` belongs to the receiver.
      for j in i ..< args.len:
        result.rest.add args[j]
      break
    var claimed = false
    for k, opt in ReplayBackendOptions:
      if arg == opt.flag:
        if i + 1 < args.len:
          inc i
          result.given[k] = (opt.flag, some(args[i]))
        else:
          result.given[k] = (opt.flag, some(""))
        claimed = true
        break
      if arg.len > opt.flag.len and arg.startsWith(opt.flag) and
          arg[opt.flag.len] in {'=', ':'}:
        result.given[k] = (opt.flag, some(arg[opt.flag.len + 1 .. ^1]))
        claimed = true
        break
    if not claimed:
      result.rest.add arg
    inc i
