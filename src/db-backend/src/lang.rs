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
        _ => Lang::Unknown,
    }
}
