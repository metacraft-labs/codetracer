# m8_native_c — native end-to-end incremental-decision fixture

A tiny C program (`src/native_funcs.c`) plus a hand-crafted native calltrace,
used by the M8 native decision tests (`tests/t_native_decision.nim`). This is
the native counterpart of the Phase-1 m0/m4 fixtures: it proves the SAME
`decide()`/`record()` engine skips/re-runs a NATIVE test by its compiled
instruction bytes, end to end.

## Functions

| function   | executed by the test? | role                                            | leaf? |
|------------|-----------------------|-------------------------------------------------|-------|
| `used_a`   | YES                   | edited by `native_changing_an_executed_function_reruns` | yes (pure leaf) |
| `used_b`   | YES                   | second executed function                        | yes (pure leaf) |
| `unused_c` | NO                    | edited by `native_changing_an_unexecuted_function_skips` | yes |
| `main`     | NO (see below)        | entry point; calls `used_a` + `used_b`          | no    |

The test's executed set is exactly **{`used_a`, `used_b`}** — two pure,
position-independent leaves. `main` is deliberately kept OUT of the executed set
(the hand-crafted calltrace lists only `used_a` and `used_b`) so the executed
set contains no call-containing function. See the layout discussion below for
why that matters.

## The native calltrace fixture shape (prototype stand-in)

A live MCR/RR run is not available in this dev shell, so — exactly as Phase 1
hand-crafts canonical JSON traces — M8 hand-crafts the native calltrace in a
JSON shape modeled on the real native-recorder structures. The file the reader
consumes is `<traceDir>/native_calltrace.json`:

```json
{
  "binary": "/abs/path/to/the/recorded/executable",
  "calls": [
    { "functionName": "used_a", "calleePc": 4096 },
    { "functionName": "used_b", "calleePc": 4112 }
  ]
}
```

### What real native-recorder format this models

CodeTracer's native / Multi-Core-Recorder (MCR) path keeps its calltrace in
memory rather than as a canonical on-disk JSON; the executed-function set comes
from:

- `codetracer-native-recorder/ct_emulator/src/ct_emulator/write_log.nim` —
  `CallRecord {tickEnter, tickExit, callerPc, calleePc}`, the flat call/return
  stream the emulator appends while replaying.
- `.../ct_emulator/calltrace_collector.nim` — collects those records during
  emulation (the same collector serves MCR direct emulation and RR replay).
- `.../ct_emulator/calltrace.nim` — `buildCallTree` turns the flat records into
  a `CallTree` of `CallNode {functionName, sourceFile, sourceLine, calleePc,
  children, ...}`, resolving each `calleePc` to a `functionName` via
  `source_index.resolvePCs` (addr2line over the recorded ELF, `elfPath`).

The fixture JSON is a thin, explicitly-documented projection of that in-memory
structure:

- `binary` ⇐ the recorder's `elfPath` (the binary PCs are resolved against; the
  owning binary of every executed function).
- `calls[].functionName` ⇐ `CallNode.functionName` — the only field dependency
  discovery needs.
- `calls[].calleePc` ⇐ `CallNode.calleePc` / `CallRecord.calleePc` — carried for
  fidelity; the dependency set keys on the resolved NAME, so the reader
  de-duplicates by name and `calleePc` is optional.

The executed SET is independent of the call-tree nesting, so the flat `calls`
array loses nothing relevant to dependency discovery (a real reader would walk
the whole tree collecting every node's `functionName`; that yields the same
set). The full reader contract + fail-safe behaviour is documented in
`src/repro_ct_incremental/native_trace.nim`.

### The `binary` path is filled in at test time

The recorded executable is built at test time into a temp dir (the binary is
NOT committed), so the committed fixture cannot hardcode its absolute path. The
M8 test writes `native_calltrace.json` into the trace dir with `binary` pointing
at the freshly-built binary — exactly as a real recorder writes the actual
`elfPath` it replayed. This is documented here and in the test.

## The native `ExecutedFunction` convention

Native dependencies key on **(function name + owning binary)**, not a source
file + line: a native function's identity is its compiled instruction bytes,
located in the binary by symbol name. So `readExecutedFunctionsNative` returns
`ExecutedFunction` with `name` = the function name, `file` = the **binary path**
(not a source path), and `defLine` = 0 (unused). The native `ShallowHasher`
reads `dep.file` as the binary and calls `shallowHashNative(dep.file,
dep.name)`. This reuses the existing cache schema (`{name, file, defLine,
shallow}`) with no change — the binary travels in the slot a source path would.

## Building

The binary is **not committed**. The test builds it (and edited copies) at test
time into temp dirs via `build.sh <source.c> <out>`, which runs the dev shell's
`cc`:

```
cc -O0 -g -fno-stack-protector -fno-asynchronous-unwind-tables -o <out> <source.c>
```

## Layout choice — why the unexecuted-edit case genuinely SKIPS (empirical)

The M7 relocation limitation is real: a function that relocates AND contains a
call re-hashes (a safe re-run, but it would break the "skip" expectation). To
make `native_changing_an_unexecuted_function_skips` genuinely skip, editing
`unused_c` must not change the instruction bytes of the executed functions.

Two properties guarantee it:

1. The executed functions `used_a`/`used_b` are pure **position-independent
   leaves** — byte-identical machine code wherever the linker places them, so
   even if they relocate their hashes are stable.
2. The executed set excludes `main` (the only call-containing function), so no
   executed function carries a relocation-sensitive pc-relative call operand.

Empirically confirmed on this host (arm64 macOS): editing `unused_c` (growing
it with a loop) shifts `used_a`/`used_b` to lower addresses, yet their
instruction-byte hashes are **unchanged** (`used_a 5b33e421faa53965` and
`used_b 69d8b6c436ed0ff9` before and after), while `unused_c`'s own hash
changes. The test asserts this stability directly, so a regression fails loudly
rather than coincidentally re-running.
