# M-XOS-Fixture — cross-OS replay test fixture

`xos_hello.ct` is a real `ct_cli record` capture of the tiny C program in
`xos_hello.c`, slimmed so the recorded `cp0.mem` stream only carries the
program's PIE load segments plus the active `[stack]` mapping. Everything
else needed by `EmulatorReplaySession::new_from_ctfs_bytes` (`cp0.regs`,
`cp0.maps`, `cp0.fsbase`, `meta.dat`, `debug.dat`, one empty thread
stream, the event log sidecars, `paths.json`) is preserved verbatim from
the recorder output.

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

| file | bytes |
|------|-------|
| `cp0.mem`     | ~188 KB (6 regions: 5 program pages + [stack]) |
| `debug.dat`   | ~17 KB  (full ELF with DWARF)                  |
| `cp0.maps`    | ~7.8 KB (verbatim /proc/self/maps text)        |
| `meta.dat`    | ~256 B                                         |
| `cp0.regs`    | 152 B   (compact 144-byte register payload)    |
| `event log.*` | ~230 B  (sidecar files)                        |
| `t000...`     | ~158 B  (per-thread stream)                    |
| `cp0.fsbase`  | 16 B                                           |
| `paths.json`  | 2 B                                            |
| **Total .ct** | **~288 KB** (well under the 2 MB budget)       |

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
2. **Record** the program via `ct_cli record --source xos_hello.c -o
   /tmp/<x>.ct -- ./xos_hello.elf` to produce a full-snapshot capture
   (~90 MB on disk — all readable process memory).
3. **Slim** the recorded `cp0.mem` to (PIE load segments | `[stack]`)
   via the `slim_xos_fixture` integration test (gated `#[ignore]` in
   `tests/xos_fixture_rebuild.rs`), which re-uses the production
   `CtfsReader` / `write_minimal_ctfs` pair so the byte layout is
   identical to a freshly-recorded `.ct`, just with a much smaller
   `cp0.mem`.

Set `CT_CLI=` if `ct_cli` is not on `$PATH` (e.g.
`CT_CLI=$HOME/metacraft/codetracer-native-recorder/ct_cli/ct_cli
./rebuild.sh`).
