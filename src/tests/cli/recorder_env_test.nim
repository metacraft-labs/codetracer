## recorder_env_test.nim
##
## `ct record`'s recorder options reach ct-mcr through the environment, never
## as flags -- codetracer-specs `CLI/ct/record.md`, "Recorder options".  A
## flag appended for the recorder travels behind `--` to the recorded program
## (`db-backend-record` -> `ct-native-replay` -> `ct-mcr record -o X --
## <program> <args>`); that is how `--use-interpose` never reached it.
##
## Mocking justification (workspace policy on mock objects): none.  The
## production table and its lookup are called directly.  The end-to-end half
## -- that the variables arrive through the real chain and the program's argv
## is untouched -- is `src/tests/cli/recorder_env_e2e_test.nim`.
##
## Compile and run:
##   nim c -r src/tests/cli/recorder_env_test.nim

import std/[strutils, unittest]
import ../../ct/trace/recorder_env
import ../../ct/trace/portable_route

suite "ct record: recorder options travel as environment twins":
  test "--use-interpose is CT_INTERPOSE=on":
    let f = recorderForwarding(["--use-interpose"])
    check f.refusal.len == 0
    check f.env == @[("CT_INTERPOSE", "on")]

  test "--portable is CT_PORTABLE=on, and portable_route uses the table":
    check recorderForwarding(["--portable"]).env == @[("CT_PORTABLE", "on")]
    let r = portableRoute(false, "", "mcr", true, "", false)
    check r.env == recorderForwarding(["--portable"]).env

  test "both at once":
    let f = recorderForwarding(["--use-interpose", "--portable"])
    check f.refusal.len == 0
    check ("CT_INTERPOSE", "on") in f.env
    check ("CT_PORTABLE", "on") in f.env

  test "an option without a twin is refused by name, never forwarded":
    let f = recorderForwarding(["--hook-debug"])
    check f.env.len == 0
    check f.refusal.len == 1
    check "ct record --hook-debug" in f.refusal[0]
    check "environment twin" in f.refusal[0]

  test "every twin is a CT_ variable with a value":
    for (name, envVar, value) in RecorderEnvTwins:
      check name.startsWith("--")
      check envVar.startsWith("CT_")
      check value.len > 0
