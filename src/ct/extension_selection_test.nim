## extension_selection_test.nim — PLAT-9's `--no-extensions` selector.
##
## §7's last bullet asks for "a single flag" that is "the recovery route when
## an extension makes the product unusable". This suite asserts the three
## things that makes true: the flag is read before anything else happens, it
## is removed from the arguments confutils then parses, and it cannot be
## inverted by a value.
##
## ## WHAT IT DOES NOT ASSERT
##
## That the decision REACHES the plugin host. That is
## `test_plugin_surfaces.nim`'s `--no-extensions produces a working debugger`
## suite, which drives a real host with `extensionsEnabled = false` and
## measures three plugins' own activation counters. This file is the argv half
## alone, in a lane that links nothing.
##
## ## NO MOCKS
##
## Every input is a `seq[string]` and an environment VALUE passed in by hand —
## the module never reads the process environment itself, which is what makes
## the environment layer assertable without touching one.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## The one assertion helper is a `template`.
##
## Compile and run:
##   nim c -r src/ct/extension_selection_test.nim

import std/[os, strutils, unittest]

import ./extension_selection

const ExpectedAssertions = 37
  ## Written from a run, and asserted against the tally below.
  ## `ci/lib/run-nim-test-lane.sh` READS this name: a file that declares
  ## it AND fails when its own tally disagrees is a file whose assertion
  ## count the lane can report, which is what keeps `OK (n tests)` from
  ## being the only evidence a suite produces.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

suite "PLAT-9: --no-extensions is read before anything is loaded":

  test "absent, the arguments are passed through byte for byte":
    let argv = @["replay", "--ui=tui", "/tmp/trace"]
    let plan = planExtensions(argv)
    ck plan.kind == epkDecided
    ck plan.enabled
    ck plan.source == esDefault
    ck plan.ctArgs == argv

  test "present, it is removed and nothing else is":
    let plan = planExtensions(@["replay", ExtensionsFlag, "--ui=tui",
                                "/tmp/trace"])
    ck plan.kind == epkDecided
    ck not plan.enabled
    ck plan.source == esFlag
    ck plan.ctArgs == @["replay", "--ui=tui", "/tmp/trace"]

  test "the flag takes no value, so it cannot be inverted by one":
    # The one invocation this flag exists for is the one where the user is
    # guessing, so `--no-extensions=false` must not quietly load them.
    for spelling in [ExtensionsFlag & "=false", ExtensionsFlag & ":0",
                     ExtensionsFlag & "=true"]:
      let plan = planExtensions(@["replay", spelling])
      ck plan.kind == epkUsageError
      ck spelling.split({'=', ':'})[0] in plan.message
      ck "takes no value" in plan.message

  test "everything after a bare -- belongs to the recorded program":
    # `ct record prog --no-extensions` passes the flag to `prog`. Turning
    # CodeTracer's plugins off is not something a recorded program's own
    # arguments get to do.
    let plan = planExtensions(@["record", "prog", "--", ExtensionsFlag])
    ck plan.kind == epkDecided
    ck plan.enabled
    ck plan.ctArgs == @["record", "prog", "--", ExtensionsFlag]
    # ... and the control: before the separator, the same token is ct's.
    let mine = planExtensions(@["record", ExtensionsFlag, "--", "prog"])
    ck not mine.enabled
    ck mine.ctArgs == @["record", "--", "prog"]

  test "the environment can disable it, and an empty value never does":
    ck not planExtensions(@["replay"], "1").enabled
    ck not planExtensions(@["replay"], "TRUE").enabled
    ck not planExtensions(@["replay"], " yes ").enabled
    ck planExtensions(@["replay"], "1").source == esEnv
    # The failure direction is "your plugins still load". An exported-but-empty
    # variable is the commonest way a shell hands a program a value nobody
    # meant, and vanishing every extension because of one would be the worse
    # of the two mistakes.
    ck planExtensions(@["replay"], "").enabled
    ck planExtensions(@["replay"], "0").enabled
    ck planExtensions(@["replay"], "no").enabled
    ck planExtensions(@["replay"], "maybe").enabled

  test "the flag wins over the environment, in both directions of surprise":
    let plan = planExtensions(@["replay", ExtensionsFlag], "0")
    ck not plan.enabled
    ck plan.source == esFlag

  test "the source is named, because 'I did not turn them off' is usually true":
    ck "environment" in describe(planExtensions(@["replay"], "1"))
    ck ExtensionsFlag in describe(planExtensions(@["replay", ExtensionsFlag]))
    ck "enabled" in describe(planExtensions(@["replay"]))

  test "the flag's spelling agrees with the one the host reports to a user":
    # `NoExtensionsFlag` is declared in `plugin_host/surface_host.nim`, which
    # this module must not import — parsing a command line does not pull in the
    # reactive host. So the two spellings are asserted to agree by READING the
    # other file, rather than by a convention somebody has to remember.
    #
    # Verification-Harness-Traps §4: a scan that finds nothing passes every
    # "must not contain" check, so the assertion is on the EXTRACTED value and
    # the extraction is required to have found exactly one.
    let source = readFile("src/frontend/viewmodel/plugin_host/surface_host.nim")
    var found: seq[string] = @[]
    for line in source.splitLines():
      let t = line.strip()
      if t.startsWith("NoExtensionsFlag* = "):
        found.add t["NoExtensionsFlag* = ".len .. ^1].strip(chars = {'"'})
    ck found.len == 1
    ck found == @[ExtensionsFlag]

suite "PLAT-9: the counted-assertion tally":

  test "the tally":
    check countedAssertions == ExpectedAssertions
