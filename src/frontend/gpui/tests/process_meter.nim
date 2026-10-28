## process_meter.nim — this process's CURRENT resident set size and the host's
## one-minute load average, on every host the `gpui-shell` lane runs on.
##
## `test_gpui_editing_surface.nim`'s large-file case bounds RSS growth while it
## scrolls a 40,000-line file. It used to read `/proc/self/statm` only, so on
## macOS — where the lane also runs — the case raised before its first scroll
## stop and asserted nothing, including the held-lines bound that needs no RSS
## at all (codetracer-pm issue 2026-10-23, "the GPUI editing-surface suite
## measures RSS only through `/proc/self/statm`").
##
## ## WHAT IS MEASURED, AND WHY NOT `getrusage`
##
## Both readers report the **current** resident size, never the peak:
##
##   * Linux: `/proc/self/statm`'s second field (`resident`, in pages), scaled
##     by the page size the kernel reports through `sysconf(_SC_PAGESIZE)`
##     rather than an assumed 4 KiB, because aarch64 kernels run with 16 KiB
##     and 64 KiB pages too.
##     https://man7.org/linux/man-pages/man5/proc_pid_statm.5.html
##   * macOS: `task_info(mach_task_self(), MACH_TASK_BASIC_INFO, …)`'s
##     `resident_size`, in bytes.
##     https://developer.apple.com/documentation/kernel/1537934-task_info
##
## `getrusage`'s `ru_maxrss` is easier to call and is deliberately NOT used: it
## is the PEAK, so "RSS does not grow while scrolling" would turn into "RSS
## never exceeded its earlier high-water mark", which a renderer that holds the
## whole file after an early spike satisfies for free.
##
## ## A HOST WITH NEITHER READER IS A FAILURE, NOT A SKIP
##
## `residentKb` raises `IOError` naming the host. A run that silently stopped
## measuring memory would be a run whose memory assertion passed for free
## (codetracer-pm `spec/Testing/Silent-Self-Pass-Audit-2026-08-23.md`).

import std/strutils
when defined(linux):
  import std/[os, posix]

when defined(macosx):
  # Module-level, because an `importc` variable declared inside a proc is
  # emitted as a C local of that name, which the SDK's macros then expand.
  type
    MachTaskBasicInfo {.importc: "struct mach_task_basic_info",
                        header: "<mach/mach.h>", bycopy.} = object
      resident_size: uint64
  var
    machTaskBasicInfo {.importc: "MACH_TASK_BASIC_INFO",
                        header: "<mach/mach.h>".}: cint
    machTaskBasicInfoCount {.importc: "MACH_TASK_BASIC_INFO_COUNT",
                             header: "<mach/mach.h>".}: cuint
    kernSuccess {.importc: "KERN_SUCCESS", header: "<mach/mach.h>".}: cint
  proc machTaskSelf(): cuint {.importc: "mach_task_self",
                               header: "<mach/mach.h>".}
  proc taskInfo(task: cuint; flavor: cint; info: pointer;
                count: ptr cuint): cint {.importc: "task_info",
                                          header: "<mach/mach.h>".}

proc residentKb*(): int {.raises: [IOError, ValueError].} =
  ## This process's current resident set size, in KiB.
  when defined(macosx):
    var info: MachTaskBasicInfo
    var count = machTaskBasicInfoCount
    let kr = taskInfo(machTaskSelf(), machTaskBasicInfo, addr info, addr count)
    if kr != kernSuccess:
      raise newException(IOError,
        "RSS cannot be measured: task_info(MACH_TASK_BASIC_INFO) returned " &
        "kern_return_t " & $kr)
    int(info.resident_size div 1024)
  elif defined(linux):
    const statm = "/proc/self/statm"
    if not fileExists(statm):
      raise newException(IOError,
        "RSS cannot be measured: " & statm & " does not exist (is /proc " &
        "mounted?), and a memory bound that stopped measuring would pass " &
        "for free.")
    let fields = readFile(statm).splitWhitespace()
    if fields.len < 2:
      raise newException(IOError, statm & " has fewer than two fields")
    let pageSize = sysconf(SC_PAGESIZE)
    if pageSize <= 0:
      raise newException(IOError,
        "RSS cannot be measured: sysconf(_SC_PAGESIZE) returned " & $pageSize)
    parseInt(fields[1]) * int(pageSize) div 1024
  else:
    raise newException(IOError,
      "RSS cannot be measured: this host (" & hostOS & ") has no resident-set " &
      "reader here. Linux reads /proc/self/statm and macOS reads " &
      "task_info(MACH_TASK_BASIC_INFO); port `residentKb` to this host rather " &
      "than letting a memory bound pass without a measurement.")

proc loadAverage1*(): string =
  ## The host's one-minute load average, for labelling a measurement taken on
  ## a shared host — or `unavailable` where `getloadavg(3)` answers nothing.
  ## A label, never an assertion input, so its absence is reported rather than
  ## raised. `getloadavg` is in both glibc and libSystem.
  ## https://man7.org/linux/man-pages/man3/getloadavg.3.html
  when defined(linux) or defined(macosx):
    proc getloadavg(loadavg: ptr cdouble; nelem: cint): cint {.
      importc, header: "<stdlib.h>".}
    var load: cdouble
    if getloadavg(addr load, 1) == 1:
      return formatFloat(float(load), ffDecimal, 2)
  "unavailable"
