pub mod concurrency_async;
pub mod errors_runtime;
pub mod iterators_collections;
pub mod lexical_bindings;
pub mod macros_support;
pub mod ownership_borrowing;
pub mod patterns_control;
pub mod smart_pointers;
pub mod traits_generics;
pub mod unsafe_macros_const;

use std::error::Error;

extern crate self as rs_checklist;

pub type ChecklistResult = Result<(), Box<dyn Error + Send + Sync>>;

/// Reusable heading printer so standalone binaries can show section names.
pub fn heading(name: &str) {
    println!("\n== {name} ==");
}

/// Returns the modules in the canonical execution order used by `main`.
pub fn modules() -> &'static [(&'static str, fn() -> ChecklistResult)] {
    &[
        ("lexical_bindings", lexical_bindings::run),
        ("iterators_collections", iterators_collections::run),
        ("ownership_borrowing", ownership_borrowing::run),
        ("patterns_control", patterns_control::run),
        ("traits_generics", traits_generics::run),
        ("errors_runtime", errors_runtime::run),
        ("concurrency_async", concurrency_async::run),
        ("smart_pointers", smart_pointers::run),
        ("unsafe_macros_const", unsafe_macros_const::run),
    ]
}

pub fn run_all() -> ChecklistResult {
    for (name, runner) in modules() {
        heading(name);
        runner()?;
    }
    Ok(())
}
