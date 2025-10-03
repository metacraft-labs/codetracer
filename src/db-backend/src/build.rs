// build.rs
use std::env;
use std::path::PathBuf;

fn main() {
    // Re-run if sysroot headers change
    println!("cargo:rerun-if-changed=wasm-sysroot/include");

    let sysroot = env::var("SYSROOT").unwrap_or_else(|_| {
        let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.push("wasm-sysroot");
        p.display().to_string()
    });

    // Expose SYSROOT to your Rust code if you want (env!("SYSROOT"))
    println!("cargo:rustc-env=SYSROOT={}", sysroot);
}
