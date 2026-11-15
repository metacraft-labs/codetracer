//! Records the compiler Cargo resolved for this build.
//!
//! Cargo sets `RUSTC` for build scripts to "the compiler that Cargo has
//! resolved to use"
//! (https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-sets-for-build-scripts).
//! That is the only place the repro build's compiler is observable: the engine
//! provisions it onto the Cargo edge's PATH as a sub-tool, so neither the
//! graph's evaluation nor a separate shell action can see it.
//!
//! Measured: with no override Cargo passes the BARE name `rustc`, which it
//! looked up on its own PATH. This script inherits that PATH, so it resolves
//! the name the same way (first match in PATH order, as a program would be
//! found) and canonicalises the result. The absolute path is handed to the
//! binary as a compile-time variable, and the binary prints it.
//!
//! Cargo re-runs a build script when the compiler changes (the rustc version
//! is part of every fingerprint); `rerun-if-env-changed` adds RUSTC and PATH
//! themselves, so a different compiler of the same version is seen too.

use std::env;
use std::path::{Path, PathBuf};

fn resolve(name: &str) -> PathBuf {
    let candidate = Path::new(name);
    if candidate.components().count() > 1 {
        return candidate.to_path_buf();
    }
    let suffixes: &[&str] = if cfg!(windows) { &[".exe", ""] } else { &[""] };
    for dir in env::split_paths(&env::var_os("PATH").unwrap_or_default()) {
        for suffix in suffixes {
            let full = dir.join(format!("{name}{suffix}"));
            if full.is_file() {
                return full;
            }
        }
    }
    panic!("ct-repro-cargo-probe: cargo named the compiler `{name}`, and it is not on PATH");
}

fn main() {
    let rustc = env::var("RUSTC").expect("cargo sets RUSTC for build scripts");
    let path = resolve(&rustc);
    let path = path.canonicalize().unwrap_or(path);
    println!("cargo:rerun-if-env-changed=RUSTC");
    println!("cargo:rerun-if-env-changed=PATH");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rustc-env=CT_REPRO_CARGO_PROBE_RUSTC={}", path.display());
}
