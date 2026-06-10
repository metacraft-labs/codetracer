# M13 Smart-Contract and VM Recorder Harnesses

Scope: catalog integration for sibling recorder repositories present in the
workspace. Recorder repos are treated as read-only inputs.

Common contract:

- Detect the sibling recorder repo by name from the workspace root or a parent.
- Discover fixtures from each recorder's documented `test-programs` or example
  directories.
- Advertise file run/record only when a recorder executable is available on
  `PATH`, in `target/{debug,release}`, or through the provider-specific
  `CODETRACER_*_RECORDER_CMD` environment variable. Sibling `target` binaries
  are trusted as built recorder outputs; external/PATH executables must expose
  recorder-like `--help` output so fake adapter scripts do not satisfy M13.
- Run/record shells out to the documented `record ... --out-dir <dir>` command
  and accepts success only when a non-empty `.ct` artifact is produced.

| Provider        | Sibling repo                  | Fixture roots                                                     | Stable command                                                                          | Artifact shape                                        | Dependencies and limitations                                                                                                                              |
| --------------- | ----------------------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `smart-cairo`   | `codetracer-cairo-recorder`   | `test-programs/cairo`, Cairo files under `test-programs/starknet` | `codetracer-cairo-recorder record <file.cairo> --out-dir <dir>`                         | CTFS `.ct`, `trace_metadata.json`, `trace_paths.json` | Needs Cairo corelib. StarkNet JSON conversion uses `trace-starknet` and is not exposed by the generic M13 record adapter. Replay is documented as a stub. |
| `smart-move`    | `codetracer-move-recorder`    | `test-programs/move/**/traces`                                    | `codetracer-move-recorder record <trace-file> --out-dir <dir>`                          | CTFS `.ct` sidecars from Sui/Aptos traces             | Catalog uses pre-generated trace files. Live Sui/Aptos replay needs external CLIs and is not run by discovery.                                            |
| `smart-evm`     | `codetracer-evm-recorder`     | `test-programs`                                                   | `codetracer-evm-recorder record <solidity-file> --out-dir <dir> [--function <name>]`    | CTFS `.ct` sidecars                                   | Needs `solc` and Anvil for real recording. M13 uses default entry-point selection.                                                                        |
| `smart-solana`  | `codetracer-solana-recorder`  | `test-programs`                                                   | `codetracer-solana-recorder record <program.so> --out-dir <dir>`                        | CTFS `.ct` sidecars                                   | Catalogs compiled `.so`/`.elf` fixtures. Rust source fixtures require `cargo-build-sbf` first.                                                            |
| `smart-fuel`    | `codetracer-fuel-recorder`    | `test-programs`                                                   | `codetracer-fuel-recorder record --bytecode <FILE.bin> --out-dir <dir>`                 | CTFS `.ct` sidecars for bytecode                      | Sway project recording is documented as a placeholder, so M13 uses prebuilt bytecode fixtures.                                                            |
| `smart-miden`   | `codetracer-miden-recorder`   | `test-programs/masm`                                              | `codetracer-miden-recorder record <file.masm> --out-dir <dir>`                          | CTFS `.ct` sidecars                                   | MockChain contract command currently writes a summary artifact only, not full CTFS.                                                                       |
| `smart-circom`  | `codetracer-circom-recorder`  | `test-programs/circom`                                            | `codetracer-circom-recorder record <file.circom> --out-dir <dir> [--backend wasm\|cpp]` | CTFS `.ct` sidecars                                   | Needs Circom/witness tooling. M13 uses the recorder default backend.                                                                                      |
| `smart-leo`     | `codetracer-leo-recorder`     | `test-programs/leo`                                               | `codetracer-leo-recorder record <leo-file> --out-dir <dir>`                             | CTFS `.ct` sidecars                                   | `.leo` fixtures are cataloged. Aleo instruction fixtures and on-chain Aleo REST replay use separate flows and are not cataloged.                          |
| `smart-polkavm` | `codetracer-polkavm-recorder` | `test-programs/rust`, `test-programs/assembly`                    | `codetracer-polkavm-recorder record <blob-file> --out-dir <dir>`                        | CTFS `.ct` sidecars                                   | M13 catalogs compiled blobs when present. ink! message tracing needs additional metadata.                                                                 |
| `smart-ton`     | `codetracer-ton-recorder`     | `test-programs/tolk`                                              | `codetracer-ton-recorder record <tolk-file> --out-dir <dir>`                            | CTFS `.ct` sidecars                                   | Sandbox log conversion and on-chain replay are separate modes not cataloged.                                                                              |
| `smart-cardano` | `codetracer-cardano-recorder` | `test-programs/aiken`, `test-programs/uplc`                       | `codetracer-cardano-recorder record <file.ak> --out-dir <dir>`                          | CTFS `.ct` sidecars                                   | Blockfrost replay needs credentials and is not cataloged.                                                                                                 |
| `smart-flow`    | `codetracer-flow-recorder`    | `test-programs/cadence`                                           | `codetracer-flow-recorder record <file.cdc> --out-dir <dir>`                            | CTFS bundle from Cadence helper                       | Needs `cadence-trace-helper`. Replay requires Flow access-node connectivity.                                                                              |
| `smart-wasm`    | `codetracer-wasm-recorder`    | `examples`                                                        | `go test ./examples/...`                                                                | No CodeTracer recorder artifact contract found        | This sibling is a wazero checkout, not a `record --out-dir` CodeTracer recorder CLI. Discovery is informational.                                          |
| `smart-wasmi`   | `codetracer-wasmi-recorder`   | `crates/*/tests`                                                  | `cargo test`                                                                            | No CodeTracer recorder artifact contract found        | This sibling is a wasmi runtime checkout, not a `record --out-dir` CodeTracer recorder CLI. Discovery is informational.                                   |

Current local verification environment:

- `nim`, `just`, and `cargo` are available; recorder builds were run through
  `nix-shell -p cargo rustc nim nimble openssl pkg-config just`.
- `codetracer-evm-recorder`, `codetracer-fuel-recorder`,
  `codetracer-polkavm-recorder`, and `codetracer-miden-recorder` build
  successfully into sibling `target/debug` directories.
- Real recorder smokes produced non-empty CTFS bundles:
  `FlowTest.ct` from EVM when `solc` and `anvil` are provided by
  `nix-shell -p solc foundry`, `flow_test.ct` from Fuel bytecode,
  `flow_test.ct` from PolkaVM, and `masm_flow_test.ct` from Miden MASM.
- Recorder providers whose binaries are not available in `PATH` or sibling
  `target/{debug,release}` directories report discovery-only capabilities and
  emit diagnostics naming the missing binary and the matching
  `CODETRACER_*_RECORDER_CMD` override.
