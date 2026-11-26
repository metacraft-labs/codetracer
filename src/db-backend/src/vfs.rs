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
use std::sync::atomic::{AtomicU64, Ordering};

/// Simple in-memory file store: maps virtual paths to byte contents.
///
/// The WASM module is single-threaded, so the Mutex is never contended.
/// We use it to satisfy `Sync` requirements for `static` storage.
static VFS_STORE: Lazy<Mutex<HashMap<String, Vec<u8>>>> = Lazy::new(|| Mutex::new(HashMap::new()));

/// Take the store, tolerating a poisoned lock.
///
/// `unwrap()` on the guard is what this used to do, and it is now a
/// `clippy::unwrap_used` error because `mod vfs` is compiled into the
/// `replay-server` binary (whose crate root denies that lint) and not only
/// into the wasm library. Poisoning is not a real state here — the three
/// critical sections below are a `HashMap` insert, a `get`, and a
/// `contains_key`, none of which can panic — so recovering the inner value is
/// both correct and the only behaviour that never aborts a replay session
/// over an unrelated panic elsewhere.
fn store() -> std::sync::MutexGuard<'static, HashMap<String, Vec<u8>>> {
    VFS_STORE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Bumped by every [`vfs_write`], so a cache of "this path could not be read"
/// can tell that the store has changed since it looked.
static VFS_GENERATION: AtomicU64 = AtomicU64::new(0);

/// Write a file into the in-memory VFS store.
pub fn vfs_write(path: &str, data: Vec<u8>) {
    let mut store = store();
    store.insert(path.to_string(), data);
    VFS_GENERATION.fetch_add(1, Ordering::SeqCst);
}

/// How many writes the store has seen. Two equal readings mean nothing was
/// written in between, so a lookup that failed at the first still fails.
pub fn vfs_generation() -> u64 {
    VFS_GENERATION.load(Ordering::SeqCst)
}

/// Read file bytes from the in-memory VFS store.
pub fn vfs_read(path: &str) -> Option<Vec<u8>> {
    let store = store();
    store.get(path).cloned()
}

/// Check whether a file exists in the in-memory VFS store.
pub fn vfs_exists(path: &str) -> bool {
    let store = store();
    store.contains_key(path)
}
