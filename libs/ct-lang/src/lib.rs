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
//! # The ordinals are a wire and storage contract — do not reorder
//!
//! The integer value of a `Lang` is carried by:
//!
//! * the `lang` column of the persisted `~/.local/share/codetracer/trace_index.db`
//!   `recordings` table, written by Nim (`src/common/trace_index.nim`);
//! * the `ct/load-locals` DAP request, whose `lang` field the Nim frontend
//!   sends as `ord(Lang)` and this side reads with `serde_repr`;
//! * `ct-dap-client`'s tracepoint requests.
//!
//! It is **not** carried to `codetracer-native-backend`.  That repository has
//! its own, deliberately different `Lang` (the languages the native backend
//! *supports*, with a `Small` variant at ordinal 21), and the replay worker
//! socket between the two crates carries language *names* — see
//! [`Lang::wire_name`].

use num_derive::FromPrimitive;
use serde_repr::*;

/// Identifies a programming language implementation.
///
/// Ordinals MUST match the Nim `Lang` enum in `src/common/common_lang.nim`.
/// `src/tests/cli/lang_enum_contract_test.nim` asserts that mechanically, name
/// for name and ordinal for ordinal, and fails rather than silently comparing
/// nothing if it cannot locate either list.
#[derive(
    Debug,
    Default,
    Copy,
    Clone,
    FromPrimitive,
    Serialize_repr,
    Deserialize_repr,
    PartialEq,
    Eq,
    Hash,
)]
#[cfg_attr(feature = "schemars", derive(schemars::JsonSchema))]
#[repr(u8)]
pub enum Lang {
    #[default]
    C = 0,
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
    Python,
    Ruby,
    RubyDb,
    Javascript,
    Lua,
    Asm,
    Noir,
    RustWasm,
    CppWasm,
    PythonDb,
    Unknown,
    // Ordinals 23+ have no `ct/load-locals` traffic: they are the shell and
    // blockchain-VM languages, whose traces are materialized and read by the
    // db-backend rather than stepped through a native frame.  They are NOT
    // absent from the Nim frontend enum — `src/common/common_lang.nim`
    // declares all 40 of these variants at the same ordinals, and
    // `src/tests/cli/lang_enum_contract_test.nim` asserts the two lists are
    // the same length, name for name.
    //
    // Shell languages, kept here for expr_loader tree-sitter support.
    Bash,
    Zsh,
    // EVM/Solidity support (ordinal 25).
    Solidity,
    // Blockchain VM languages (ordinals 26+).
    /// Miden MASM assembly (Polygon Miden zkVM)
    Masm,
    /// FuelVM Sway language
    Sway,
    /// Sui/Aptos Move language
    Move,
    /// PolkaVM RISC-V (Polkadot smart contracts)
    PolkaVM,
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
    /// Solana (Solana programs/smart contracts)
    Solana,
    /// Elixir/BEAM materialized traces
    Elixir,
    /// Erlang/BEAM materialized traces
    Erlang,
    /// PHP materialized traces
    Php,
    // GDScript (Godot). Ordinal 40, after Php. Materialized trace produced by the
    // patched Godot engine recorder (GDScript-Recorder.md); also the VM sub-trace
    // in a mixed native<->GDScript recording. Kept in sync with the Nim
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
            Lang::Python => "python",
            Lang::Ruby => "ruby",
            Lang::RubyDb => "rubydb",
            Lang::Javascript => "javascript",
            Lang::Lua => "lua",
            Lang::Asm => "asm",
            Lang::Noir => "noir",
            Lang::RustWasm => "rustwasm",
            Lang::CppWasm => "cppwasm",
            Lang::PythonDb => "pythondb",
            Lang::Unknown => "unknown",
            Lang::Bash => "bash",
            Lang::Zsh => "zsh",
            Lang::Solidity => "solidity",
            Lang::Masm => "masm",
            Lang::Sway => "sway",
            Lang::Move => "move",
            Lang::PolkaVM => "polkavm",
            Lang::Cairo => "cairo",
            Lang::Circom => "circom",
            Lang::Leo => "leo",
            Lang::Tolk => "tolk",
            Lang::Aiken => "aiken",
            Lang::Cadence => "cadence",
            Lang::Solana => "solana",
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
    pub const ALL: [Lang; 41] = [
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
        Lang::Python,
        Lang::Ruby,
        Lang::RubyDb,
        Lang::Javascript,
        Lang::Lua,
        Lang::Asm,
        Lang::Noir,
        Lang::RustWasm,
        Lang::CppWasm,
        Lang::PythonDb,
        Lang::Unknown,
        Lang::Bash,
        Lang::Zsh,
        Lang::Solidity,
        Lang::Masm,
        Lang::Sway,
        Lang::Move,
        Lang::PolkaVM,
        Lang::Cairo,
        Lang::Circom,
        Lang::Leo,
        Lang::Tolk,
        Lang::Aiken,
        Lang::Cadence,
        Lang::Solana,
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
/// Applied only to the native replay worker socket
/// (`db_backend::query::ReplayQuery`).  The DAP-facing structs keep
/// `serde_repr` because the Nim frontend still sends `lang` as an integer
/// there.
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
                "unknown language name `{name}` on the replay worker wire"
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
                        "unknown language name `{name}` on the replay worker wire"
                    ))
                }),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The three variants `src/tui/src/lang.rs` was missing before it was
    /// deleted, at the ordinals the persisted `trace_index.db.lang` column
    /// already contains.  A truncated copy of this enum answered `None` for
    /// all three, and the TUI's `.expect("expected valid lang")` turned that
    /// into a panic.
    #[test]
    fn the_three_ordinals_the_tui_copy_was_missing_decode() {
        use num_traits::FromPrimitive;
        assert_eq!(<Lang as FromPrimitive>::from_i64(37), Some(Lang::Elixir));
        assert_eq!(<Lang as FromPrimitive>::from_i64(38), Some(Lang::Erlang));
        assert_eq!(<Lang as FromPrimitive>::from_i64(39), Some(Lang::Php));
    }

    /// The ordinals nothing may move without a data migration of the
    /// `recordings.lang` column.
    #[test]
    fn the_pinned_ordinals_are_where_the_persisted_column_expects_them() {
        assert_eq!(Lang::C as u8, 0);
        assert_eq!(Lang::PythonDb as u8, 21);
        assert_eq!(Lang::Unknown as u8, 22);
        assert_eq!(Lang::ALL.len(), 40);
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
