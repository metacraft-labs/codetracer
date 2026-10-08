# M-XOS-Fixture — cross-OS replay test fixture

`xos_hello.ct` is a real `ct_cli record --attach=premain` capture of the tiny
C program in `xos_hello.c`, slimmed so the recorded `cp0.mem` snapshot payload
only carries the program's PIE load segments plus the active `[stack]`
mapping. Everything else needed by
`EmulatorReplaySession::new_from_ctfs_bytes` (`cp0.regs`, `cp0.maps`,
`cp0.fsbase`, `meta.dat`, `debug.dat`, the thread stream, the event log
members, `paths.dat`) is preserved verbatim from the recorder output.

`--attach=premain` is what makes this fixture usable: it records the `main`
boundary (`cp0.regs` + `cp0.mem`) the emulator session seeds from. The Linux
default, `--attach=instruction0`, records the execve-stop boundary instead
(`bootelf.bin`, `bootelf.stk`, `cp.entry.*`, `cppages.ns`) and no `cp0.*`
member; the session refuses such a recording by name.

Consumed by `src/db-backend/tests/xos_replay.rs` (the
`xos_fixture_drives_emulator_replay_session` integration test).

## Why this fixture exists

The replay path runs the same Rust → Nim → emulator stack regardless of
host OS. A `.ct` is just a captured x86_64 register file plus tagged
memory regions plus an `/proc/self/maps`-derived load base; the emulator
interprets those values without ever touching the live host. This
fixture pins that contract structurally on Linux — opening it in the
WASM/browser build (which never inspects the host) follows the exact
same code path. A true macOS-host run requires CI infra and is out of
scope for this milestone.

## File budget

| member | bytes |
|--------|-------|
| `cp0.mzd` + `cp0.mzi` | ~5.6 KB (`cp0.mem` compressed; 8 regions, ~17 MB inflated, mostly zero pages) |
| `cp0.maps`    | ~20 KB  (verbatim /proc/self/maps text)          |
| `debug.dat`   | ~17 KB  (full ELF with DWARF)                    |
| `cp0.rtx`, `rtx.final` | ~16 KB each (recorder-generated text)   |
| `meta.dat`    | ~13 KB                                           |
| `guest.env`   | ~1.5 KB (the scrubbed recording environment)     |
| `cp0.regs`    | 152 B   (compact 144-byte register payload)      |
| `t000...`, `eventlog.*` | < 1 KB                                 |
| `cp0.fsbase`  | 16 B                                             |
| **Total .ct** | **~200 KB** (well under the 2 MB budget)         |

`cp0.mem` is a snapshot payload: stored as the `cp0.mzd` + `cp0.mzi`
chunked-compressed pair when it is larger than one container block, raw under
`cp0.mem` otherwise (`codetracer-trace-format-spec/internal-files.md`,
"Snapshot payloads").

## How to regenerate

The fixture is committed so `cargo test` does not need the recorder
toolchain. Regenerate only when the test program changes or you need a
fresh capture (e.g. cp0 layout changes).

```bash
cd codetracer/src/db-backend/tests/fixtures/xos
./rebuild.sh
```

`rebuild.sh` performs three steps:

1. **Compile `xos_hello.elf`** with `-O0 -g
   -fdebug-prefix-map=$(pwd)=.` so the bundled DWARF carries
   `DW_AT_comp_dir = .` (the prefix-map flag is critical — without it
   DWARF would bake in the regenerator's absolute home directory,
   making the fixture machine-specific).
2. **Record** the program via `ct_cli record --attach=premain --source
   xos_hello.c -o /tmp/<x>.ct -- ./xos_hello.elf` under a scrubbed
   environment (`env -i`), producing a full-snapshot capture (~74 MB of
   `cp0.mem`). The kept `[stack]` region carries the program's `envp`
   strings and `guest.env` its whole environment, so a recording made from a
   CI job or a developer shell would otherwise publish that host's
   variables.
3. **Slim** the recorded `cp0.mem` to (PIE load segments | `[stack]`)
   via the `slim_xos_fixture` integration test (gated `#[ignore]` in
   `tests/xos_fixture_rebuild.rs`), which reads and re-encodes the payload
   with the production snapshot-payload code and re-emits the container
   with `write_minimal_ctfs`. It fails instead of writing a fixture when
   the recording has no `cp0.mem` payload, no `cp0.regs`, no region holding
   the recorded RSP or the program, nothing to drop, or a member carrying a
   credential-looking environment entry; `rebuild.sh` fails if the helper
   wrote nothing.

Set `CT_CLI=` if `ct_cli` is not on `$PATH` (e.g.
`CT_CLI=$HOME/metacraft/codetracer-native-recorder/ct_cli/ct_cli
./rebuild.sh`).
