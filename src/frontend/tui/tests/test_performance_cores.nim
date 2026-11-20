## test_performance_cores.nim — an rr fixture keeps the CPUs it was started on
## when they are performance cores, and runs on every performance core only
## when none of them is.
##
## `fixtures/performance_cores.preferPerformanceCores` used to replace the
## inherited affinity with every performance core. A native scenario started
## under `taskset -c 12-15` on this workspace's hybrid host (an i9-12900K:
## performance cores 0-15) widened itself back to 0-15, so `taskset` could not
## starve it, and reproducing the native flow hang under CPU starvation needed
## a cgroup quota instead (codetracer-pm `issues/2026-11-20-a-native-flow-load-
## goes-silent-for-30-s-on-a-starved-host-and-the-window-gives-up.md`, nat8).
##
## The first suite checks the rule on masks. The second runs it on this
## process's real affinity: it narrows the affinity, names the performance
## cores through a CPU-list file (the function takes the path, so the test
## needs no hybrid CPU), calls `preferPerformanceCores`, and reads the affinity
## back with `sched_getaffinity`. It restores the affinity it started with.

import std/[os, unittest]

import ./fixtures/performance_cores

proc mask(list: string): CpuMask = parseCpuList(list)

suite "performanceCoreMask":
  test "inherited performance cores are kept":
    check cpuList(performanceCoreMask(mask("12-15"), mask("0-15"))) == "12-15"

  test "inherited efficiency cores are dropped and the performance ones kept":
    check cpuList(performanceCoreMask(mask("14-19"), mask("0-15"))) == "14-15"

  test "an unconfined process gets every performance core":
    check cpuList(performanceCoreMask(mask("0-23"), mask("0-15"))) == "0-15"

  test "only efficiency cores inherited falls back to every performance core":
    check cpuList(performanceCoreMask(mask("20-23"), mask("0-15"))) == "0-15"

  test "CPU lists parse and print as the kernel writes them":
    check cpuList(mask("0-7,16,18-19")) == "0-7,16,18-19"
    check cpuList(mask("3")) == "3"
    check mask("").isEmpty

when defined(linux):
  suite "preferPerformanceCores on this process":
    let original = currentAffinity()
    var allowed: seq[int]
    for cpu in 0 ..< original.len * 64:
      if cpu in original: allowed.add cpu
    let coreList = getTempDir() / ("test_performance_cores_" & $getCurrentProcessId() & ".cpus")

    proc confinedTo(cpus: string; performance: string): string =
      ## This process's affinity after `preferPerformanceCores`, started on
      ## `cpus`, with `performance` named as the performance cores.
      setAffinity(mask(cpus))
      writeFile(coreList, performance)
      try:
        preferPerformanceCores(coreList)
        result = cpuList(currentAffinity())
      finally:
        setAffinity(original)
        removeFile(coreList)

    test "a narrowed process stays on its performance cores":
      if allowed.len < 2:
        skip()
      else:
        # Started on one allowed CPU, with every allowed CPU a performance
        # core: the old code widened this to all of them.
        let one = $allowed[0]
        check confinedTo(one, cpuList(original)) == one

    test "a process on no performance core moves to all of them":
      if allowed.len < 2:
        skip()
      else:
        # Started on one CPU, with only the other allowed CPUs named as
        # performance cores.
        var others: CpuMask
        for cpu in allowed[1 .. ^1]: others.incl cpu
        check confinedTo($allowed[0], cpuList(others)) == cpuList(others)

    test "a CPU without performance cores leaves the affinity alone":
      let before = cpuList(currentAffinity())
      preferPerformanceCores(coreList & ".absent")
      check cpuList(currentAffinity()) == before
