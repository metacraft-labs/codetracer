use num_derive::FromPrimitive;
use serde_repr::*;

#[derive(
    Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq,
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
    PythonDb,
    Unknown,
    Bash,
    Zsh,
    Solidity,
    Masm,
    Sway,
    Move,
    PolkaVM,
    Cairo,
    Circom,
    Leo,
    Tolk,
    Aiken,
    Cadence,
    Solana,
}
