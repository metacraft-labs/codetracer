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

pub fn lang_from_context(path: &Path, trace_kind: TraceKind) -> Lang {
    let extension = path.extension().unwrap_or(OsStr::new("")).to_str().unwrap_or("");
    // for now important mostly for system langs/rr support
    // but still good to add all supported langs: TODO
    match extension {
        "rs" => {
            if trace_kind == TraceKind::DB {
                Lang::RustWasm
            } else {
                Lang::Rust
            }
        }
        "c" => Lang::C,
        "cpp" => Lang::Cpp,
        "pas" => Lang::Pascal,
        "nim" => Lang::Nim,
        "d" => Lang::C, // TODO
        "go" => Lang::Go,
        _ => Lang::Unknown,
    }
}
