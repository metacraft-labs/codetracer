# Cooperative-domain Nim flow program for MCR cooperative record/replay.
#
# WHY THIS EXISTS SEPARATELY FROM nim_flow_test.nim
# -------------------------------------------------
# Cooperative capture can only see syscalls issued from the TRACEE'S OWN
# IMAGE.  The hook is installed by rebinding the main executable's indirect
# symbol table (fishhook), and dyld strips the indirect symbol table from
# dyld-shared-cache images, so a call site inside libsystem_c is permanently
# out of reach.  See
# codetracer-specs/Recording-Backends/Multi-Core-Recorder/MCR-Cooperative-Mobile.md
# ("Why cooperative mode exists" / "The capability boundary").
#
# `nim_flow_test.nim` reaches libc for its I/O: `echo` goes through Nim's
# `c_fwrite`/`c_putc`, whose `write(2)` is issued from inside libsystem_c.  That
# program is therefore NOT a valid cooperative target — measured, it records
# exactly two events (one `evThreadStart` plus its orphan `evVerifyArgHash`
# companion) no matter how much it prints.  That is the boundary working as
# designed, not a recorder defect, so it must not be "fixed" by hooking the
# stdio family.
#
# This program is the same computation with its I/O put back inside the
# cooperative domain: every byte of output is formatted in-image and handed to
# a single direct `write(2)` whose call site is in the main executable.  A
# fully statically-linked binary would have the same property, but macOS ships
# no static libc (no `libSystem.a`, no `crt0.o`; `clang -static` fails to
# link), so "issue the syscall from your own image" is the reachable form of
# that property on Darwin.
#
# The printed text and every local's value match `nim_flow_test.nim`, so the
# two programs stay comparable.  `nim_flow_test.nim` is left alone: it is the
# fixture for the DAP/flow tests (breakpoint line 13, `echo` in the
# excluded-identifier set), and those tests want the libc call sites.
#
# Deliberately allocation-free on the output path: no `echo`, no `$`, no string
# building.  Formatting is hand-rolled into a stack buffer so the recorded event
# stream is exactly one `evOsWrite` per printed line and nothing else.  (The
# cooperative build compiles this with `--mm:none`, so avoiding the allocator
# here also keeps the program's heap out of the replay-symmetry picture.)

proc ctWrite(fd: cint; buf: pointer; count: csize_t): int
  {.importc: "write", header: "<unistd.h>".}

proc ctExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

proc appendStr(buf: var array[64, char]; pos: int; s: string): int =
  result = pos
  for ch in s:
    buf[result] = ch
    inc result

proc appendInt(buf: var array[64, char]; pos: int; v: int): int =
  result = pos
  var tmp: array[24, char]
  var n = 0
  var u: uint64
  if v < 0:
    buf[result] = '-'
    inc result
    u = uint64(-v)
  else:
    u = uint64(v)
  while true:
    tmp[n] = char(ord('0') + int(u mod 10'u64))
    inc n
    u = u div 10'u64
    if u == 0'u64: break
  while n > 0:
    dec n
    buf[result] = tmp[n]
    inc result

# One line out, one `write(2)` in.  A short or failed write is a hole in both
# the program's output and the recorded stream, so it exits loudly rather than
# being dropped on the floor.
proc emit(label: string; value: int) =
  var buf: array[64, char]
  var n = appendStr(buf, 0, label)
  n = appendInt(buf, n, value)
  buf[n] = '\n'
  inc n
  if ctWrite(1.cint, addr buf[0], csize_t(n)) != n:
    ctExit(70.cint)

proc calculateSum(a: int, b: int): int =
  # Local variables inside a proc - these should NOT be mangled
  let sum = a + b
  let doubled = sum * 2
  let final = doubled + 10
  emit("Sum: ", sum)
  emit("Doubled: ", doubled)
  emit("Final: ", final)
  return final

proc main() =
  # Local variables in main proc
  let x = 10
  let y = 32
  let result = calculateSum(x, y)
  emit("Result: ", result)

# Call main
main()
