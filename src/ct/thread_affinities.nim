{.pragma: sched_h, importc, header: "sched.h".}

type
  cpu_set_t* {.sched_h.} = object

proc CPU_ZERO(set: var cpu_set_t) {.sched_h.}
proc CPU_SET(cpu: int, set: var cpu_set_t) {.sched_h.}

proc sched_setaffinity*(pid: int,
                        cpusetsize: csize_t,
                        mask: var cpu_set_t): cint {.sched_h.}

proc zeroCpuSet*: cpu_set_t =
  CPU_ZERO(result)

proc enableCpu*(s: var cpu_set_t, cpu: int) =
  CPU_SET(cpu, s)

proc setAffinityToCoreRanges*(ranges: varargs[Slice[int]]): bool =
  var mask = zeroCpuSet()
  for r in ranges:
    for i in r:
      mask.enableCpu(i)
  sched_setaffinity(0, csize_t sizeof(cpu_set_t), mask) == 0
