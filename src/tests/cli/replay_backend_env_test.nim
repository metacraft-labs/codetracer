## replay_backend_env_test.nim
##
## `ct replay`'s replay-engine options reach the native replay backend as
## their Rule 3 environment twins, and a bad value is refused by name before
## anything is launched -- codetracer-specs `CLI/ct/replay.md`, "Options", and
## `CLI/ct-mcr/replay-worker.md`, "Ordering granularity".
##
## Mocking justification (workspace policy on mock objects): the invoking
## environment is passed in as a lookup over a table instead of the process
## environment, so each row sees exactly the variables it names and no row can
## leak a variable into the next.  The production decision is called
## directly; nothing of it is replaced.  The end-to-end half -- that the
## SHIPPED `ct replay` publishes the decision to the process it launches -- is
## `src/tests/cli/replay_backend_env_e2e_test.nim`.
##
## Compile and run:
##   nim c -r src/tests/cli/replay_backend_env_test.nim

import std/[options, strutils, tables, unittest]
import ../../ct/trace/replay_backend_env

proc envOf(pairs: openArray[(string, string)]): proc (name: string): string =
  let t = pairs.toTable
  result = proc (name: string): string = t.getOrDefault(name, "")

proc forward(threadSyncOrder = none(string); osSimulation = none(string);
             env: openArray[(string, string)] = []): ReplayBackendForwarding =
  replayBackendForwarding(
    [(ThreadSyncOrderFlag, threadSyncOrder), (OsSimulationFlag, osSimulation)],
    envOf(env))

suite "ct replay: replay-engine options travel as environment twins":
  test "nothing given publishes nothing (the engine's default applies)":
    let f = forward()
    check f.refusal.len == 0
    check f.env.len == 0

  test "--thread-sync-order=per-object is CT_THREAD_SYNC_ORDER=per-object":
    let f = forward(threadSyncOrder = some("per-object"))
    check f.refusal.len == 0
    check f.env == @[("CT_THREAD_SYNC_ORDER", "per-object")]

  test "--thread-sync-order=total is published, not dropped as the default":
    # On a Linux or macOS recording an explicit `total` must agree with the
    # recording, while no value means "the declared policy": the two are
    # different requests, so an explicit default is forwarded.
    let f = forward(threadSyncOrder = some("total"))
    check f.refusal.len == 0
    check f.env == @[("CT_THREAD_SYNC_ORDER", "total")]

  test "every --os-simulation mode is CT_OS_SIMULATION=<mode>":
    for mode in ["weak-userspace", "strong-userspace", "strong-kernel"]:
      let f = forward(osSimulation = some(mode))
      check f.refusal.len == 0
      check f.env == @[("CT_OS_SIMULATION", mode)]

  test "both at once":
    let f = forward(some("per-object"), some("strong-userspace"))
    check f.refusal.len == 0
    check ("CT_THREAD_SYNC_ORDER", "per-object") in f.env
    check ("CT_OS_SIMULATION", "strong-userspace") in f.env
    check f.env.len == 2

suite "ct replay: Rule 3 -- the variable seeds, the flag wins":
  test "the variable alone is forwarded":
    let f = forward(env = {"CT_THREAD_SYNC_ORDER": "per-object",
                           "CT_OS_SIMULATION": "strong-kernel"})
    check f.refusal.len == 0
    check ("CT_THREAD_SYNC_ORDER", "per-object") in f.env
    check ("CT_OS_SIMULATION", "strong-kernel") in f.env

  test "the flag overrides the variable":
    let f = forward(threadSyncOrder = some("total"),
                    osSimulation = some("weak-userspace"),
                    env = {"CT_THREAD_SYNC_ORDER": "per-object",
                           "CT_OS_SIMULATION": "strong-kernel"})
    check f.refusal.len == 0
    check f.env == @[("CT_THREAD_SYNC_ORDER", "total"),
                     ("CT_OS_SIMULATION", "weak-userspace")]

  test "an empty variable is no choice":
    let f = forward(env = {"CT_THREAD_SYNC_ORDER": "", "CT_OS_SIMULATION": ""})
    check f.refusal.len == 0
    check f.env.len == 0

suite "ct replay: a bad value is refused by name and nothing is published":
  test "a bad flag value names the flag and the accepted values":
    let f = forward(threadSyncOrder = some("global"))
    check f.env.len == 0
    check f.refusal.len == 1
    check "--thread-sync-order='global'" in f.refusal[0]
    check "'total' or 'per-object'" in f.refusal[0]

  test "a bad variable names the variable":
    let f = forward(env = {"CT_OS_SIMULATION": "strong"})
    check f.env.len == 0
    check f.refusal.len == 1
    check "CT_OS_SIMULATION='strong'" in f.refusal[0]
    check "'weak-userspace' or 'strong-userspace' or 'strong-kernel'" in
      f.refusal[0]

  test "a bad variable is refused even when the flag would override it":
    # As the replay engine does: an invalid value is never silently replaced.
    let f = forward(threadSyncOrder = some("total"),
                    env = {"CT_THREAD_SYNC_ORDER": "PER-OBJECT"})
    check f.env.len == 0
    check f.refusal.len == 1
    check "CT_THREAD_SYNC_ORDER='PER-OBJECT'" in f.refusal[0]

  test "an empty flag value is refused, not read as no choice":
    let f = forward(osSimulation = some(""))
    check f.env.len == 0
    check f.refusal.len == 1
    check "--os-simulation requires a value" in f.refusal[0]

  test "one bad option publishes neither, so half a request never travels":
    let f = forward(threadSyncOrder = some("per-object"),
                    osSimulation = some("weak"))
    check f.env.len == 0
    check f.refusal.len == 1
    check "--os-simulation='weak'" in f.refusal[0]

  test "an option without a twin is refused by name, never dropped":
    let f = replayBackendForwarding([("--bootstrap", some("stage0"))],
                                    envOf([]))
    check f.env.len == 0
    check f.refusal.len == 1
    check "ct replay --bootstrap" in f.refusal[0]
    check "environment twin" in f.refusal[0]

suite "ct replay --ui=<other front-end>: the options are claimed by name":
  # The `--ui=tui|gpui|webui` handoffs give the other front-end what is left
  # of the argument list; these options are taken out first and published as
  # their twins (`codetracer.nim`, `handoffReplayArgs`).
  test "every confutils spelling is claimed, and the rest keeps its order":
    let c = claimReplayBackendOptions(["--goto=200",
      "--thread-sync-order", "per-object", "/traces/a",
      "--os-simulation=strong-kernel", "--no-color"])
    check c.rest == @["--goto=200", "/traces/a", "--no-color"]
    check c.given == @[("--thread-sync-order", some("per-object")),
                       ("--os-simulation", some("strong-kernel"))]
    let colon = claimReplayBackendOptions(["--thread-sync-order:total"])
    check colon.rest.len == 0
    check colon.given[0] == ("--thread-sync-order", some("total"))

  test "an argument list without them is untouched and claims nothing":
    let c = claimReplayBackendOptions(["/traces/a", "--theme=light"])
    check c.rest == @["/traces/a", "--theme=light"]
    check c.given == @[("--thread-sync-order", none(string)),
                       ("--os-simulation", none(string))]

  test "a name that only starts like an option is not claimed":
    let c = claimReplayBackendOptions(["--os-simulation-extra=1"])
    check c.rest == @["--os-simulation-extra=1"]
    check c.given[1] == ("--os-simulation", none(string))

  test "a claimed option is decided like the flag it is":
    let good = claimReplayBackendOptions(["--thread-sync-order", "per-object"])
    check replayBackendForwarding(good.given, envOf([])).env ==
      @[("CT_THREAD_SYNC_ORDER", "per-object")]
    # Written last with no value: claimed as empty, refused by name.
    let bare = claimReplayBackendOptions(["/traces/a", "--os-simulation"])
    check bare.rest == @["/traces/a"]
    let f = replayBackendForwarding(bare.given, envOf([]))
    check f.env.len == 0
    check f.refusal.len == 1
    check "--os-simulation requires a value" in f.refusal[0]

  test "nothing after a bare `--` is claimed":
    let c = claimReplayBackendOptions(["/traces/a", "--",
                                       "--thread-sync-order=total"])
    check c.rest == @["/traces/a", "--", "--thread-sync-order=total"]
    check c.given[0] == ("--thread-sync-order", none(string))

suite "ct replay: the twin table":
  test "every twin is the CT_ spelling of its flag (Rule 3)":
    for opt in ReplayBackendOptions:
      check opt.flag.startsWith("--")
      check opt.envVar ==
        "CT_" & opt.flag[2 .. ^1].replace("-", "_").toUpperAscii
      check opt.values.len > 0

  test "the value sets are the replay engine's":
    # `ct_cli/thread_sync_order.nim` parseThreadSyncOrder and
    # `parseReplayOsSimMode` (codetracer-specs CLI/ct-mcr/replay-worker.md).
    check ReplayBackendOptions[0].flag == ThreadSyncOrderFlag
    check ReplayBackendOptions[0].values == @["total", "per-object"]
    check ReplayBackendOptions[1].flag == OsSimulationFlag
    check ReplayBackendOptions[1].values ==
      @["weak-userspace", "strong-userspace", "strong-kernel"]
