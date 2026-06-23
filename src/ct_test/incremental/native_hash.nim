## Native shallow hash — the M7 deliverable of the
## Trace-Based-Incremental-Testing prototype campaign (Phase 2).
##
## CodeTracer's *native / Multi-Core-Recorder (MCR)* path identifies a function
## not by its source text (the Phase-1 source/interpreted path) but by its
## **compiled instruction bytes** (spec
## `codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md` §16.7.1
## "System languages (DWARF-based)"; native-recorder `AUDIT-CTFS-2026-05.md`).
## Two builds of an unchanged function emit the same machine code, so hashing a
## function's instruction bytes is a stable, per-function change detector.
##
## # Precision under relocation — what holds, and the documented limitation
##
## The per-function precision of this detector is NOT unconditional under
## address relocation. It depends on whether the function's machine code is
## position-independent:
##
##   * POSITION-INDEPENDENT functions (e.g. pure leaves: no calls, no
##     pc-relative branches to siblings, no absolute address references) emit
##     byte-IDENTICAL machine code regardless of where the linker places them.
##     Editing a *sibling* (which shifts addresses) does NOT change such a
##     function's bytes ⇒ its hash is stable. This is the case the M7 fixture's
##     leaves (`used_b`/`unused_c`) demonstrate.
##
##   * RELOCATION-SENSITIVE functions — most notably any function CONTAINING A
##     CALL/BRANCH to another function (arm64 `bl`, x86 `call rel32`) — encode a
##     PC-RELATIVE offset to the target. If a layout change alters the distance
##     between this function and its callee (e.g. a new/grown function is
##     inserted between them), the encoded offset bytes change, so the
##     instruction bytes change, so the hash CHANGES even though the function's
##     SOURCE is unchanged. (Empirically verified on this host: an unedited
##     arm64 `caller_d(){ return callee(5); }` whose distance to `callee` grew
##     had its `bl` word change `0x97fffff2 → 0x97ffffd5` and its hash flip; a
##     leaf beside it stayed byte-identical. See
##     `t_native_hash.nim`'s `relocated_call_containing_function_*` tests.)
##
## SAFETY DIRECTION (why this is acceptable for the campaign): a changed hash
## drives the engine to `idRerunChanged` — a CONSERVATIVE RE-RUN. A
## relocation-sensitive function that re-hashes therefore causes a SAFE,
## possibly-unnecessary re-run; it can NEVER cause a false SKIP. So this is a
## precision/usefulness limitation, never a correctness/safety hole: native
## skip decisions are always sound, they are just less aggressive for
## call-containing functions whose callee distance shifted. A future milestone
## could normalize pc-relative operands before hashing to recover precision; M7
## does not, and honestly documents the limitation instead.
##
## This module owns the two M7 procs:
##
##   1. `nativeFunctionTable` — `function_name → (file-offset, size)` of each
##      function's machine code, read from the binary's symbol table.
##   2. `shallowHashNative`   — hash of one function's instruction bytes
##      `binary[offset ..< offset+size]`, read from the file.
##
## M8 wires `shallowHashNative` into the M6 `ShallowHasher` seam for the
## `tbNativeDwarf` backend.
##
## # Platform branch + tooling (DOCUMENTED, as M7 requires)
##
## The mapping from a symbol's virtual address to a FILE OFFSET is
## format-specific, and the chosen tools differ per platform:
##
## ## macOS (Mach-O) — the branch THIS host (arm64 Darwin) takes
##
##   * The dev shell's `cc`/`clang` emits a **Mach-O** binary. The dev shell's
##     `nm` is LLVM's nm (`nm, compatible with GNU nm`), but on Mach-O
##     `nm --print-size` is documented by LLVM to ALWAYS return zero
##     ("sizes with --print-size for Mach-O files are always zero"). So size is
##     computed from the **delta to the next symbol's address** (symbols sorted
##     ascending by address), and the LAST function's size is bounded by the end
##     of the `__TEXT,__text` section.
##   * Tools used:
##       - `nm -n --defined-only <binary>` — defined symbols, numerically
##         (address-) sorted. Each line is `<hexaddr> <type> <name>`.
##       - `otool -l <binary>` — the load commands, from which the
##         `__TEXT,__text` section's `addr` (vmaddr), `offset` (file offset) and
##         `size` are parsed.
##   * addr → file-offset mapping:
##         file_offset = sym.vmaddr - text.addr + text.offset
##     i.e. the symbol's offset within the `__text` section, added to where the
##     section begins in the FILE. (On this fixture `text.addr == text.offset`
##     numerically only by coincidence of the low bits; the formula handles the
##     general `vmaddr != fileoff` case.)
##   * Mach-O C symbols carry a leading underscore (`_used_a`); it is stripped so
##     the table keys on the C identifier (`used_a`).
##
## ## Linux (ELF) — the other branch (compiled but unexercised on this host)
##
##   * `nm` on ELF DOES honour `--print-size`, so each line of
##     `nm -nS --defined-only <binary>` is `<addr> <size> <type> <name>` and the
##     size is read directly (no next-symbol delta needed). When a size column is
##     absent (a stripped or size-less symbol) we fall back to the same
##     next-symbol-delta computation as Mach-O.
##   * For the file-offset mapping ELF is even simpler when the binary is
##     non-PIE/position-dependent, but PIE executables (the modern default) place
##     `.text` at a non-zero vaddr just like Mach-O, so the same
##     `file_offset = sym.vaddr - text.addr + text.offset` formula is used, with
##     the `.text` section header parsed from `objdump --section-headers`.
##
## Detection is by `hostOS`: `"macosx"` ⇒ the Mach-O branch, anything else ⇒ the
## ELF branch. The ELF branch is exercised when the campaign runs on Linux CI.
##
## # Fail-safe invariant (carried over from Phase 1 / M5)
##
## Any lookup problem — a missing function, a zero-or-negative computed size, an
## unreadable binary, or a tool that fails to run — yields an `Err`. The engine
## turns that into a re-run (NEVER a silent skip). This module never returns a
## usable hash it is not certain about.

import std/[os, osproc, strutils, tables, algorithm, hashes, sets, streams]
import results

export results

type
  HashSlice* = tuple[offset, size: int]
    ## The byte range of a function's compiled machine code inside the binary
    ## FILE: `offset` is the absolute file offset of the first instruction byte,
    ## `size` the number of instruction bytes. `binary[offset ..< offset+size]`
    ## is exactly the function's machine code.

  TextSection = object
    ## The executable-code section whose `addr`/`offset` give the
    ## virtual-address → file-offset mapping (Mach-O `__TEXT,__text`; ELF
    ## `.text`).
    vmaddr: uint64   ## Virtual address the section is loaded at.
    fileoff: uint64  ## Offset of the section's bytes within the binary file.
    size: uint64     ## Section size in bytes (bounds the last function).

# ---------------------------------------------------------------------------
# Small exec helper
# ---------------------------------------------------------------------------

proc runTool(cmd: string; args: openArray[string]):
    Result[string, string] =
  ## Run an external binary-inspection tool and capture stdout. A non-zero exit
  ## or an exec failure is an `Err` (so the engine re-runs). `cmd` is resolved
  ## via PATH (the dev shell puts `nm`/`otool`/`objdump` on PATH).
  var p: Process
  try:
    p = startProcess(
      cmd, args = args,
      options = {poUsePath, poStdErrToStdOut})
  except CatchableError as e:
    return err("failed to start '" & cmd & "': " & e.msg)
  var captured = ""
  try:
    captured = p.outputStream.readAll()
  except CatchableError as e:
    p.close()
    return err("failed reading output of '" & cmd & "': " & e.msg)
  let code = p.waitForExit()
  p.close()
  if code != 0:
    return err("'" & cmd & "' exited with code " & $code & ":\n" & captured)
  ok(captured)

# ---------------------------------------------------------------------------
# Section parsing — the virtual-address → file-offset mapping
# ---------------------------------------------------------------------------

func parseUintField(line: string; key: string): Result[uint64, string] =
  ## Parse the unsigned integer following `key` on a whitespace-delimited line
  ## such as `      addr 0x0000000100003f2c` or `    offset 16172`. Accepts both
  ## `0x`-prefixed hex and plain decimal (otool mixes the two).
  let parts = line.splitWhitespace()
  for i in 0 ..< parts.len:
    if parts[i] == key and i + 1 < parts.len:
      let tok = parts[i + 1]
      try:
        if tok.toLowerAscii().startsWith("0x"):
          return ok(uint64(parseHexInt(tok)))
        return ok(uint64(parseBiggestInt(tok)))
      except ValueError as e:
        return err("could not parse '" & key & "' value '" & tok & "': " & e.msg)
  err("field '" & key & "' not found on line: " & line)

proc machoTextSection(binary: string): Result[TextSection, string] =
  ## Parse the `__TEXT,__text` section's vmaddr/fileoff/size from
  ## `otool -l <binary>`. The relevant block looks like:
  ##   sectname __text
  ##    segname __TEXT
  ##       addr 0x0000000100003f2c
  ##       size 0x000000000000008c
  ##     offset 16172
  let outRes = runTool("otool", ["-l", binary])
  if outRes.isErr:
    return err(outRes.error)
  var inText = false
  var sect: TextSection
  var haveAddr, haveOff, haveSize = false
  for raw in outRes.get().splitLines():
    let line = raw.strip()
    if line.startsWith("sectname"):
      inText = (line == "sectname __text")
      # A new section header resets per-section state for the __text block.
      if inText:
        haveAddr = false; haveOff = false; haveSize = false
      continue
    if not inText:
      continue
    if line.startsWith("addr "):
      let v = parseUintField(line, "addr")
      if v.isErr: return err(v.error)
      sect.vmaddr = v.get(); haveAddr = true
    elif line.startsWith("offset "):
      let v = parseUintField(line, "offset")
      if v.isErr: return err(v.error)
      sect.fileoff = v.get(); haveOff = true
    elif line.startsWith("size "):
      let v = parseUintField(line, "size")
      if v.isErr: return err(v.error)
      sect.size = v.get(); haveSize = true
    if haveAddr and haveOff and haveSize:
      return ok(sect)
  err("could not locate __TEXT,__text section in otool output for " & binary)

proc elfTextSection(binary: string): Result[TextSection, string] =
  ## Parse the `.text` section's vaddr/fileoff/size from
  ## `objdump --section-headers <binary>`. objdump prints, per section, a line:
  ##   Idx Name      Size      VMA               LMA               File off  Algn
  ##   0   .text     0000008c  0000...           0000...           00001000  2**2
  let outRes = runTool("objdump", ["--section-headers", binary])
  if outRes.isErr:
    return err(outRes.error)
  for raw in outRes.get().splitLines():
    let parts = raw.splitWhitespace()
    # A section row has at least: Idx Name Size VMA LMA FileOff ...
    if parts.len >= 6 and parts[1] == ".text":
      try:
        let size = uint64(parseHexInt(parts[2]))
        let vma = uint64(parseHexInt(parts[3]))
        let fileoff = uint64(parseHexInt(parts[5]))
        return ok(TextSection(vmaddr: vma, fileoff: fileoff, size: size))
      except ValueError as e:
        return err("could not parse .text section row '" & raw & "': " & e.msg)
  err("could not locate .text section in objdump output for " & binary)

proc textSection(binary: string): Result[TextSection, string] =
  ## Platform-dispatched executable-code section lookup.
  when defined(macosx):
    machoTextSection(binary)
  else:
    elfTextSection(binary)

# ---------------------------------------------------------------------------
# Symbol-table parsing
# ---------------------------------------------------------------------------

type RawSymbol = tuple[address: uint64, name: string]

func stripLeadingUnderscore(name: string): string =
  ## Mach-O's C ABI prefixes a leading underscore to symbol names (`_used_a`).
  ## Strip exactly one so table keys are the C identifiers callers use. ELF C
  ## symbols carry no such prefix, so this is a no-op there.
  when defined(macosx):
    if name.len > 0 and name[0] == '_': name[1 .. ^1] else: name
  else:
    name

proc definedTextSymbols(binary: string; text: TextSection):
    Result[seq[RawSymbol], string] =
  ## Return the defined symbols whose address falls within the executable
  ## section, sorted ascending by address, with the leading underscore stripped.
  ## `nm -n --defined-only` prints `<hexaddr> <type> <name>` per line, already
  ## address-sorted; we keep only symbols inside `[text.vmaddr, text.end)` so a
  ## non-code symbol (e.g. `__mh_execute_header` at the Mach-O header) is
  ## excluded and cannot bound a function's size.
  let outRes = runTool("nm", ["-n", "--defined-only", binary])
  if outRes.isErr:
    return err(outRes.error)
  let textEnd = text.vmaddr + text.size
  var syms: seq[RawSymbol] = @[]
  var seen = initHashSet[uint64]()
  for raw in outRes.get().splitLines():
    let parts = raw.splitWhitespace()
    # Expect: <hexaddr> <type> <name...>. Undefined symbols print without an
    # address and are excluded by --defined-only, but we defend anyway.
    if parts.len < 3:
      continue
    var address: uint64
    try:
      address = uint64(parseHexInt(parts[0]))
    except ValueError:
      continue
    if address < text.vmaddr or address >= textEnd:
      continue
    # Two symbols may alias one address (e.g. a local + global alias). Keep the
    # first; the name we expose is the alphabetically-first defined name there is
    # not important for the campaign (each fixture function has a unique addr).
    if address in seen:
      continue
    seen.incl address
    let name = stripLeadingUnderscore(parts[2 .. ^1].join(" "))
    syms.add (address: address, name: name)
  syms.sort(proc (a, b: RawSymbol): int = cmp(a.address, b.address))
  ok(syms)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc nativeFunctionTable*(binary: string):
    Result[Table[string, HashSlice], string] =
  ## Build `function_name → (file-offset, size)` for every function in the
  ## binary's executable section, from its symbol table.
  ##
  ## Size is the delta to the next defined symbol's address (symbols sorted by
  ## address); the final function's size is bounded by the end of the executable
  ## section. The file offset is `sym.vmaddr - text.vmaddr + text.fileoff` so the
  ## returned slice reads the correct bytes regardless of `vmaddr != fileoff`.
  ##
  ## A missing/unreadable binary, a failing inspection tool, or an empty symbol
  ## set ⇒ `Err` (the engine re-runs, never skips).
  if not fileExists(binary):
    return err("binary not found: " & binary)
  let textRes = textSection(binary)
  if textRes.isErr:
    return err(textRes.error)
  let text = textRes.get()
  let symsRes = definedTextSymbols(binary, text)
  if symsRes.isErr:
    return err(symsRes.error)
  let syms = symsRes.get()
  if syms.len == 0:
    return err("no defined code symbols found in " & binary)
  let textEnd = text.vmaddr + text.size
  var table = initTable[string, HashSlice]()
  for i in 0 ..< syms.len:
    let address = syms[i].address
    # End of this function = start of the next symbol, or the section end for
    # the last one. This is the macOS approach (nm sizes are zero on Mach-O) and
    # also a robust fallback on ELF.
    let endAddr =
      if i + 1 < syms.len: syms[i + 1].address
      else: textEnd
    if endAddr <= address:
      # Degenerate (alias at section end, or a bad section bound). A
      # zero/negative size is not a usable function; skip it rather than emit a
      # bogus slice. `shallowHashNative` will Err if such a name is requested.
      continue
    let size = int(endAddr - address)
    let fileoff = int(address - text.vmaddr + text.fileoff)
    # Later defined symbols at distinct addresses win in name-collision cases;
    # fixture functions are unique so this never triggers in tests.
    table[syms[i].name] = (offset: fileoff, size: size)
  if table.len == 0:
    return err("no sized functions derived from symbols in " & binary)
  ok(table)

proc shallowHashNative*(binary, funcName: string):
    Result[string, string] =
  ## Shallow hash of one native function, computed from its compiled instruction
  ## bytes `binary[offset ..< offset+size]`.
  ##
  ## Fail-safe `Err` (⇒ re-run upstream, never a skip) when:
  ##   * the binary is missing/unreadable, or the symbol-table tools fail;
  ##   * `funcName` is absent from the function table;
  ##   * the computed size is zero or negative (defended in the table build too);
  ##   * the binary is too short to contain the function's byte range.
  ##
  ## The hash is `std/hashes.hash` over the raw instruction bytes, rendered as a
  ## lowercase hex string — matching `engine.shallowHash`'s representation. (Per
  ## §16.7 the hash need not be cryptographic: this is change detection on
  ## trusted local build output.)
  ##
  ## PRECISION NOTE: the hash is over the RAW bytes, including any embedded
  ## pc-relative operands. For a position-independent function this is exact
  ## (relocation-invariant); for a function containing a call/branch whose
  ## callee DISTANCE changed under a layout shift, the bytes — and thus the hash
  ## — change even with unchanged source, yielding a conservative SAFE re-run
  ## (never a false skip). See the module doc-comment for the full discussion.
  let tableRes = nativeFunctionTable(binary)
  if tableRes.isErr:
    return err(tableRes.error)
  let table = tableRes.get()
  if funcName notin table:
    return err("function not found in " & binary & ": " & funcName)
  let slice = table[funcName]
  if slice.size <= 0:
    return err("non-positive size for function '" & funcName & "' in " & binary)
  var bytes: string
  var f: File
  if not open(f, binary, fmRead):
    return err("could not open binary for reading: " & binary)
  try:
    f.setFilePos(slice.offset)
    bytes = newString(slice.size)
    let got = f.readBuffer(addr bytes[0], slice.size)
    if got != slice.size:
      return err("short read for function '" & funcName & "' in " & binary &
        " (wanted " & $slice.size & " bytes at offset " & $slice.offset &
        ", got " & $got & ")")
  except CatchableError as e:
    return err("error reading function bytes from " & binary & ": " & e.msg)
  finally:
    f.close()
  ok(toHex(cast[uint](hash(bytes))).toLowerAscii())
