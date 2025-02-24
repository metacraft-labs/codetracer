# {.pragma: sched_h, importc, header: "sched.h".}

# type
#   cpu_set_t* {.sched_h.} = object

# proc CPU_ZERO(set: var cpu_set_t) {.sched_h.}
# proc CPU_SET(cpu: int, set: var cpu_set_t) {.sched_h.}

# proc sched_setaffinity*(pid: int,
#                         cpusetsize: csize_t,
#                         mask: var cpu_set_t): cint {.sched_h.}

# proc zeroCpuSet*: cpu_set_t =
#   CPU_ZERO(result)

# proc enableCpu*(s: var cpu_set_t, cpu: int) =
#   CPU_SET(cpu, s)

# proc setAffinityToCoreRanges*(ranges: varargs[Slice[int]]): bool =
#   var mask = zeroCpuSet()
#   for r in ranges:
#     for i in r:
#       mask.enableCpu(i)
#   sched_setaffinity(0, csize_t sizeof(cpu_set_t), mask) == 0

# # but this is linux/rr only specific!
# proc cpuidImpl(level: int, eax, ebx, ecx, edx: var uint32): int {.importc: "__get_cpuid", header: "cpuid.h".}

# proc cpuid*: uint32 =
#   var eax, ebx, ecx, edx: uint32
#   if cpuidImpl(1, eax, ebx, ecx, edx) == 1:
#     # Mask out the family and model bits
#     eax and 0xFFFF0
#   else:
#     0

# const cpuidAlderLake* = 0x906C0
# const cpuidRaptorLake* = 0xB0670

proc workaroundIntelECoreProblem* =
  discard 
  # TODO: enable this or move this to rr/gdb backend
  # it's linux specific currently
  # and it's needed for rr only

  # let cpu = cpuid()
  # if cpu in [cpuidAlderLake, cpuidRaptorLake]:
  #   # TODO:
  #   # This solution is very far from ideal.
  #   #
  #   # We are pinning the current process only to the performance
  #   # cores of the high-end Alder Lake and Raptor Lake CPUs used
  #   # by the Metacraft Labs development team.
  #   #
  #   # Ideally, this issue will be soon fixed by upstream RR, where
  #   # it's possible to similarly detect the CPU and apply the right
  #   # affinitiy mask only to the RR process and its children:
  #   #
  #   # https://github.com/rr-debugger/rr/issues/3338
  #   #
  #   # With fork/execve, it's also possible to not change the thread
  #   # affinity of the CodeTracer process as it's done in the taskset
  #   # utility:
  #   #
  #   # https://github.com/util-linux/util-linux/blob/master/schedutils/taskset.c
  #   #
  #   # ... or we can just launch RR through the taskset utility here,
  #   # but since this should be a temporary solution, I've opted for
  #   # the current fix introducing minimal new dependencies.
  #   if not setAffinityToCoreRanges(0..15):
  #     echo "warn: Failed to set thread affinity. " &
  #          "The next RR execution may be scheduled on an E-Core which lacks the" &
  #          "necessary performance counters and this may results in an error."
