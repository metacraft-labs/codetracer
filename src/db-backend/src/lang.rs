//! The language tag, and the extension-to-language mapping the replay side
//! uses to pick a value loader.
//!
//! The `Lang` enum itself lives in the leaf crate `libs/ct-lang` and is
//! re-exported here, so that `src/tui` and `libs/ct-dap-client` can share the
//! single canonical Rust definition without taking on this crate's `build.rs`
//! (which compiles the Nim MCR emulator) or its tree-sitter grammars.  Every
//! existing `use crate::lang::Lang` keeps working unchanged.
//!
//! `src/tests/cli/lang_enum_contract_test.nim` pins `ct-lang`'s list against
//! the Nim `Lang` in `src/common/common_lang.nim`, and asserts that no other
//! Rust copy of the enum has reappeared in this repository.

use std::ffi::OsStr;
use std::path::Path;

pub use ct_lang::{Lang, lang_wire};

/// Map a source path to the language whose value loader must decode its locals.
///
/// This answer is not advisory: it is serialised to the native replay worker,
/// which uses it verbatim to pick a value loader (there is no auto-detect
/// fallback on the far side).  A missing arm therefore does not degrade to
/// "no syntax highlighting" — it silently decodes the frame's locals with the
/// wrong language's loader.  That is exactly what used to happen for every C
/// and C++ **header**: an RR replay stopped inside an inline function, a
/// template, or any `std::` internal computed `Lang::Unknown` here.
///
/// **The `trace_kind` parameter is gone (LRS-5, second deletion round).**  It
/// had exactly one effect: `.rs` in a `TraceKind::Materialized` container
/// answered `Lang::RustWasm`, an ISA and a recording approach carried on a
/// LANGUAGE tag.  With that variant deleted the answer is `Lang::Rust` either
/// way, and the parameter had nothing left to decide.  It is removed rather
/// than kept as `_trace_kind` because a dead parameter on a dispatch function
/// is an invitation to re-couple the two facts; the trace kind is still
/// available at every call site that has one.
///
/// `Path::extension` is case-sensitive, so extensions that are conventionally
/// spelled upper-case (`.C` for C++, `.F90` for pre-processed Fortran) need
/// their own arms.
///
/// Only extensions for languages this product actually supports appear here;
/// e.g. there is deliberately no `.cu`/`.cuh` arm because nothing in the
/// codebase implements CUDA.
pub fn lang_from_context(path: &Path) -> Lang {
    let extension = path.extension().unwrap_or(OsStr::new("")).to_str().unwrap_or("");
    // for now important mostly for system langs/rr support
    // but still good to add all supported langs: TODO
    match extension {
        // `.rs` is Rust, whichever way the recording was made.  This used to
        // answer `Lang::RustWasm` for a materialized container -- the target
        // ISA and the recording approach welded onto the language, and one of
        // the reasons LRS-4 could not delete the variant.  Nothing here loses
        // a fact: the caller already has `trace_kind`, the persisted
        // `recordings.lang` cell carries all four axes since trace_index
        // schema version 2, and the value loaders this answer picks are the
        // *language's*, which is the same for both routes.
        "rs" => Lang::Rust,
        // `.h` is shared by C and C++; C is the conventional reading and both
        // resolve to the same `COrCppValueLoader` family in the native worker.
        "c" | "h" => Lang::C,
        "cpp" | "cc" | "cxx" | "c++" | "C" | "hpp" | "hh" | "hxx" | "h++" | "ipp" | "tcc" => Lang::Cpp,
        // `.inc`/`.pp`/`.lpr` follow `codetracer-native-backend`'s
        // `utils::lang_from_path` and `debuginfo::lang_for_source_ext`, which
        // both already read `.inc` as Pascal.  Disagreeing here would just move
        // the mismatch rather than remove it.
        "pas" | "pp" | "inc" | "lpr" => Lang::Pascal,
        "nim" => Lang::Nim,
        "d" | "di" => Lang::D,
        "go" => Lang::Go,
        "f90" | "f95" | "f03" | "f08" | "f" | "for" | "ftn" | "F90" | "F95" | "F03" | "F08" => Lang::Fortran,
        "cr" => Lang::Crystal,
        "lean" => Lang::Lean,
        "jl" => Lang::Julia,
        "adb" | "ads" => Lang::Ada,
        "js" | "mjs" | "cjs" => Lang::Javascript,
        "lua" => Lang::Lua,
        "s" | "asm" => Lang::Asm,
        "sol" => Lang::Solidity,
        "masm" => Lang::Masm,
        "sw" => Lang::Sway,
        "move" => Lang::Move,
        "cairo" => Lang::Cairo,
        "circom" => Lang::Circom,
        "leo" => Lang::Leo,
        "tolk" => Lang::Tolk,
        "ak" => Lang::Aiken,
        "cdc" => Lang::Cadence,
        "ex" | "exs" => Lang::Elixir,
        "erl" | "hrl" => Lang::Erlang,
        "php" => Lang::Php,
        "gd" => Lang::GDScript,
        _ => Lang::Unknown,
    }
}

#[cfg(test)]
#[allow(clippy::panic, clippy::unwrap_used)]
mod tests {
    use super::*;

    fn lang_of(path: &str) -> Lang {
        lang_from_context(Path::new(path))
    }

    /// The defect this test exists for: an RR replay stopping inside any C/C++
    /// header (an inline function, a template, any `std::` internal) used to
    /// compute `Lang::Unknown` here, ship it to the native replay worker, and
    /// have the worker decode the frame's locals with the *Rust* value loader.
    #[test]
    fn c_and_cpp_headers_are_not_unknown() {
        for path in [
            "/usr/include/stdio.h",
            "/src/inline_helpers.h",
            "/usr/include/c++/13/vector.hpp",
            "/usr/include/c++/13/bits/stl_vector.hh",
            "/src/tpl.hxx",
            "/src/tpl.h++",
            "/src/tpl.ipp",
            "/usr/include/c++/13/bits/basic_string.tcc",
        ] {
            let lang = lang_of(path);
            assert_ne!(lang, Lang::Unknown, "{path} must not be Unknown");
            assert!(
                matches!(lang, Lang::C | Lang::Cpp),
                "{path} must be a C/C++ language, got {lang:?}"
            );
        }
    }

    #[test]
    fn c_headers_map_to_c() {
        assert_eq!(lang_of("/usr/include/stdio.h"), Lang::C);
        assert_eq!(lang_of("/src/main.c"), Lang::C);
    }

    #[test]
    fn cpp_headers_and_sources_map_to_cpp() {
        for path in [
            "/src/a.cpp",
            "/src/a.cc",
            "/src/a.cxx",
            "/src/a.c++",
            "/src/a.C",
            "/src/a.hpp",
            "/src/a.hh",
            "/src/a.hxx",
            "/src/a.h++",
            "/src/a.ipp",
            "/src/a.tcc",
        ] {
            assert_eq!(lang_of(path), Lang::Cpp, "{path}");
        }
    }

    /// `.C` (upper case) is C++ by convention and `Path::extension` is
    /// case-sensitive, so it needs an arm of its own.  `.c` stays C.
    #[test]
    fn extension_case_is_significant_for_c_plus_plus() {
        assert_eq!(lang_of("/src/a.C"), Lang::Cpp);
        assert_eq!(lang_of("/src/a.c"), Lang::C);
    }

    /// `.inc` is ambiguous; `codetracer-native-backend` already reads it as
    /// Pascal in both `utils::lang_from_path` and
    /// `debuginfo::lang_for_source_ext`.  Agreeing with the worker matters
    /// more than the choice itself, because this value is what the worker
    /// uses.
    #[test]
    fn pascal_include_extensions_agree_with_the_native_worker() {
        for path in ["/src/a.pas", "/src/a.pp", "/src/a.inc", "/src/a.lpr"] {
            assert_eq!(lang_of(path), Lang::Pascal, "{path}");
        }
    }

    #[test]
    fn upper_case_fortran_extensions_are_recognised() {
        for path in ["/src/a.F90", "/src/a.F95", "/src/a.F03", "/src/a.F08", "/src/a.ftn"] {
            assert_eq!(lang_of(path), Lang::Fortran, "{path}");
        }
    }

    #[test]
    fn d_interface_files_map_to_d() {
        assert_eq!(lang_of("/src/a.d"), Lang::D);
        assert_eq!(lang_of("/src/a.di"), Lang::D);
    }

    /// Nothing in this product implements CUDA, so `.cu` must stay Unknown
    /// rather than pretend.
    #[test]
    fn unclaimed_extensions_stay_unknown() {
        for path in ["/src/a.cu", "/src/a.cuh", "/src/a.zig", "/src/a"] {
            assert_eq!(lang_of(path), Lang::Unknown, "{path}");
        }
    }

    /// LRS-5's second deletion round: `.rs` is `Lang::Rust` whatever the
    /// container is.  Before it, a materialized container answered
    /// `Lang::RustWasm` -- an ISA and an approach carried on the language
    /// tag, through a `trace_kind` parameter this function no longer takes.
    /// The recording approach is a per-recording fact the caller already has
    /// and the column now stores; the language is a per-file fact and this
    /// function answers only that.
    #[test]
    fn materialized_rust_is_rust_whatever_the_container() {
        assert_eq!(lang_from_context(Path::new("/src/a.rs")), Lang::Rust);
        assert_eq!(lang_of("/src/a.rs"), Lang::Rust);
    }

    /// `.polkavm` used to map to `Lang::PolkaVM` -- a variant naming a VM
    /// rather than a language.  With the variant gone the extension names no
    /// language, which is the truth: a PolkaVM blob's sources are Rust, and a
    /// `.rs` path in the same recording answers `Lang::Rust` above.
    #[test]
    fn a_polkavm_blob_names_no_source_language() {
        assert_eq!(lang_of("/src/program.polkavm"), Lang::Unknown);
    }

    // -----------------------------------------------------------------
    // Wire names (the de-ordinalised worker socket)
    // -----------------------------------------------------------------

    #[test]
    fn wire_names_round_trip_for_every_variant() {
        for lang in Lang::ALL {
            assert_eq!(
                Lang::from_wire_name(lang.wire_name()),
                Some(lang),
                "{lang:?} does not round-trip through its wire name"
            );
        }
    }

    #[test]
    fn wire_names_are_unique() {
        let mut names: Vec<&'static str> = Lang::ALL.iter().map(|lang| lang.wire_name()).collect();
        names.sort_unstable();
        let count = names.len();
        names.dedup();
        assert_eq!(names.len(), count, "two `Lang` variants share a wire name");
    }

    /// `Lang::ALL` must actually list every variant.  `wire_name` is exhaustive
    /// with no catch-all, so a new variant breaks the build there; this pins
    /// the array's length to the enum's so `ALL` cannot silently fall behind.
    #[test]
    fn all_covers_every_ordinal() {
        use num_traits::FromPrimitive;
        for (index, lang) in Lang::ALL.iter().enumerate() {
            assert_eq!(
                <Lang as FromPrimitive>::from_u8(index as u8),
                Some(*lang),
                "Lang::ALL[{index}] is not the variant with ordinal {index}"
            );
        }
        assert_eq!(<Lang as FromPrimitive>::from_u8(Lang::ALL.len() as u8), None);
    }

    /// The names both repositories know must be spelled identically, because
    /// `codetracer-native-backend`'s `Lang::from_str` is what parses them on
    /// the far side of the worker socket.  This list is copied from that
    /// crate's `recognize::lang_wire_name`; the mirror test there asserts the
    /// same pairs from its side.
    #[test]
    fn wire_names_match_native_backend_spellings() {
        let shared = [
            (Lang::C, "c"),
            (Lang::Cpp, "cpp"),
            (Lang::Rust, "rust"),
            (Lang::Nim, "nim"),
            (Lang::Go, "go"),
            (Lang::Pascal, "pascal"),
            (Lang::Fortran, "fortran"),
            (Lang::D, "d"),
            (Lang::Crystal, "crystal"),
            (Lang::Lean, "lean"),
            (Lang::Julia, "julia"),
            (Lang::Ada, "ada"),
            // `python` / `ruby` were the retired rr backends' names; LRS-4
            // deleted the variants, so the shared list shrank by two and the
            // native backend's own `python` / `ruby` now name nothing here.
            // `rustwasm` / `cppwasm` left the same way in LRS-5's second
            // deletion round: `codetracer-native-backend` still HAS those two
            // variants in its own (deliberately different) enum and still
            // parses the names, but this core no longer emits them, so they
            // are no longer *shared* -- they joined `small` / `odin` /
            // `vlang` / `csharp` as native-backend-only spellings.  Its own
            // mirror test must drop the two rows; recorded here because this
            // list is the half that moved.
            (Lang::RubyDb, "rubydb"),
            (Lang::Javascript, "javascript"),
            (Lang::Lua, "lua"),
            (Lang::Asm, "asm"),
            (Lang::Noir, "noir"),
            (Lang::PythonDb, "pythondb"),
            (Lang::Unknown, "unknown"),
        ];
        for (lang, name) in shared {
            assert_eq!(lang.wire_name(), name, "{lang:?}");
        }
    }

    #[test]
    fn unknown_wire_names_are_rejected_not_defaulted() {
        assert_eq!(Lang::from_wire_name("perl"), None);
        assert_eq!(Lang::from_wire_name(""), None);
        assert_eq!(Lang::from_wire_name("C"), None);
        assert_eq!(Lang::from_wire_name("0"), None);
    }
}
