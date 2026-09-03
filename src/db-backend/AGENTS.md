there is a json schema for DAP availabe in the spec_dap folder
(copied from <https://microsoft.github.io/debug-adapter-protocol/debugAdapterProtocol.json>)

always use `cargo fmt` to autoformat the rust files before committing

## If a failing test here prints nothing

On macOS, a failing test used to abort with

```text
fatal runtime error: failed to initiate panic, error 5, aborting
(signal: 6, SIGABRT: process abort signal)
```

and print NEITHER the assertion message NOR the values it compared — so a red
carried no information and mutation testing was impossible.

The cause is the linker, not any test: rustc's default Darwin linker driver is
`cc`, which in this repo's Nix dev shell is GCC, and GCC's Darwin driver passes
`-no_compact_unwind`. The binary then has no `__TEXT,__unwind_info` and Apple's
libunwind cannot unwind out of a panic.

The fix is the `[target.*-apple-darwin] linker = "clang"` entries in the
repo-root `.cargo/config.toml` (root, not `src/`: the justfile and
`nix/pre-commit.nix` run cargo from the repo root with `--manifest-path`).
`tests/panic_message_visibility.rs` is the guard — if it goes red, check that
config first, and do not trust any other red in this crate until it is green.
