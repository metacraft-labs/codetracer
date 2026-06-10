import ../discovery
import smart_contract_common

proc cairoSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-cairo", language: "cairo",
    framework: "cairo-vm", displayName: "Cairo Recorder Harness",
    recorderRepo: "codetracer-cairo-recorder",
    recorderBinary: "codetracer-cairo-recorder",
    envCommand: "CODETRACER_CAIRO_RECORDER_CMD",
    fixtureRoots: @["test-programs/cairo", "test-programs/starknet"],
    fixtureExtensions: @[".cairo"],
    ignoredPathFragments: @[],
    preferredFixtureNames: @["flow_test.cairo", "simple_contract.cairo"],
    recordMode: shrmRecordFile,
    stableTestCommand:
      "codetracer-cairo-recorder record <file.cairo> --out-dir <dir>",
    dependencies: @["Cairo corelib / CAIRO_CORELIB_DIR"],
    limitations:
      "Cairo source fixtures record directly; StarkNet JSON conversion uses " &
      "a separate trace-starknet command and on-chain replay remains a stub.")

proc cardanoSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-cardano", language: "aiken",
    framework: "cardano-uplc", displayName: "Cardano/Aiken Recorder Harness",
    recorderRepo: "codetracer-cardano-recorder",
    recorderBinary: "codetracer-cardano-recorder",
    envCommand: "CODETRACER_CARDANO_RECORDER_CMD",
    fixtureRoots: @["test-programs/aiken", "test-programs/uplc"],
    fixtureExtensions: @[".ak", ".uplc"],
    ignoredPathFragments: @[],
    preferredFixtureNames: @["flow_test.ak", "flow_test.uplc"],
    recordMode: shrmRecordFile,
    stableTestCommand:
      "codetracer-cardano-recorder record <file.ak> --out-dir <dir>",
    dependencies: @["Aiken/UPLC parser support in recorder"],
    limitations:
      "Local Aiken and raw UPLC fixtures record directly; Blockfrost replay " &
      "requires credentials and is not exposed as a local catalog item.")

proc circomSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-circom", language: "circom",
    framework: "circom-witness", displayName: "Circom Recorder Harness",
    recorderRepo: "codetracer-circom-recorder",
    recorderBinary: "codetracer-circom-recorder",
    envCommand: "CODETRACER_CIRCOM_RECORDER_CMD",
    fixtureRoots: @["test-programs/circom"],
    fixtureExtensions: @[".circom"],
    ignoredPathFragments: @[],
    preferredFixtureNames: @["flow_test.circom"],
    recordMode: shrmRecordFile,
    stableTestCommand:
      "codetracer-circom-recorder record <file.circom> --out-dir <dir> " &
      "[--backend wasm|cpp]",
    dependencies: @["circom", "witness calculator backend"],
    limitations:
      "Circom fixtures record through the recorder default backend; explicit " &
      "backend selection is not part of the M13 catalog selector.")

proc evmSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-evm", language: "solidity",
    framework: "evm", displayName: "EVM Solidity/Vyper Recorder Harness",
    recorderRepo: "codetracer-evm-recorder",
    recorderBinary: "codetracer-evm-recorder",
    envCommand: "CODETRACER_EVM_RECORDER_CMD",
    fixtureRoots: @["test-programs"],
    fixtureExtensions: @[".sol", ".vy", ".yul"],
    ignoredPathFragments: @[],
    preferredFixtureNames: @["FlowTest.sol"],
    recordMode: shrmRecordFile,
    stableTestCommand:
      "codetracer-evm-recorder record <solidity-file> --out-dir <dir> " &
      "[--function <name>]",
    dependencies: @["solc", "anvil"],
    requiredTools: @["solc", "anvil"],
    nixPackages: @["solc", "foundry"],
    limitations:
      "Solidity/Yul fixtures record with the recorder default entry point; " &
      "Vyper coverage is represented by Solidity harness wrappers in the " &
      "recorder fixtures.")

proc flowSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-flow", language: "cadence",
    framework: "flow-cadence", displayName: "Flow/Cadence Recorder Harness",
    recorderRepo: "codetracer-flow-recorder",
    recorderBinary: "codetracer-flow-recorder",
    envCommand: "CODETRACER_FLOW_RECORDER_CMD",
    fixtureRoots: @["test-programs/cadence"],
    fixtureExtensions: @[".cdc"],
    ignoredPathFragments: @[],
    preferredFixtureNames: @["flow_test.cdc"],
    recordMode: shrmRecordFile,
    stableTestCommand:
      "codetracer-flow-recorder record <file.cdc> --out-dir <dir>",
    dependencies: @["cadence-trace-helper"],
    limitations:
      "Local Cadence fixtures record through the Go helper; on-chain replay " &
      "requires Flow access-node connectivity and is not cataloged.")

proc fuelSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-fuel", language: "sway",
    framework: "fuelvm", displayName: "Sway/FuelVM Recorder Harness",
    recorderRepo: "codetracer-fuel-recorder",
    recorderBinary: "codetracer-fuel-recorder",
    envCommand: "CODETRACER_FUEL_RECORDER_CMD",
    fixtureRoots: @["test-programs"],
    fixtureExtensions: @[".bin"],
    ignoredPathFragments: @[],
    preferredFixtureNames: @["flow_test.bin", "script_arith.bin"],
    recordMode: shrmFuelBytecode,
    stableTestCommand:
      "codetracer-fuel-recorder record --bytecode <FILE.bin> --out-dir <dir>",
    dependencies: @["prebuilt FuelVM bytecode", "forc for rebuilding fixtures"],
    limitations:
      "M13 records prebuilt FuelVM bytecode because Sway project recording " &
      "is documented as a placeholder in the recorder README.")

proc leoSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-leo", language: "leo",
    framework: "aleo-avm", displayName: "Leo/Aleo Recorder Harness",
    recorderRepo: "codetracer-leo-recorder",
    recorderBinary: "codetracer-leo-recorder",
    envCommand: "CODETRACER_LEO_RECORDER_CMD",
    fixtureRoots: @["test-programs/leo"],
    fixtureExtensions: @[".leo"],
    ignoredPathFragments: @[],
    preferredFixtureNames: @["flow_test.leo"],
    recordMode: shrmRecordFile,
    stableTestCommand:
      "codetracer-leo-recorder record <leo-file> --out-dir <dir>",
    dependencies: @["Leo parser support in recorder"],
    limitations:
      "Local Leo fixtures record directly; Aleo instruction fixtures and " &
      "Aleo REST replay use separate flows and are not represented as M13 " &
      "record items.")

proc midenSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-miden", language: "masm",
    framework: "miden-vm", displayName: "Miden VM Recorder Harness",
    recorderRepo: "codetracer-miden-recorder",
    recorderBinary: "codetracer-miden-recorder",
    envCommand: "CODETRACER_MIDEN_RECORDER_CMD",
    fixtureRoots: @["test-programs/masm"],
    fixtureExtensions: @[".masm"],
    ignoredPathFragments: @[],
    preferredFixtureNames: @["masm_flow_test.masm", "compute.masm"],
    recordMode: shrmRecordFile,
    stableTestCommand:
      "codetracer-miden-recorder record <file.masm> --out-dir <dir>",
    dependencies: @["Miden VM assembler/runtime"],
    limitations:
      "Standalone MASM programs record directly; MockChain contract tracing " &
      "currently produces a summary artifact only and is not cataloged.")

proc moveSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-move", language: "move",
    framework: "sui-aptos-move", displayName: "Move Recorder Harness",
    recorderRepo: "codetracer-move-recorder",
    recorderBinary: "codetracer-move-recorder",
    envCommand: "CODETRACER_MOVE_RECORDER_CMD",
    fixtureRoots: @["test-programs/move"],
    fixtureExtensions: @[".zst", ".ndjson"],
    ignoredPathFragments: @["/build/"],
    preferredFixtureNames: @["flow_test__flow_test__test_computation.json.zst"],
    recordMode: shrmRecordFile,
    stableTestCommand:
      "codetracer-move-recorder record <trace-file> --out-dir <dir>",
    dependencies: @["pre-generated Sui trace JSON/Zstd",
        "sui or aptos CLI only for replay"],
    limitations:
      "Move local catalog items are pre-generated Sui trace files; live " &
      "Sui/Aptos replay is intentionally not run by discovery.")

proc polkavmSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-polkavm", language: "polkavm",
    framework: "polkavm", displayName: "PolkaVM Recorder Harness",
    recorderRepo: "codetracer-polkavm-recorder",
    recorderBinary: "codetracer-polkavm-recorder",
    envCommand: "CODETRACER_POLKAVM_RECORDER_CMD",
    fixtureRoots: @["test-programs/rust", "test-programs/assembly"],
    fixtureExtensions: @[".polkavm", ".blob"],
    ignoredPathFragments: @[],
    preferredFixtureNames: @["flow_test.polkavm"],
    recordMode: shrmRecordFile,
    stableTestCommand:
      "codetracer-polkavm-recorder record <blob-file> --out-dir <dir>",
    dependencies: @["PolkaVM program blob"],
    limitations:
      "M13 records compiled PolkaVM blobs when present; ink! message " &
      "tracing and on-chain replay require additional target metadata.")

proc solanaSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-solana", language: "rust",
    framework: "solana-sbf", displayName: "Solana SBF Recorder Harness",
    recorderRepo: "codetracer-solana-recorder",
    recorderBinary: "codetracer-solana-recorder",
    envCommand: "CODETRACER_SOLANA_RECORDER_CMD",
    fixtureRoots: @["test-programs"],
    fixtureExtensions: @[".so", ".elf"],
    ignoredPathFragments: @[],
    preferredFixtureNames: @["cpi_fixture.elf"],
    recordMode: shrmRecordFile,
    stableTestCommand:
      "codetracer-solana-recorder record <program.so> --out-dir <dir>",
    dependencies: @["compiled SBF ELF",
      "cargo-build-sbf for rebuilding fixtures"],
    limitations:
      "M13 records compiled SBF ELF fixtures when present; Rust source-only " &
      "fixtures require a Solana build step before recording.")

proc tonSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-ton", language: "tolk",
    framework: "ton-tvm", displayName: "TON/Tolk Recorder Harness",
    recorderRepo: "codetracer-ton-recorder",
    recorderBinary: "codetracer-ton-recorder",
    envCommand: "CODETRACER_TON_RECORDER_CMD",
    fixtureRoots: @["test-programs/tolk"],
    fixtureExtensions: @[".tolk"],
    ignoredPathFragments: @[],
    preferredFixtureNames: @["flow_test.tolk"],
    recordMode: shrmRecordFile,
    stableTestCommand:
      "codetracer-ton-recorder record <tolk-file> --out-dir <dir>",
    dependencies: @["Tolk/TVM parser support in recorder"],
    limitations:
      "Local Tolk fixtures record directly; sandbox log conversion and " &
      "on-chain replay are separate recorder modes not cataloged in M13.")

proc wasmSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-wasm", language: "wasm",
    framework: "wazero", displayName: "Wasm/Wazero Harness Notes",
    recorderRepo: "codetracer-wasm-recorder",
    recorderBinary: "codetracer-wasm-recorder",
    envCommand: "CODETRACER_WASM_RECORDER_CMD",
    fixtureRoots: @["examples"],
    fixtureExtensions: @[".wasm", ".wat", ".go"],
    ignoredPathFragments: @[],
    preferredFixtureNames: @["add.go"],
    recordMode: shrmUnsupported,
    stableTestCommand: "go test ./examples/...",
    dependencies: @["go"],
    limitations:
      "The sibling is a wazero checkout with examples, not a CodeTracer " &
      "recorder CLI exposing record --out-dir.")

proc wasmiSpec*(): SmartHarnessSpec =
  SmartHarnessSpec(providerId: "smart-wasmi", language: "wasm",
    framework: "wasmi", displayName: "Wasmi Harness Notes",
    recorderRepo: "codetracer-wasmi-recorder",
    recorderBinary: "codetracer-wasmi-recorder",
    envCommand: "CODETRACER_WASMI_RECORDER_CMD",
    fixtureRoots: @["crates/cli/tests", "crates/wasmi/tests",
        "crates/wasi/tests"],
    fixtureExtensions: @[".wasm", ".wat", ".rs"],
    ignoredPathFragments: @["/target/"],
    preferredFixtureNames: @[],
    recordMode: shrmUnsupported,
    stableTestCommand: "cargo test",
    dependencies: @["cargo"],
    limitations:
      "The sibling is a wasmi runtime checkout without a CodeTracer " &
      "recorder CLI exposing record --out-dir.")

proc smartHarnessSpecs*(): seq[SmartHarnessSpec] =
  @[
    cairoSpec(),
    moveSpec(),
    evmSpec(),
    solanaSpec(),
    fuelSpec(),
    midenSpec(),
    circomSpec(),
    leoSpec(),
    polkavmSpec(),
    tonSpec(),
    cardanoSpec(),
    flowSpec(),
    wasmSpec(),
    wasmiSpec()
  ]

proc newSmartContractHarnessM13Providers*(): seq[M1Provider] =
  for spec in smartHarnessSpecs():
    result.add newSmartHarnessProvider(spec)
