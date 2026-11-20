## performance_cores.nim — the CPUs an rr fixture runs on, on a hybrid Intel CPU.
##
## rr cannot replay a recording whose tracee migrated between a performance
## core and an efficiency core: their performance counters differ. On a hybrid
## CPU the kernel publishes the performance cores at
## `/sys/devices/cpu_core/cpus`, and `preferPerformanceCores` confines this
## process to them before it records or replays. Children inherit the mask, and
## the rr that replays runs below `replay-server` below this process, so this
## covers record and replay alike.
##
## It keeps the affinity it was started with, narrowed to the performance
## cores. It used to replace the inherited affinity with every performance
## core, so a run started under `taskset -c 12-15` widened itself back to
## 0-15. That made the native flow hang's CPU-starvation reproduction
## (codetracer-pm `issues/2026-11-20-a-native-flow-load-goes-silent-for-30-s-
## on-a-starved-host-and-the-window-gives-up.md`) impossible with `taskset`.
## Only when the inherited CPUs include no performance core does it fall back
## to all of them, because then the caller asked for something rr cannot use.

import std/[os, strutils]

type CpuMask* = array[128, uint64]
  ## A `cpu_set_t` of 8192 CPUs: as large as any kernel's `nr_cpu_ids`, which
  ## `sched_getaffinity` requires the buffer to cover.

proc incl*(mask: var CpuMask; cpu: int) =
  mask[cpu div 64] = mask[cpu div 64] or (1'u64 shl (cpu mod 64))

proc contains*(mask: CpuMask; cpu: int): bool =
  (mask[cpu div 64] and (1'u64 shl (cpu mod 64))) != 0

proc isEmpty*(mask: CpuMask): bool =
  for word in mask:
    if word != 0: return false
  true

proc `*`*(a, b: CpuMask): CpuMask =
  ## The CPUs in both masks.
  for i in 0 ..< a.len: result[i] = a[i] and b[i]

proc parseCpuList*(text: string): CpuMask =
  ## A kernel CPU list (`0-7,16,18-19`), as in `/sys/devices/*/cpus`.
  for part in text.strip().split(','):
    if part.len == 0: continue
    let bounds = part.split('-')
    for cpu in parseInt(bounds[0]) .. parseInt(bounds[^1]):
      result.incl cpu

proc cpuList*(mask: CpuMask): string =
  ## `mask` as a kernel CPU list, ranges collapsed.
  var cpu = 0
  while cpu < mask.len * 64:
    if cpu in mask:
      var last = cpu
      while last + 1 < mask.len * 64 and (last + 1) in mask: inc last
      if result.len > 0: result.add ','
      result.add $cpu
      if last > cpu: result.add "-" & $last
      cpu = last + 1
    else:
      inc cpu

proc performanceCoreMask*(inherited, performance: CpuMask): CpuMask =
  ## The CPUs to run on: the inherited ones that are performance cores, or
  ## every performance core when none of the inherited ones is.
  result = inherited * performance
  if result.isEmpty: result = performance

when defined(linux):
  proc schedGetAffinity(pid: cint; size: csize_t; mask: ptr CpuMask): cint
    {.importc: "sched_getaffinity", cdecl.}
  proc schedSetAffinity(pid: cint; size: csize_t; mask: ptr CpuMask): cint
    {.importc: "sched_setaffinity", cdecl.}

  proc currentAffinity*(): CpuMask =
    if schedGetAffinity(0, csize_t(sizeof(result)), addr result) != 0:
      raise newOSError(osLastError(), "reading this process's CPU affinity")

  proc setAffinity*(mask: CpuMask) =
    var m = mask
    if schedSetAffinity(0, csize_t(sizeof(m)), addr m) != 0:
      raise newOSError(osLastError(), "setting this process's CPU affinity to " & cpuList(mask))

proc preferPerformanceCores*(coreList = "/sys/devices/cpu_core/cpus") =
  ## Confine this process to the performance cores it may run on (see the
  ## module header). Nothing on a CPU with one kind of core: the kernel
  ## publishes `cpu_core` only on a hybrid one. `coreList` is a parameter so a
  ## test can name the performance cores.
  when defined(linux):
    if not fileExists(coreList): return
    let wanted = performanceCoreMask(currentAffinity(), parseCpuList(readFile(coreList)))
    try:
      setAffinity(wanted)
    except OSError as e:
      raise newException(OSError, "confining the rr fixture to " & coreList & ": " & e.msg, e)
