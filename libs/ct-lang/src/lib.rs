//! The canonical CodeTracer `Lang` enum for Rust.
//!
//! # Why this crate exists
//!
//! `Lang` used to be written out by hand in four places in this repository:
//! `src/common/common_lang.nim` (40 values), `src/db-backend/src/lang.rs`
//! (40), `src/tui/src/lang.rs` (**37** — it stopped at `Solana` and was
//! missing `Elixir`, `Erlang` and `Php`) and
//! `libs/ct-dap-client/src/types/common.rs` (**21**, diverging from ordinal 6
//! onwards).  Every one of those copies carries an *ordinal* across a wire or
//! a database column, so a copy that falls behind does not fail loudly: it
//! decodes the integer as a different language, or as no language at all.
//!
//! The three Rust copies are now this one file.  The Nim copy cannot be
//! deduplicated by sharing code — it is a different language — so it stays a
//! second hand-maintained definition, pinned against this one by
//! `src/tests/cli/lang_enum_contract_test.nim`.
//!
//! # Why the definition is not simply `db-backend`'s
//!
//! The obvious consolidation is "delete the copies, depend on `db_backend`".
//! That does not work, for two independent reasons:
//!
//! * `src/db-backend` is the `replay-server` package.  It has a 1170-line
//!   `build.rs` that shells out to Nim to compile the MCR emulator into a
//!   cdylib, its default features pull in two dozen tree-sitter C grammars,
//!   and its path dependencies reach out of this repository into
//!   `../../../codetracer-trace-format/*`.  Making the TUI — a crate whose
//!   whole lock file is 161 packages, and which CI builds standalone on
//!   Windows — depend on all of that to obtain a 40-variant enum would be a
//!   very large price for a type with no code in it.
//! * `libs/ct-dap-client` is a **dev-dependency of `db-backend` itself**.
//!   Pointing it at `replay-server` would make the DAP test client build the
//!   Nim emulator before it could compile.
//!
//! So the enum lives in a leaf crate that all three can depend on cheaply, and
//! `db-backend`'s `lang` module re-exports it so that every existing
//! `use crate::lang::Lang` keeps working.  `db-backend` remains the home of
//! the *logic* (`lang_from_context` and its tests); this crate holds only the
//! ordinal contract and the things that are pure functions of it.
//!
//! # No wire carries the ordinal any more — the layout is still pinned, not yet free
//!
//! What the integer value of a `Lang` is and is not carried by, as of LRS-1
//! (both tranches):
//!
//! * **no longer** the `lang` column of the persisted
//!   `~/.local/share/codetracer/trace_index.db` `recordings` table — it holds
//!   the enum *name* since trace_index schema version 1
//!   (`src/common/trace_index.nim`);
//! * **no longer** the `ct/load-locals` DAP request: its `lang` field is the
//!   [`Lang::wire_name`] on both sides — the Nim frontend writes
//!   `langWireName(lang)` and `db_backend::task::CtLoadLocalsArguments` reads
//!   it through [`lang_wire`], refusing a bare integer;
//! * **no longer** the tracepoint hop: `Tracepoint.lang` (`ct/run-tracepoints`)
//!   and `Stop.lang` (`ct/tracepoint-results`) were DELETED rather than
//!   converted, because both were dead — the db-backend never read the first
//!   (it takes the language from each stop's path) and always sent
//!   `Lang::default()` for the second, and no Nim reader consulted either.
//!   A receiver still tolerates a legacy `lang` key from an older sender and
//!   ignores it.
//!
//! Accordingly `Lang` derives **no serde implementation at all**: the only
//! way to put one on a wire is the explicit [`lang_wire`] adapter, which
//! writes and reads the name.  A struct field `lang: Lang` without
//! `#[serde(with = "…lang_wire")]` does not compile in a `Serialize` /
//! `Deserialize` derive — that is deliberate, and
//! `src/tests/cli/lang_enum_contract_test.nim` asserts the derive stays
//! absent and that every `lang: Lang` field on a serde struct carries the
//! adapter.
//!
//! The `#[repr(u8)]`, `FromPrimitive` and the explicit ordinal remain: the
//! Nim enum and this one are still pinned ordinal for ordinal by the contract
//! test (a lockstep renumber is a test-visible refactor, not a wire break),
//! and the retiring Rust TUI still decodes an integer `lang` column with
//! `FromPrimitive` from a table that no longer exists.  LRS-4 (2026-09-21)
//! made the first such renumber: `Unknown` moved to ordinal 0 -- so that
//! `Lang::default()` and Nim's zero-initialised `result` both say "unknown"
//! rather than "C" -- and `Python` / `Ruby`, the retired rr/gdb backends
//! whose only content was a diagnostic, were deleted (`PythonDb` / `RubyDb`
//! are the Python and Ruby identity; their wire names `pythondb` / `rubydb`
//! are unchanged because `codetracer-native-backend`'s `Lang::from_str`
//! knows them by those spellings).  LRS-5's SECOND deletion round
//! (2026-09-21) made the next one: `RustWasm` / `CppWasm` and `PolkaVM` /
//! `Solana` are gone, 39 variants -> **35**.  Each was a non-language axis
//! welded onto a language enum, and each was kept only while the persisted
//! `recordings.lang` column was one `Lang` name; trace_index schema version 2
//! stores all four axes (`rs-wasm-unknown-vm`,
//! `unknown-solanasbf-unknown-vm`) and the Nim `Trace.approach` carries the
//! recording approach per recording, so nothing has to say "wasm" or "no
//! source language" with a variant any more.  What is left is one variant per
//! source language.
//!
//! It is **not** carried to `codetracer-native-backend`.  That repository has
//! its own, deliberately different `Lang` (the languages the native backend
//! *supports*, with a `Small` variant at ordinal 21), and the replay worker
//! socket between the two crates carries language *names* — see
//! [`Lang::wire_name`].
//!
//! # The four axes (LRS-2B)
//!
//! `Lang` answers four questions with one value; the Nim side splits them into
//! [`SourceLanguage`], [`TargetIsa`], [`Toolchain`] and [`RecordingApproach`]
//! (`src/common/target_axes.nim`), and this crate carries the same four enums
//! so a Rust consumer can speak the same vocabulary.  Unlike `Lang` they carry
//! **no ordinal contract**: there is no `#[repr(u8)]` and no `serde_repr`, and
//! `src/tests/cli/lang_enum_contract_test.nim` asserts that stays so.  Every
//! axis value crosses every boundary as its `wire_name`, which is the Nim
//! `token(v)` spelling, pinned by the same test name for name and variant for
//! variant.  Each `wire_name` is an exhaustive `match` for the same reason
//! [`Lang::wire_name`] is: a new variant must not compile until it is named.

use num_derive::FromPrimitive;

/// Identifies a programming language implementation.
///
/// Ordinals MUST match the Nim `Lang` enum in `src/common/common_lang.nim`.
/// `src/tests/cli/lang_enum_contract_test.nim` asserts that mechanically, name
/// for name and ordinal for ordinal, and fails rather than silently comparing
/// nothing if it cannot locate either list.  `Unknown` is ordinal 0 and the
/// `Default` (LRS-4): a `Lang` nobody set is the sentinel, never C.
///
/// Deliberately NO `Serialize` / `Deserialize` derive (it used to be
/// `serde_repr`'s, which wrote the ordinal): a `Lang` crosses a wire only
/// through [`lang_wire`], by name.  See the module doc.
#[derive(Debug, Default, Copy, Clone, FromPrimitive, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "schemars", derive(schemars::JsonSchema))]
#[repr(u8)]
pub enum Lang {
    /// The sentinel, at ordinal 0 (LRS-4) so that a zero-initialised or
    /// defaulted `Lang` is "unknown" and not a plausible language.
    #[default]
    Unknown = 0,
    C,
    Cpp,
    Rust,
    Nim,
    Go,
    Pascal,
    Fortran,
    D,
    Crystal,
    Lean,
    Julia,
    Ada,
    /// Ruby, recorded by `codetracer-ruby-recorder`.  The `Db` suffix is
    /// historical: it was the pair partner of the retired rr backend `Ruby`,
    /// deleted in LRS-4.
    RubyDb,
    Javascript,
    Lua,
    Asm,
    Noir,
    /// Python, recorded by `codetracer-python-recorder`; `Db` suffix as for
    /// `RubyDb` (the retired `Python` was deleted in LRS-4).
    PythonDb,
    // The shell and blockchain-VM languages, whose traces are materialized
    // and read by the db-backend rather than stepped through a native frame.
    // They are NOT absent from the Nim frontend enum — `src/common/common_lang.nim`
    // declares all 35 of these variants at the same ordinals, and
    // `src/tests/cli/lang_enum_contract_test.nim` asserts the two lists are
    // the same length, name for name.
    //
    // Shell languages, kept here for expr_loader tree-sitter support.
    Bash,
    Zsh,
    // EVM/Solidity support.
    Solidity,
    // Blockchain VM languages.
    /// Miden MASM assembly (Polygon Miden zkVM)
    Masm,
    /// FuelVM Sway language
    Sway,
    /// Sui/Aptos Move language
    Move,
    /// Cairo/StarkNet (zero-knowledge smart contracts)
    Cairo,
    /// Circom (zero-knowledge circuits)
    Circom,
    /// Leo/Aleo (zero-knowledge smart contracts)
    Leo,
    /// Tolk/TON (TON smart contracts)
    Tolk,
    /// Aiken/Cardano (Cardano validators)
    Aiken,
    /// Cadence/Flow (Flow smart contracts)
    Cadence,
    /// Elixir/BEAM materialized traces
    Elixir,
    /// Erlang/BEAM materialized traces
    Erlang,
    /// PHP materialized traces
    Php,
    // GDScript (Godot), last.  Materialized trace produced by the patched
    // Godot engine recorder (GDScript-Recorder.md); also the VM sub-trace in a
    // mixed native<->GDScript recording. Kept in sync with the Nim
    // src/common/common_lang.nim enum (lang_enum_contract_test asserts it).
    GDScript,
}

impl Lang {
    /// The ordinal-independent spelling of this language on the native replay
    /// worker socket.
    ///
    /// The worker socket used to carry `Lang` as a `serde_repr` integer, which
    /// made the two repositories' enum *layouts* a wire contract: inserting a
    /// variant in either enum silently re-pointed every ordinal above it.  The
    /// two enums have in fact already diverged (`codetracer-native-backend`
    /// has `Small`, `Odin`, `V` and `CSharp`; this one has the whole
    /// blockchain block), so the integers were only accidentally agreeing for
    /// the low ordinals.
    ///
    /// This match is deliberately exhaustive with no catch-all arm: adding a
    /// `Lang` variant must not compile until it has been given a name.  The
    /// spellings match `codetracer-native-backend`'s `Lang::from_str` /
    /// `recognize::lang_wire_name` for every language both sides know, which
    /// `wire_names_match_native_backend_spellings` in
    /// `src/db-backend/src/lang.rs` pins down.
    pub fn wire_name(self) -> &'static str {
        match self {
            Lang::Unknown => "unknown",
            Lang::C => "c",
            Lang::Cpp => "cpp",
            Lang::Rust => "rust",
            Lang::Nim => "nim",
            Lang::Go => "go",
            Lang::Pascal => "pascal",
            Lang::Fortran => "fortran",
            Lang::D => "d",
            Lang::Crystal => "crystal",
            Lang::Lean => "lean",
            Lang::Julia => "julia",
            Lang::Ada => "ada",
            Lang::RubyDb => "rubydb",
            Lang::Javascript => "javascript",
            Lang::Lua => "lua",
            Lang::Asm => "asm",
            Lang::Noir => "noir",
            Lang::PythonDb => "pythondb",
            Lang::Bash => "bash",
            Lang::Zsh => "zsh",
            Lang::Solidity => "solidity",
            Lang::Masm => "masm",
            Lang::Sway => "sway",
            Lang::Move => "move",
            Lang::Cairo => "cairo",
            Lang::Circom => "circom",
            Lang::Leo => "leo",
            Lang::Tolk => "tolk",
            Lang::Aiken => "aiken",
            Lang::Cadence => "cadence",
            Lang::Elixir => "elixir",
            Lang::Erlang => "erlang",
            Lang::Php => "php",
            Lang::GDScript => "gdscript",
        }
    }

    /// Every `Lang` variant, in declaration order.
    ///
    /// Used by the wire-name round-trip tests; kept next to [`Lang::wire_name`]
    /// so the two are updated together.
    pub const ALL: [Lang; 35] = [
        Lang::Unknown,
        Lang::C,
        Lang::Cpp,
        Lang::Rust,
        Lang::Nim,
        Lang::Go,
        Lang::Pascal,
        Lang::Fortran,
        Lang::D,
        Lang::Crystal,
        Lang::Lean,
        Lang::Julia,
        Lang::Ada,
        Lang::RubyDb,
        Lang::Javascript,
        Lang::Lua,
        Lang::Asm,
        Lang::Noir,
        Lang::PythonDb,
        Lang::Bash,
        Lang::Zsh,
        Lang::Solidity,
        Lang::Masm,
        Lang::Sway,
        Lang::Move,
        Lang::Cairo,
        Lang::Circom,
        Lang::Leo,
        Lang::Tolk,
        Lang::Aiken,
        Lang::Cadence,
        Lang::Elixir,
        Lang::Erlang,
        Lang::Php,
        Lang::GDScript,
    ];

    /// Parse a [`Lang::wire_name`] back.  `None` for anything else — callers
    /// must report the unrecognised spelling rather than substitute a default.
    pub fn from_wire_name(name: &str) -> Option<Lang> {
        Lang::ALL.into_iter().find(|lang| lang.wire_name() == name)
    }
}

/// `#[serde(with = "...")]` adapter that carries a [`Lang`] as its
/// [`Lang::wire_name`] instead of its ordinal.
///
/// Applied to the native replay worker socket
/// (`db_backend::query::ReplayQuery`) and, since LRS-1, to the
/// `ct/load-locals` DAP request (`db_backend::task::CtLoadLocalsArguments`),
/// whose Nim sender writes the same spelling via `langWireName`.  It is the
/// ONLY serde path a `Lang` has: the enum derives no `Serialize` /
/// `Deserialize` of its own, so a field that forgets this adapter fails to
/// compile rather than silently writing the ordinal.
///
/// With the adapter, a `Lang` field serialises as its name:
///
/// ```
/// #[derive(serde::Serialize, serde::Deserialize, PartialEq, Debug)]
/// struct Args {
///     #[serde(with = "ct_lang::lang_wire")]
///     lang: ct_lang::Lang,
/// }
/// let json = serde_json::to_string(&Args { lang: ct_lang::Lang::Leo }).unwrap();
/// assert_eq!(json, r#"{"lang":"leo"}"#);
/// assert_eq!(serde_json::from_str::<Args>(&json).unwrap(), Args { lang: ct_lang::Lang::Leo });
/// assert!(serde_json::from_str::<Args>(r#"{"lang":32}"#).is_err(), "an ordinal is refused");
/// ```
///
/// Without it, the struct does not compile — there is no `Serialize` for
/// `Lang` to fall back on, so the ordinal cannot leak onto a wire by
/// omission (this is the mutation "re-add a bare `lang: Lang` field"):
///
/// ```compile_fail
/// #[derive(serde::Serialize)]
/// struct Args {
///     lang: ct_lang::Lang,
/// }
/// ```
///
/// ```compile_fail
/// #[derive(serde::Deserialize)]
/// struct Args {
///     lang: ct_lang::Lang,
/// }
/// ```
pub mod lang_wire {
    use super::Lang;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(lang: &Lang, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(lang.wire_name())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Lang, D::Error> {
        let name = String::deserialize(deserializer)?;
        Lang::from_wire_name(&name).ok_or_else(|| {
            serde::de::Error::custom(format!(
                "unknown language name `{name}` on the wire: expected a `Lang::wire_name` spelling such as `c` or `pythondb`, never an ordinal"
            ))
        })
    }

    /// The same adapter for an optional field.
    pub mod option {
        use super::super::Lang;
        use serde::{Deserialize, Deserializer, Serializer};

        pub fn serialize<S: Serializer>(
            lang: &Option<Lang>,
            serializer: S,
        ) -> Result<S::Ok, S::Error> {
            match lang {
                Some(lang) => serializer.serialize_some(lang.wire_name()),
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Option<Lang>, D::Error> {
            let name = Option::<String>::deserialize(deserializer)?;
            match name {
                None => Ok(None),
                Some(name) => Lang::from_wire_name(&name).map(Some).ok_or_else(|| {
                    serde::de::Error::custom(format!(
                        "unknown language name `{name}` on the wire: expected a `Lang::wire_name` spelling such as `c` or `pythondb`, never an ordinal"
                    ))
                }),
            }
        }
    }
}


// ---------------------------------------------------------------------------
// The four axes.  Names only; no ordinal ever crosses a boundary.
// ---------------------------------------------------------------------------

macro_rules! axis_enum {
    (
        $(#[$meta:meta])*
        $name:ident, $all:ident, $unknown:ident {
            $( $variant:ident => $token:literal, )+
        }
    ) => {
        $(#[$meta])*
        #[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
        pub enum $name {
            $( $variant, )+
        }

        impl $name {
            /// Every variant, in declaration order — the same order as the Nim
            /// enum, which the contract test pins.
            pub const $all: &'static [$name] = &[ $( $name::$variant, )+ ];

            /// The wire spelling: the Nim `token(v)` of the same member.
            /// Exhaustive with no catch-all, so a new variant does not compile
            /// until it has been named.
            pub fn wire_name(self) -> &'static str {
                match self {
                    $( $name::$variant => $token, )+
                }
            }

            /// Parse a [`Self::wire_name`] back.  `None` for anything else —
            /// callers must report the unrecognised spelling rather than
            /// substitute the sentinel.
            pub fn from_wire_name(name: &str) -> Option<$name> {
                Self::$all.iter().copied().find(|v| v.wire_name() == name)
            }
        }

        impl Default for $name {
            /// The sentinel is ordinal 0 on every axis, so a zero-initialised
            /// value says "not determined" rather than naming a real member.
            fn default() -> Self {
                $name::$unknown
            }
        }
    };
}

axis_enum! {
    /// What notation a **file** is written in.  Per file.
    /// Mirrors `SourceLanguage` in `src/common/target_axes.nim`.
    SourceLanguage, ALL, Unknown {
        Unknown => "unknown",
        C => "c",
        Cpp => "cpp",
        Rust => "rust",
        Nim => "nim",
        Go => "go",
        Pascal => "pascal",
        Fortran => "fortran",
        D => "d",
        Crystal => "crystal",
        Lean => "lean",
        Julia => "julia",
        Ada => "ada",
        Python => "python",
        Ruby => "ruby",
        JavaScript => "javascript",
        Lua => "lua",
        Php => "php",
        Bash => "bash",
        Zsh => "zsh",
        Elixir => "elixir",
        Erlang => "erlang",
        Solidity => "solidity",
        Move => "move",
        Sway => "sway",
        Cairo => "cairo",
        Circom => "circom",
        Leo => "leo",
        Tolk => "tolk",
        Aiken => "aiken",
        Cadence => "cadence",
        Noir => "noir",
        Asm => "asm",
        // Deliberately NOT "masm": that spelling is reserved for a Microsoft
        // MASM dialect, as are "gas" and "nasm".  See the Nim side.
        MidenAsm => "midenasm",
        GdScript => "gdscript",
    }
}

axis_enum! {
    /// What the machine that runs the artefact executes.  Per artefact.
    /// Mirrors `TargetIsa` in `src/common/target_axes.nim`.
    TargetIsa, ALL, Unknown {
        Unknown => "unknown",
        Native => "native",
        Interpreted => "interpreted",
        NimVm => "nimvm",
        Wasm => "wasm",
        Evm => "evm",
        MidenVm => "midenvm",
        MoveVm => "movevm",
        FuelVm => "fuelvm",
        PolkaVm => "polkavm",
        CairoVm => "cairovm",
        AleoVm => "aleovm",
        TonVm => "tonvm",
        Plutus => "plutus",
        FlowVm => "flowvm",
        SolanaSbf => "solanasbf",
        Acir => "acir",
        CircomWitness => "circomwitness",
        Beam => "beam",
        GdScriptVm => "gdscriptvm",
    }
}

axis_enum! {
    /// What turned the source into the artefact.  Per artefact.
    /// Mirrors `Toolchain` in `src/common/target_axes.nim`.
    Toolchain, ALL, Unknown {
        Unknown => "unknown",
        None => "none",
        Gcc => "gcc",
        Clang => "clang",
        Msvc => "msvc",
        Rustc => "rustc",
        Cargo => "cargo",
        GoBuild => "gobuild",
        NimC => "nimc",
        NimScriptVm => "nimscriptvm",
        Fpc => "fpc",
        CrystalCompiler => "crystal",
        Gfortran => "gfortran",
        Ldc2 => "ldc2",
        Gnat => "gnat",
        Lake => "lake",
        Shards => "shards",
        Nargo => "nargo",
        Scarb => "scarb",
        Forc => "forc",
        Foundry => "foundry",
        AikenCli => "aiken",
        MoveCli => "move",
        LeoCli => "leo",
    }
}

axis_enum! {
    /// How CodeTracer observed the run.  Per recording.
    /// Mirrors `RecordingApproach` in `src/common/target_axes.nim`.
    RecordingApproach, ALL, Unknown {
        Unknown => "unknown",
        Mcr => "mcr",
        Rr => "rr",
        Ttd => "ttd",
        InstrumentedRuntime => "instrumented",
        VmEmulation => "vm",
    }
}

#[cfg(test)]
mod axis_tests {
    use super::*;

    fn round_trips<T: Copy + PartialEq + std::fmt::Debug>(
        all: &[T],
        wire: impl Fn(T) -> &'static str,
        parse: impl Fn(&str) -> Option<T>,
    ) {
        let mut seen = std::collections::HashSet::new();
        for &v in all {
            let name = wire(v);
            assert!(!name.is_empty());
            assert_eq!(name, name.to_ascii_lowercase());
            assert!(!name.contains('-'), "{name} contains the storage separator");
            assert!(seen.insert(name), "{name} is spelled by two variants");
            assert_eq!(parse(name), Some(v));
        }
        assert_eq!(parse("no-such-token"), None);
    }

    #[test]
    fn every_axis_round_trips_and_is_hyphen_free() {
        round_trips(SourceLanguage::ALL, SourceLanguage::wire_name, SourceLanguage::from_wire_name);
        round_trips(TargetIsa::ALL, TargetIsa::wire_name, TargetIsa::from_wire_name);
        round_trips(Toolchain::ALL, Toolchain::wire_name, Toolchain::from_wire_name);
        round_trips(RecordingApproach::ALL, RecordingApproach::wire_name, RecordingApproach::from_wire_name);
    }

    #[test]
    fn the_sentinel_is_first_and_spelled_unknown_on_every_axis() {
        assert_eq!(SourceLanguage::ALL[0], SourceLanguage::Unknown);
        assert_eq!(TargetIsa::ALL[0], TargetIsa::Unknown);
        assert_eq!(Toolchain::ALL[0], Toolchain::Unknown);
        assert_eq!(RecordingApproach::ALL[0], RecordingApproach::Unknown);
        assert_eq!(SourceLanguage::default().wire_name(), "unknown");
        assert_eq!(TargetIsa::default().wire_name(), "unknown");
        assert_eq!(Toolchain::default().wire_name(), "unknown");
        assert_eq!(RecordingApproach::default().wire_name(), "unknown");
    }

    #[test]
    fn the_reserved_assembler_names_are_spent_by_nothing() {
        for reserved in ["masm", "gas", "nasm"] {
            assert_eq!(SourceLanguage::from_wire_name(reserved), None);
            assert_eq!(TargetIsa::from_wire_name(reserved), None);
            assert_eq!(Toolchain::from_wire_name(reserved), None);
            assert_eq!(RecordingApproach::from_wire_name(reserved), None);
        }
        assert_eq!(SourceLanguage::MidenAsm.wire_name(), "midenasm");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The three variants `src/tui/src/lang.rs` was missing before it was
    /// deleted.  A truncated copy of this enum answered `None` for all three
    /// and the TUI's `.expect("expected valid lang")` turned that into a
    /// panic.  The ordinals were 37, 38, 39 when the persisted column still
    /// held integers; the column holds NAMES since trace_index schema
    /// version 1, so the assertion that survives is that all three decode
    /// as the last three before `GDScript`, whatever their number.
    #[test]
    fn the_three_variants_the_tui_copy_was_missing_decode() {
        use num_traits::FromPrimitive;
        let php = Lang::Php as u8;
        assert_eq!(<Lang as FromPrimitive>::from_u8(php - 2), Some(Lang::Elixir));
        assert_eq!(<Lang as FromPrimitive>::from_u8(php - 1), Some(Lang::Erlang));
        assert_eq!(<Lang as FromPrimitive>::from_u8(php), Some(Lang::Php));
        assert_eq!(<Lang as FromPrimitive>::from_u8(php + 1), Some(Lang::GDScript));
    }

    /// The layout LRS-4 chose, pinned on this side too (the Nim contract test
    /// pins the two enums against each other; this pins the DECISION, so a
    /// lockstep move of `Unknown` off zero is a red test here as well).
    #[test]
    fn the_sentinel_is_ordinal_zero_and_the_default() {
        assert_eq!(Lang::Unknown as u8, 0);
        assert_eq!(Lang::default(), Lang::Unknown);
        assert_eq!(Lang::ALL[0], Lang::Unknown);
        assert_eq!(Lang::C as u8, 1);
        // 35 since LRS-5's second deletion round removed `RustWasm`,
        // `CppWasm`, `PolkaVM` and `Solana` from the 39 LRS-4 left (41 = 40
        // plus the `GDScript` append, minus `Python` and `Ruby`).  This
        // length read 40 for a while after that append and the failure went
        // unnoticed, which is the drift the Nim contract test exists to catch
        // on the other side.
        assert_eq!(Lang::ALL.len(), 35);
        assert_eq!(Lang::GDScript as u8, 34);
    }

    /// The retired members' wire names are gone with them, and nothing else
    /// took the spellings: a `python` or `ruby` on the worker socket is a
    /// refused request, not a silently re-pointed one.
    #[test]
    fn the_retired_wire_names_resolve_to_nothing() {
        assert_eq!(Lang::from_wire_name("python"), None);
        assert_eq!(Lang::from_wire_name("ruby"), None);
        assert_eq!(Lang::from_wire_name("pythondb"), Some(Lang::PythonDb));
        assert_eq!(Lang::from_wire_name("rubydb"), Some(Lang::RubyDb));
        // The same, for LRS-5's second deletion round.  `rustwasm` and
        // `cppwasm` are now `codetracer-native-backend`-only spellings (its
        // own, deliberately different `Lang` still has both variants and
        // still parses them); this core emits neither, and a `rustwasm` on
        // the worker socket is refused rather than re-pointed at `Rust` --
        // which would be the ISA silently absorbed into the language again.
        assert_eq!(Lang::from_wire_name("rustwasm"), None);
        assert_eq!(Lang::from_wire_name("cppwasm"), None);
        assert_eq!(Lang::from_wire_name("polkavm"), None);
        assert_eq!(Lang::from_wire_name("solana"), None);
        assert_eq!(Lang::from_wire_name("rust"), Some(Lang::Rust));
        assert_eq!(Lang::from_wire_name("cpp"), Some(Lang::Cpp));
    }

    /// `Lang::ALL` must be exactly the enum, in order, with nothing past the
    /// end.  `wire_name` is exhaustive so a new variant breaks the build
    /// there; this stops `ALL` from falling behind silently.
    #[test]
    fn all_is_the_enum_in_ordinal_order() {
        use num_traits::FromPrimitive;
        for (index, lang) in Lang::ALL.iter().enumerate() {
            assert_eq!(
                <Lang as FromPrimitive>::from_u8(index as u8),
                Some(*lang),
                "Lang::ALL[{index}] is not the variant with ordinal {index}"
            );
        }
        assert_eq!(
            <Lang as FromPrimitive>::from_u8(Lang::ALL.len() as u8),
            None
        );
    }
}
