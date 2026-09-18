//! The SEEKABLE call-argument decode, covered from a real container.
//!
//! # Why this file exists
//!
//! Two copies of the call-argument decode are live in db-backend, and until
//! this file only one of them had integration coverage:
//!
//! | copy | site | reached by |
//! |---|---|---|
//! | seekable | `ctfs_trace_reader/call_stream_source.rs` `decode_args` | `seekable_call()`, `Calltrace::new`, the pure-Rust/browser open, follow refresh |
//! | inline (Nim FFI) | `ctfs_trace_reader/mod.rs` `open_new_format_nim` | `reader.call()` on the native production open |
//!
//! `tests/ctfs_call_args_roundtrip_test.rs` reads `reader.call(key)` and so
//! exercises the INLINE copy. It looks like coverage of the seekable one and is
//! not: planting a `panic!` in `decode_args` leaves it green. That was measured
//! on 2026-09-17 and is the reason this file was written, so the measurement is
//! repeated here as a standing instruction rather than a claim — see
//! `codetracer-specs/Trace-Files/CTFS-Lazy-Seekable-Coverage.milestones.org`
//! M8, verification `seekable_call_arg_decode_is_covered_by_an_integration_test`.
//!
//! # What this asserts, and why in this order
//!
//! The property that matters is that argument NAMES survive. That is what
//! `codetracer-trace-format` `a797cb8` ("fix(calls.dat): keep every argument,
//! and its name") exists to protect: the writer used to collapse a call's
//! arguments into ONE entry under a synthetic `varname_id` of 0, which kept the
//! first argument's bytes and threw away every name. A test that counts
//! arguments, or that checks values alone, cannot see that defect — a collapsed
//! record and a single-argument call are indistinguishable by count, and a
//! value compared without its name is a value attributed to nothing.
//!
//! So the fixture gives one call THREE distinct named arguments with THREE
//! distinct values, and the assertions run in this order:
//!
//! 1. **Anti-vacuity floors first.** The container really has the calls and the
//!    arguments the fixture wrote. An empty decode satisfies "no argument is
//!    wrong" by producing nothing, and "every name resolved" vacuously; both
//!    floors are asserted BEFORE any per-argument comparison.
//! 2. **A name resolves to non-empty text** — `varname_id` is an index into
//!    `varnames.dat`, and an index that resolves to nothing is the collapsed
//!    form wearing the right shape.
//! 3. **Then** names in declaration order, and only then the values.
//!
//! # Control arm
//!
//! `args_agree_between_the_seekable_and_materialized_paths` reads the same
//! fixture through `reader.call()` — the inline copy — and requires the same
//! arguments. A divergence is therefore attributable to one of the two decoders
//! rather than to the fixture, which is the distinction the existing
//! `seekable_and_materialized_call_trees_agree` cross-check cannot draw: it
//! compares key/function_id/parent/depth/children and deliberately omits `args`.
//!
//! # Fixture
//!
//! Written in-test with the Rust `CtfsTraceWriter`, the same way
//! `tests/seekable_call_stream_test.rs` builds its bundle, so there is no
//! external dependency and no prerequisite that could be missing. A small
//! `calls.dat` chunk size puts the argument-bearing call and the zero-argument
//! call in DIFFERENT chunks, so a seek that decodes arguments from the wrong
//! chunk cannot pass by coincidence.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::*;
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::ctfs_trace_reader::call_stream_source::SeekableCallStream;
use db_backend::trace_reader::TraceReader;

/// The argument-bearing call's key in the fixture below.
const THREE_ARG_CALL: CallKey = CallKey(2);
/// A call written with no arguments at all, in a different `calls.dat` chunk.
const ZERO_ARG_CALL: CallKey = CallKey(3);

/// The three arguments `sum3` is called with, in declaration order.
/// Distinct names AND distinct values: if the decode loses order, or pairs a
/// name with the wrong value, no two entries can cover for each other.
const EXPECTED_ARGS: [(&str, i64); 3] = [("alpha", 11), ("beta", 22), ("gamma", 33)];

/// Write a small split-stream `.ct` with a call stream.
///
/// Call records, by `call_key`:
/// ```text
///   <toplevel>()                     -> 0   (implicit, emitted by start())
///     main()                         -> 1
///       sum3(alpha=11, beta=22, gamma=33) -> 2   <- THREE_ARG_CALL
///       noargs()                     -> 3   <- ZERO_ARG_CALL
/// ```
/// `calls.dat` chunk size 2 puts records 0–1 in chunk 0 and 2–3 in chunk 1.
fn write_trace(dir: &tempfile::TempDir) -> PathBuf {
    let path_buf = dir.path().join("trace");
    let mut writer = CtfsTraceWriter::new("seekable_call_args_prog", &[])
        .with_call_stream(true)
        .with_calls_chunk_size(2);
    TraceWriter::begin_writing_trace_events(&mut writer, &path_buf).unwrap();

    let src = Path::new("/test/prog.rs");
    TraceWriter::start(&mut writer, src, Line(1));

    let int_type = TraceWriter::ensure_type_id(&mut writer, TypeKind::Int, "Int");
    let main_fn = TraceWriter::ensure_function_id(&mut writer, "main", src, Line(1));
    let sum3 = TraceWriter::ensure_function_id(&mut writer, "sum3", src, Line(10));
    let noargs = TraceWriter::ensure_function_id(&mut writer, "noargs", src, Line(20));

    // main()  -> call_key 1
    TraceWriter::register_call(&mut writer, main_fn, vec![]);
    TraceWriter::register_step(&mut writer, src, Line(2));

    // sum3(alpha=11, beta=22, gamma=33)  -> call_key 2
    let args: Vec<FullValueRecord> = EXPECTED_ARGS
        .iter()
        .map(|(name, value)| {
            TraceWriter::arg(
                &mut writer,
                name,
                ValueRecord::Int {
                    i: *value,
                    type_id: int_type,
                },
            )
        })
        .collect();
    TraceWriter::register_call(&mut writer, sum3, args);
    TraceWriter::register_step(&mut writer, src, Line(11));
    TraceWriter::register_return(
        &mut writer,
        ValueRecord::Int {
            i: 66,
            type_id: int_type,
        },
    );

    // noargs()  -> call_key 3
    TraceWriter::register_call(&mut writer, noargs, vec![]);
    TraceWriter::register_step(&mut writer, src, Line(21));
    TraceWriter::register_return(&mut writer, ValueRecord::None { type_id: TypeId(0) });

    // main returns
    TraceWriter::register_return(&mut writer, ValueRecord::None { type_id: TypeId(0) });

    TraceWriter::finish_writing_trace_events(&mut writer).unwrap();
    path_buf.with_extension("ct")
}

/// Pull the `i` out of a `ValueRecord::Int`, failing by name on anything else.
/// A wrong variant is a real defect (the collapsed form decoded one value's CBOR
/// map as a vector, which is exactly this kind of mismatch), so it must not be
/// silently skipped.
fn int_value(label: &str, value: &ValueRecord) -> i64 {
    match value {
        ValueRecord::Int { i, .. } => *i,
        other => panic!("{label}: expected ValueRecord::Int, got {other:?}"),
    }
}

/// THE GATE. The seekable decode — `decode_args` — returns every argument of a
/// call, in order, each keeping its own name.
///
/// This is the test whose RED state the milestone's falsifier asks for: plant a
/// `panic!` in `decode_args` (or make it return an empty `Vec`) and this must
/// fail, while `ctfs_call_args_roundtrip_test` stays green.
#[test]
fn seekable_call_args_keep_every_argument_and_its_name() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir);
    let reader = CTFSTraceReader::open(&ct).expect("open split bundle");

    // --- Anti-vacuity floor 1: the container really has the calls. ---
    let n = reader
        .seekable_call_count()
        .expect("the fixture sets has_call_stream, so a seekable call stream must be attached");
    assert!(
        n >= 4,
        "fixture floor: expected at least 4 call records (toplevel, main, sum3, noargs), got {n} — \
         a container that decoded no calls would satisfy every argument assertion below by \
         having nothing to disagree with"
    );

    let call = reader
        .seekable_call(THREE_ARG_CALL)
        .expect("call_key 2 (sum3) present in the seekable stream");

    // --- Anti-vacuity floor 2: the arguments are really there. ---
    // This is the assertion the collapsed pre-a797cb8 form fails: it produced
    // ONE entry for a three-argument call. An `assert!(!is_empty())` would pass
    // against that form, so the floor is the full count.
    assert_eq!(
        call.args.len(),
        EXPECTED_ARGS.len(),
        "sum3 was written with {} arguments and the seekable decode returned {}. \
         Exactly 1 is the collapsed pre-a797cb8 shape (one synthetic entry holding the whole \
         vector); 0 is a decode that dropped them. Decoded: {:?}",
        EXPECTED_ARGS.len(),
        call.args.len(),
        call.args
    );

    // --- Anti-vacuity floor 3: a name resolves to non-empty TEXT, before any
    // value is compared. `variable_id` indexes varnames.dat; an id that
    // resolves to nothing is the name-loss defect wearing the right shape, and
    // the name comparisons below would then all be `None == None`. ---
    let first_name = reader.variable_name(call.args[0].variable_id).unwrap_or_else(|| {
        panic!(
            "argument 0's variable_id {:?} does not resolve in varnames.dat — the interned \
                 name is what a797cb8 exists to preserve, and an unresolvable id means it is gone",
            call.args[0].variable_id
        )
    });
    assert!(
        !first_name.is_empty(),
        "argument 0 resolved to an EMPTY name; an empty string would make every name comparison \
         below compare nothing"
    );

    // --- Now the property: names, in declaration order. ---
    let decoded_names: Vec<&str> = call
        .args
        .iter()
        .enumerate()
        .map(|(i, arg)| {
            reader.variable_name(arg.variable_id).unwrap_or_else(|| {
                panic!(
                    "argument {i}'s variable_id {:?} does not resolve in varnames.dat",
                    arg.variable_id
                )
            })
        })
        .collect();
    let expected_names: Vec<&str> = EXPECTED_ARGS.iter().map(|(n, _)| *n).collect();
    assert_eq!(
        decoded_names, expected_names,
        "the seekable decode must return each argument under its OWN name, in declaration order"
    );

    // --- And only then the values, each attributed to its name. ---
    for (i, ((name, expected), arg)) in EXPECTED_ARGS.iter().zip(call.args.iter()).enumerate() {
        let got = int_value(&format!("argument {i} ({name})"), &arg.value);
        assert_eq!(
            got, *expected,
            "argument {i} is named {name} and must carry {expected}; a name paired with another \
             argument's value is the same data loss in a shape that passes a count check"
        );
    }

    // --- A zero-argument call still reads as zero, so the assertions above
    // cannot be satisfied by a decoder that invents arguments. It lives in a
    // different calls.dat chunk, so this also proves the seek addressed the
    // right chunk. ---
    let empty = reader
        .seekable_call(ZERO_ARG_CALL)
        .expect("call_key 3 (noargs) present in the seekable stream");
    assert!(
        empty.args.is_empty(),
        "noargs() was written with no arguments; the seekable decode returned {:?}",
        empty.args
    );
}

/// CONTROL ARM. The same fixture through the MATERIALIZED path (`reader.call`,
/// which on this open path is `open_new_format_nim`'s inline copy) decodes the
/// same arguments.
///
/// Its job is attribution: if the gate above goes red while this one stays
/// green, the fault is in `decode_args` and not in the fixture or the writer.
/// The existing `seekable_and_materialized_call_trees_agree` cross-check in
/// `seekable_call_stream_test.rs` cannot serve this role — it compares
/// key/function_id/parent_key/depth/children_keys and omits `args` entirely.
#[test]
fn args_agree_between_the_seekable_and_materialized_paths() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir);
    let reader = CTFSTraceReader::open(&ct).expect("open split bundle");

    let n = reader.seekable_call_count().expect("seekable stream present");
    assert!(n >= 4, "fixture floor: expected at least 4 call records, got {n}");
    assert_eq!(
        n,
        reader.call_count(),
        "the two paths must see the same number of calls before their arguments can be compared"
    );

    // Assert the control arm is not vacuous: at least one call on the
    // MATERIALIZED path really carries arguments. Two decoders that both
    // returned nothing would agree perfectly.
    let materialized_args: usize = (0..n)
        .filter_map(|i| reader.call(CallKey(i as i64)))
        .map(|c| c.args.len())
        .sum();
    assert!(
        materialized_args >= EXPECTED_ARGS.len(),
        "the materialized path decoded {materialized_args} arguments across {n} calls; the \
         fixture writes {}. Two empty decoders agree with each other and prove nothing",
        EXPECTED_ARGS.len()
    );

    for i in 0..n {
        let key = CallKey(i as i64);
        let seek = reader.seekable_call(key).expect("seekable call");
        let materialized = reader.call(key).expect("materialized call").clone();

        assert_eq!(
            seek.args.len(),
            materialized.args.len(),
            "call {i}: seekable decoded {} arguments, materialized decoded {}",
            seek.args.len(),
            materialized.args.len()
        );
        for (j, (s, m)) in seek.args.iter().zip(materialized.args.iter()).enumerate() {
            assert_eq!(
                s.variable_id, m.variable_id,
                "call {i} argument {j}: the two paths disagree about which varnames.dat entry \
                 names this argument"
            );
            assert_eq!(
                s.value, m.value,
                "call {i} argument {j} (name id {:?}): the two paths decoded different values",
                s.variable_id
            );
        }
    }
}

/// The same property, reached WITHOUT a `CTFSTraceReader` at all — straight
/// through `SeekableCallStream`, which is what `Calltrace::new` and the
/// pure-Rust/browser open path use.
///
/// This exists because `CTFSTraceReader::open` also builds a materialized
/// `db.calls`, so a reader-level assertion could in principle be served by
/// state the seekable stream did not produce. Here there is no other source.
#[test]
fn seekable_call_stream_alone_decodes_named_args() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir);

    let stream = SeekableCallStream::open(&ct)
        .expect("open seekable call stream")
        .expect("the fixture sets has_call_stream");

    assert!(
        stream.call_count() >= 4,
        "fixture floor: expected at least 4 call records, got {}",
        stream.call_count()
    );

    let call = stream.call(THREE_ARG_CALL).expect("call_key 2 (sum3) present");
    assert_eq!(
        call.args.len(),
        EXPECTED_ARGS.len(),
        "sum3's {} arguments must survive the stream-level decode; got {:?}",
        EXPECTED_ARGS.len(),
        call.args
    );

    // `varnames.dat` is not reachable from the bare stream, so the name is
    // asserted as the interned ID it must be: three arguments, three DISTINCT
    // ids, none of them the synthetic 0 the collapsed form used. That is the
    // strongest name assertion available without the interning table, and it
    // still fails against the defect this covers.
    let ids: Vec<usize> = call.args.iter().map(|a| a.variable_id.0).collect();
    let mut sorted = ids.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(
        sorted.len(),
        ids.len(),
        "the three arguments must carry three DISTINCT varnames.dat ids; got {ids:?}, which \
         means at least two arguments are attributed to the same name"
    );

    for (i, ((name, expected), arg)) in EXPECTED_ARGS.iter().zip(call.args.iter()).enumerate() {
        let got = int_value(&format!("argument {i} ({name})"), &arg.value);
        assert_eq!(got, *expected, "argument {i} ({name}) value");
    }
}
