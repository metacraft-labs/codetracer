//! Simple in-memory virtual file system for WASM.
//!
//! The `vfs` crate's `MemoryFS` internally calls `SystemTime::now()` when
//! creating files and directories, which panics on `wasm32-unknown-unknown`
//! because time is not implemented on that target. This module provides a
//! minimal HashMap-based alternative that avoids any system calls.
//!
//! Materialized traces are CTFS-only: the only payload pushed into the VFS
//! is the contents of a `.ct` container, consumed via
//! `CTFSTraceReader::from_bytes`. Loose sidecar files (`trace_metadata.json`,
//! `trace.bin`, `trace.json`) are no longer accepted.

use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::sync::Mutex;

/// Simple in-memory file store: maps virtual paths to byte contents.
///
/// The WASM module is single-threaded, so the Mutex is never contended.
/// We use it to satisfy `Sync` requirements for `static` storage.
static VFS_STORE: Lazy<Mutex<HashMap<String, Vec<u8>>>> = Lazy::new(|| Mutex::new(HashMap::new()));

/// Write a file into the in-memory VFS store.
pub fn vfs_write(path: &str, data: Vec<u8>) {
    let mut store = VFS_STORE.lock().unwrap();
    store.insert(path.to_string(), data);
}

/// Read file bytes from the in-memory VFS store.
pub fn vfs_read(path: &str) -> Option<Vec<u8>> {
    let store = VFS_STORE.lock().unwrap();
    store.get(path).cloned()
}

/// Check whether a file exists in the in-memory VFS store.
pub fn vfs_exists(path: &str) -> bool {
    let store = VFS_STORE.lock().unwrap();
    store.contains_key(path)
}
