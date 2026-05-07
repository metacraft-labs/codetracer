use std::ffi::OsStr;
use std::path::Path;

use num_derive::FromPrimitive;
use serde_repr::*;

use crate::task::TraceKind;

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
    schemars::JsonSchema,
)]
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
    Small,
    PythonDb,
    Unknown,
    // Shell languages: not in the Nim frontend enum, kept here for
    // expr_loader tree-sitter support.  Ordinals 24+ are internal only.
    Bash,
    Zsh,
    // EVM/Solidity support (ordinal 26, internal only — not in the Nim frontend enum).
    Solidity,
    // Blockchain VM languages (ordinals 27+, internal only — not in the Nim frontend enum).
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
}

pub fn lang_from_context(path: &Path, trace_kind: TraceKind) -> Lang {
    let extension = path.extension().unwrap_or(OsStr::new("")).to_str().unwrap_or("");
    // for now important mostly for system langs/rr support
    // but still good to add all supported langs: TODO
    match extension {
        "rs" => {
            if trace_kind == TraceKind::Materialized {
                Lang::RustWasm
            } else {
                Lang::Rust
            }
        }
        "c" => Lang::C,
        "cpp" => Lang::Cpp,
        "pas" => Lang::Pascal,
        "nim" => Lang::Nim,
        "d" => Lang::D,
        "go" => Lang::Go,
        "f90" | "f95" | "f03" | "f08" | "f" | "for" => Lang::Fortran,
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
        "polkavm" => Lang::PolkaVM,
        "cairo" => Lang::Cairo,
        "circom" => Lang::Circom,
        "leo" => Lang::Leo,
        "tolk" => Lang::Tolk,
        "ak" => Lang::Aiken,
        "cdc" => Lang::Cadence,
        "ex" | "exs" => Lang::Elixir,
        "erl" | "hrl" => Lang::Erlang,
        _ => Lang::Unknown,
    }
}
