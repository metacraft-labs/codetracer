//! WASM-target libc shims for symbols referenced by the Nim MCR
//! emulator's generated C output (F5c-2).
//!
//! The bulk of the libc surface (`malloc`, `free`, `realloc`, `calloc`,
//! `fprintf`, `fclose`, `snprintf`, `vsnprintf`, `abort`, `strncmp`,
//! `clock`, `fputc`, `fputs`, `fdopen`) is already provided by
//! [`crate::c_compat`] for the existing browser-transport tree-sitter
//! integration. This module covers only the additional symbols that the
//! emulator's Nim runtime emits on top of that:
//!
//! * `exit` — Nim's panic path (`reportUnhandledError` and the
//!   `--exceptions:goto` cleanup) calls `exit(1)` after writing a
//!   diagnostic. We trap into JS via `wasm_bindgen::throw_str` so the
//!   panic surfaces as a regular browser-side exception rather than a
//!   wasm trap whose stack trace the browser can't unwind.
//! * `getenv` — Nim's envvars helper is linked into the generated
//!   output even for the browser build. Browsers have no process
//!   environment, so returning null is the deterministic libc answer.
//!
//! Symbols that the wasm32-targeted Nim output references purely as
//! compiler intrinsics — `memcpy`, `memset`, `memmove`, `memcmp` —
//! are satisfied by Rust's `compiler_builtins` crate, which the rustc
//! wasm32 build automatically pulls in. No explicit shim is needed.
//!
//! Additional environment/control-flow symbols are present through Nim stdlib
//! diagnostic paths. They are implemented as inert browser shims so wasm-bindgen
//! does not emit bare `"env"` imports.

#![cfg(target_arch = "wasm32")]
#![allow(clippy::missing_safety_doc)]

use core::ffi::{c_char, c_int};
use core::ptr::null_mut;

#[unsafe(no_mangle)]
pub extern "C" fn getenv(_name: *const c_char) -> *mut c_char {
    null_mut()
}

/// `exit(int)` shim. Nim's `system.nim` calls this on unhandled
/// exceptions; on the web we trap into JavaScript so the error
/// surfaces through the host's normal exception path instead of an
/// opaque wasm trap.
#[unsafe(no_mangle)]
pub extern "C" fn exit(_status: c_int) -> ! {
    wasm_bindgen::throw_str("ct-mcr: Nim runtime called exit() — fatal emulator error");
}
