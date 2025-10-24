use num_derive::FromPrimitive;
use serde_repr::*;

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
}
