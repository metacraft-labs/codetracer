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
//!
//! Symbols that the wasm32-targeted Nim output references purely as
//! compiler intrinsics — `memcpy`, `memset`, `memmove`, `memcmp` —
//! are satisfied by Rust's `compiler_builtins` crate, which the rustc
//! wasm32 build automatically pulls in. No explicit shim is needed.
//!
//! Symbols *not* referenced by the wasm-targeted output (verified by
//! grepping `ct_emulator/build/wasm_c_files/*.c` after generation):
//! `fwrite`, `fflush`, `stderr`, `fopen`, `__assert_fail`, `pthread_*`,
//! `__tls_get_addr`, `setjmp`/`longjmp`, `signal`, `getenv`. We do not
//! stub them; if a future Nim version starts emitting them, the
//! wasm-ld pass will fail loudly and this module is where they belong.

#![cfg(target_arch = "wasm32")]
#![allow(clippy::missing_safety_doc)]

use core::ffi::c_int;

/// `exit(int)` shim. Nim's `system.nim` calls this on unhandled
/// exceptions; on the web we trap into JavaScript so the error
/// surfaces through the host's normal exception path instead of an
/// opaque wasm trap.
#[unsafe(no_mangle)]
pub extern "C" fn exit(_status: c_int) -> ! {
    wasm_bindgen::throw_str("ct-mcr: Nim runtime called exit() — fatal emulator error");
}
