//! Write the shared byte vectors to `libs/jsbound/vectors/` (or the
//! directory given as the first argument).
//!
//! ```text
//! cargo run --example generate_vectors
//! ```
//!
//! The vectors are a cross-language contract: after regenerating, run
//! `scripts/vendor-jsbound-vectors.sh` in codetracer-js-recorder so the
//! TypeScript decoder is held to the same bytes. The generator refuses to
//! write a catalogue its own decoder disagrees with, and removes files of
//! vectors that no longer exist.

use std::fs;
use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let dir = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("vectors"));
    for v in jsbound::vectors::catalogue() {
        jsbound::vectors::check(&v, &v.bytes).map_err(|e| format!("vector {}: {e}", v.name))?;
    }
    let files = jsbound::vectors::render();
    fs::create_dir_all(&dir)?;
    for entry in fs::read_dir(&dir)? {
        let path = entry?.path();
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or_default()
            .to_string();
        if path.is_file() && !files.contains_key(&name) {
            fs::remove_file(&path)?;
        }
    }
    for (name, bytes) in &files {
        fs::write(dir.join(name), bytes)?;
    }
    println!("wrote {} files to {}", files.len(), dir.display());
    Ok(())
}
