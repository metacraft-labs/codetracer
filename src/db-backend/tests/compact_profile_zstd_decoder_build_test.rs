//! CCP-5 deliverable 5 — does a BlockTracer-only build that OMITS the Zstd
//! decoder EXIST?
//!
//! The deliverable asks for a MEASUREMENT about the build, not a consequence of
//! the campaign, so this file measures the build's own declarations rather than
//! asserting what someone intended. It reads `Cargo.toml` and
//! `build_wasm.sh` — the two files that between them decide what ends up in the
//! WebAssembly module — and pins the answer.
//!
//! THE ANSWER AS MEASURED: no. There is exactly one wasm artifact, the decoder
//! is unconditional in it, and BlockTracer consumes that same artifact rather
//! than building its own. The assertions below are written so that a future
//! build which DOES drop the decoder fails this arm and has to say so, which is
//! the only way a recorded measurement stays a measurement.

const CARGO_TOML: &str = include_str!("../Cargo.toml");
const BUILD_WASM_SH: &str = include_str!("../build_wasm.sh");

/// Strip `#` comments so a declaration is never found inside prose about it.
/// This crate's manifest is heavily commented and several comments name
/// `ruzstd`, `flate2` and `object/compression` precisely in order to explain
/// what is NOT enabled.
fn uncommented(text: &str) -> String {
    text.lines()
        .map(|l| match l.find('#') {
            Some(i) => &l[..i],
            None => l,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn the_wasm_build_carries_the_zstd_decoder_unconditionally() {
    let manifest = uncommented(CARGO_TOML);

    // (1) The wasm32 target table declares a decoder, and declares it as a
    //     PLAIN dependency: no `optional = true`, so no feature can remove it
    //     and no `--no-default-features` can either.
    let wasm_table = manifest
        .split("[target.'cfg(target_arch = \"wasm32\")'.dependencies]")
        .nth(1)
        .expect("the manifest no longer has a wasm32 target dependency table; re-take this measurement")
        .split("\n[")
        .next()
        .expect("the wasm32 table has an end");
    let ruzstd_line = wasm_table
        .lines()
        .find(|l| l.trim_start().starts_with("ruzstd"))
        .unwrap_or_else(|| {
            panic!(
                "the wasm32 target table no longer declares ruzstd. If the decoder has been made \
                 optional or removed, THAT is the finding CCP-5 deliverable 5 asks for and this \
                 assertion is what should carry it:\n{wasm_table}"
            )
        });
    assert!(
        !ruzstd_line.contains("optional"),
        "ruzstd is now optional in the wasm build: {ruzstd_line}. A build that can omit the \
         decoder now exists, which is the opposite of what CCP-5 measured — record it."
    );

    // (2) The wasm build line itself. `--no-default-features` plus exactly one
    //     feature, and that feature does not mention compression at all — so
    //     the narrowest wasm build this repository knows how to make still
    //     links a decoder.
    let build_line = BUILD_WASM_SH
        .lines()
        .find(|l| l.contains("cargo build") && l.contains("wasm32-unknown-unknown"))
        .expect("build_wasm.sh no longer builds for wasm32; re-take this measurement");
    assert!(
        build_line.contains("--no-default-features") && build_line.contains("--features browser-transport"),
        "the wasm build invocation changed: {build_line}"
    );
    let browser_transport = manifest
        .split("browser-transport = [")
        .nth(1)
        .expect("the browser-transport feature is gone; re-take this measurement")
        .split(']')
        .next()
        .expect("the feature list has an end");
    for word in ["zstd", "ruzstd", "compression", "flate"] {
        assert!(
            !browser_transport.contains(word),
            "browser-transport now mentions {word:?}, so the decoder may be feature-controlled \
             after all: {browser_transport}"
        );
    }

    // (3) There is no second wasm build, and no feature whose name proposes a
    //     decoder-free one. If one is added, this is where it must be declared.
    let features_block = manifest
        .split("\n[features]")
        .nth(1)
        .expect("the manifest has a [features] section")
        .split("\n[")
        .next()
        .expect("the features section has an end");
    for proposed in ["no-zstd", "without-zstd", "blocktracer-only", "compact-only"] {
        assert!(
            !features_block.contains(proposed),
            "a {proposed:?} feature now exists; CCP-5 recorded that no decoder-free build did, \
             and the finding has to be updated rather than the arm"
        );
    }

    println!("CCP-5 deliverable 5 — MEASURED from the build's own files:");
    println!("  wasm32 decoder declaration: {}", ruzstd_line.trim());
    println!("  wasm build invocation:      {}", build_line.trim());
    println!("  browser-transport features: no compression entry of any kind");
    println!(
        "  verdict: NO BlockTracer-only build exists that omits the Zstd decoder. There is one \
         wasm artifact and the decoder is unconditional in it."
    );
}

/// The other half of the same question, and the half that decides it: the
/// decoder cannot be dropped from a build nobody makes.
///
/// A compact container with genuinely RAW members needs no decoder to read. A
/// build that only ever opened such containers could therefore drop one — which
/// is what the campaign's Introduction says. What makes that hypothetical is
/// that the module which would drop it also serves the FULL profile, and the
/// call sites that need the decoder are not on the compact path at all.
#[test]
fn the_decoder_is_needed_by_the_full_profile_and_not_by_a_raw_compact_container() {
    // The decoder call sites, counted from the source rather than asserted:
    // they are the per-chunk readers of `spans.dat` and `events.dat`, both of
    // which are FULL-profile chunked tables.
    let span_stream = include_str!("../src/ctfs_trace_reader/span_stream.rs");
    let event_stream = include_str!("../src/ctfs_trace_reader/event_stream_source.rs");
    assert!(
        span_stream.contains("zstd::decode_all") && span_stream.contains("ruzstd::"),
        "span_stream.rs no longer carries both decoder arms; the measurement below is stale"
    );
    assert!(
        event_stream.contains("zstd::decode_all"),
        "event_stream_source.rs no longer decodes zstd; the measurement below is stale"
    );

    // And the COMPACT read path carries no decompression at all — asserted
    // against the loader's own source, which is the claim that makes a
    // decoder-free consumer conceivable in the first place.
    let container = include_str!("../src/ctfs_trace_reader/ctfs_container.rs");
    let compact_branch = container
        .split("// ── The COMPACT read path")
        .nth(1)
        .expect("the compact read path is no longer marked in ctfs_container.rs")
        .split("if entry.map_block == 0 {")
        .next()
        .expect("the compact branch has an end");
    for word in ["zstd", "decompress", "inflate", "ChunkedReader"] {
        assert!(
            !compact_branch.contains(word),
            "the compact read path now mentions {word:?}: {compact_branch}"
        );
    }
    println!(
        "the compact read path is one addition and one positional read — no decompression. The \
         decoder stays because the SAME module serves the full profile, not because the compact \
         profile needs it."
    );
}
