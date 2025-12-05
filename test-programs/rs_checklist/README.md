# Rust Checklist Programs

This suite mirrors the existing Python and Ruby checklists with a
Rust-specific set of probes that exercise language features and
standard-library behaviors useful for debugging CodeTracer. Programs are
small, verbose, and grouped by topic so you can run them together or
drill into a single cluster.

## Running

```bash
# from repo root
nix develop -c cargo run -p rs_checklist

# to run a single module binary (examples)
nix develop -c cargo run -p rs_checklist --bin lexical_bindings
nix develop -c cargo run -p rs_checklist --bin traits_generics
```

The crate targets Rust 1.85+/edition 2024 to capture newer drop-order
and capture semantics. Each module prints a heading before running its
scenarios so missing events are easy to spot.

## Layout

- `src/main.rs` wires the modules and prints section headers.
- `src/macros_support.rs` holds traits used by the proc-macro derive.
- `macros/` is a tiny proc-macro crate providing `#[derive(AutoHello)]`
  to demonstrate attribute macros.

Modules (roughly aligned to the provided coverage map):

- `lexical_bindings`: bindings, shadowing vs `mut`, `const`/`static`/`static mut`,
  `thread_local!`, raw identifiers for reserved keywords, name resolution.
- `iterators_collections`: literals/ranges/struct forms, operator overloading,
  coercions/casts, closures for Fn/FnMut/FnOnce, custom iterators,
  Vec/VecDeque/LinkedList/HashMap/BTreeMap/BinaryHeap, formatting, Unicode-safe
  slicing.
- `ownership_borrowing`: Copy vs move, Clone/Drop, partial moves, RAII drop
  ordering (2024 edition semantics), lifetimes/HRTBs, reborrowing, raw refs.
- `patterns_control`: destructuring (tuples/structs/slices), `ref`/`ref mut`,
  or-patterns, guards, range patterns, let-else, `if let` chains, labelled loops,
  diverging arms using `!`.
- `traits_generics`: supertraits, default methods, trait objects vs `dyn`,
  associated types/consts, GATs, `impl Trait` in args/returns, async fn in traits,
  const generics, PhantomData.
- `errors_runtime`: Result/Option with `?` and `ok_or`, custom error impls,
  file I/O (read/write/missing), `Instant` timing, `panic!` hooks plus
  `catch_unwind`.
- `concurrency_async`: threads with Arc<Mutex>/RwLock, barriers, mpsc + sync
  channels, atomics with orderings, condvars/Once, async/await with joins and a
  manual `Future`.
- `smart_pointers`: Box raw conversions, Rc cycles + Weak, Cell/RefCell borrow
  panic, Arc<Mutex>, Cow, pinning `PhantomPinned` self-references,
  NonZero/NonNull pointer niches.
- `unsafe_macros_const`: unsafe blocks, `MaybeUninit`, unions, `transmute`,
  repr(C) + extern "C" functions, macro_rules + proc-macro derive,
  cfg attributes, const fn/const blocks, visibility modifiers, Any/type_id
  introspection, size/align checks.

Each module exposes a `run()` invoked by `main` with numbered `println!`
output to keep trace review predictable.
