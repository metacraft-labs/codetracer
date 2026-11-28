## Which module the stage records for a Stylus contract
## (`ct_stages.stylusContractWasm`): the crate's `cdylib` `.wasm`, the one
## that exports `user_entrypoint`, whatever order cargo reports its artifacts
## in and whatever else the build made. The template crate's `bin` target
## (`src/main.rs`, the SDK's `export-abi` main) builds a `.wasm` into the same
## folder; the stage once took whichever `.wasm` the folder listed first, and
## where that was the bin the recording died (exit 139).
## Run by `ci/test/scenarios.sh stage-test`.
import std/[strutils, unittest]
import ./ct_stages

const
  Dir = "/w/stylus_fund_tracker/target/wasm32-unknown-unknown/debug/"
  Lib = """{"reason":"compiler-artifact","package_id":"path+file:///w/stylus_fund_tracker#stylus-fund-tracking-demo@0.1.11","target":{"kind":["lib","cdylib"],"crate_types":["lib","cdylib"],"name":"stylus_fund_tracking_demo","src_path":"/w/stylus_fund_tracker/src/lib.rs"},"filenames":["""" &
    Dir & """libstylus_fund_tracking_demo.rlib","""" & Dir & """stylus_fund_tracking_demo.wasm"],"fresh":false}"""
  Bin = """{"reason":"compiler-artifact","package_id":"path+file:///w/stylus_fund_tracker#stylus-fund-tracking-demo@0.1.11","target":{"kind":["bin"],"crate_types":["bin"],"name":"stylus-hello-world","src_path":"/w/stylus_fund_tracker/src/main.rs"},"filenames":["""" &
    Dir & """stylus-hello-world.wasm"],"executable":"""" & Dir & """stylus-hello-world.wasm","fresh":false}"""
  Dep = """{"reason":"compiler-artifact","package_id":"registry+https://github.com/rust-lang/crates.io-index#hex@0.4.3","target":{"kind":["lib"],"crate_types":["lib"],"name":"hex"},"filenames":["/w/target/deps/libhex.rlib"],"fresh":true}"""
  Done = """{"reason":"build-finished","success":true}"""

suite "the Stylus contract module the stage records":
  test "the cdylib's .wasm, when cargo reports the bin first":
    check stylusContractWasm([Dep, Bin, Lib, Done].join("\n")) == Dir & "stylus_fund_tracking_demo.wasm"

  test "the cdylib's .wasm, when cargo reports it first":
    check stylusContractWasm([Dep, Lib, Bin, Done].join("\n")) == Dir & "stylus_fund_tracking_demo.wasm"

  test "never the bin's .wasm, and nothing when there is no cdylib":
    check stylusContractWasm([Dep, Bin, Done].join("\n")) == ""

  test "diagnostics and other lines between the messages are skipped":
    check stylusContractWasm("   Compiling hex v0.4.3\n" & Bin & "\nwarning: unused\n" & Lib) ==
      Dir & "stylus_fund_tracking_demo.wasm"
