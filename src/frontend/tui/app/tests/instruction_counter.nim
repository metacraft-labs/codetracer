## instruction_counter.nim — count the user-space instructions this thread
## retires over a block of code, for a performance gate that has to hold on a
## shared host.
##
## A gate on time measures the host as well as the code: on a 24-core machine
## shared with CI runners, the palette's best-of-nine CPU time moved from 6.0 ms
## at load 27 to 9.7 ms at load 99 with the matcher unchanged (codetracer-pm
## issue 2026-10-31-palette-fuzzy-gate-cpu-time-still-moves-with-host-contention).
## CPU time leaves out the time spent waiting for a CPU, but not the time an SMT
## sibling or a shared cache takes from the instructions that do run. The number
## of instructions retired does not depend on either: it moves when the work
## does.
##
## Linux only, through `perf_event_open(2)` (`PERF_COUNT_HW_INSTRUCTIONS`, user
## space only, this thread). On a hybrid CPU the kernel publishes one PMU per
## core type (`/sys/bus/event_source/devices/cpu_core` and `cpu_atom`), and a
## generic hardware event counts only on one of them, so one event is opened per
## core type and the counts are added: a thread the scheduler moves between the
## two is counted on both. `open` returns a counter that is not `available` when
## the kernel refuses (`perf_event_paranoid` 3, no PMU in a VM), off Linux, or
## when no PMU accepts the event; the caller decides what to fall back to.

import std/[os, strutils]

type
  InstructionCounter* = object
    fds: seq[cint]

when defined(linux):
  {.emit: """/*INCLUDESECTION*/
#include <linux/perf_event.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <string.h>
#include <unistd.h>
""".}
  {.emit: """
static int ct_open_instruction_counter(unsigned long long pmuType) {
  struct perf_event_attr attr;
  memset(&attr, 0, sizeof attr);
  attr.size = sizeof attr;
  attr.type = PERF_TYPE_HARDWARE;
  attr.config = (pmuType << 32) | PERF_COUNT_HW_INSTRUCTIONS;
  attr.disabled = 1;
  attr.exclude_kernel = 1;
  attr.exclude_hv = 1;
  return (int)syscall(__NR_perf_event_open, &attr, 0, -1, -1, 0);
}
static int ct_counter_reset_enable(int fd) {
  if (ioctl(fd, PERF_EVENT_IOC_RESET, 0) != 0) return -1;
  return ioctl(fd, PERF_EVENT_IOC_ENABLE, 0);
}
static int ct_counter_disable(int fd) {
  return ioctl(fd, PERF_EVENT_IOC_DISABLE, 0);
}
static long long ct_counter_read(int fd) {
  long long value = 0;
  if (read(fd, &value, sizeof value) != (ssize_t)sizeof value) return -1;
  return value;
}
static void ct_counter_close(int fd) { close(fd); }
""".}
  proc ctOpenInstructionCounter(pmuType: culonglong): cint
    {.importc: "ct_open_instruction_counter", nodecl.}
  proc ctCounterResetEnable(fd: cint): cint
    {.importc: "ct_counter_reset_enable", nodecl.}
  proc ctCounterDisable(fd: cint): cint
    {.importc: "ct_counter_disable", nodecl.}
  proc ctCounterRead(fd: cint): clonglong
    {.importc: "ct_counter_read", nodecl.}
  proc ctCounterClose(fd: cint)
    {.importc: "ct_counter_close", nodecl.}

  proc hybridPmuTypes(): seq[culonglong] =
    ## The PMU type of each core type on a hybrid CPU; empty on any other.
    for name in ["cpu_core", "cpu_atom"]:
      let path = "/sys/bus/event_source/devices" / name / "type"
      if fileExists(path):
        try: result.add culonglong(parseInt(readFile(path).strip()))
        except ValueError: discard

proc available*(c: InstructionCounter): bool = c.fds.len > 0

proc close*(c: var InstructionCounter) =
  when defined(linux):
    for fd in c.fds: ctCounterClose(fd)
  c.fds = @[]

proc openInstructionCounter*(): InstructionCounter =
  ## A counter for this thread, or one that is not `available` (see the module
  ## comment). On a hybrid CPU, one event per core type or none at all: a count
  ## from one core type alone would be short whenever the thread ran on the
  ## other.
  when defined(linux):
    let types = hybridPmuTypes()
    if types.len == 0:
      let fd = ctOpenInstructionCounter(0)
      if fd >= 0: result.fds.add fd
    else:
      for t in types:
        let fd = ctOpenInstructionCounter(t)
        if fd < 0:
          result.close()
          return
        result.fds.add fd

proc start*(c: InstructionCounter): bool =
  ## Zero and start every event; false when one refused.
  when defined(linux):
    for fd in c.fds:
      if ctCounterResetEnable(fd) != 0: return false
    c.fds.len > 0
  else:
    false

proc stop*(c: InstructionCounter): int64 =
  ## Stop the events and return the instructions they counted since `start`,
  ## or -1 when one could not be read.
  when defined(linux):
    for fd in c.fds:
      if ctCounterDisable(fd) != 0: return -1
    for fd in c.fds:
      let value = ctCounterRead(fd)
      if value < 0: return -1
      result += int64(value)
  else:
    -1
