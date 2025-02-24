use num_derive::FromPrimitive;
use serde::{Deserialize, Serialize};
use serde_repr::*;

#[derive(
    Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq,
)]
#[repr(u8)]
pub enum TypeKind {
    //   seq, HashSet, OrderedSet, set and array in Nim
    //   vector and array in C++
    //    list in Python
    //   Array in Ruby
    #[default]
    Seq,
    Set,
    HashSet,
    OrderedSet,
    Array,
    Varargs,

    //   object in Nim
    //   struct, class in C++
    //   object in Python
    //   object in Ruby
    Instance,

    Int,
    Float,
    String,
    CString,
    Char,
    Bool,

    // literals in each of them
    Literal,

    //   # ref in Nim
    //   # ? C++
    //   # not used for Python, Ruby
    Ref,

    // used to signify self-referencing stuff
    Recursion,

    // fallback for unknown values
    Raw,

    // # enum in Nim
    // # enum in C++
    // # not used for Python, Ruby
    Enum,
    Enum16,
    Enum32,

    // # fallback for c values in Nim, Ruby, Python
    // # not used for C++
    C,

    // # Table in Nim
    // # std::map in C++
    // # dict in Python
    // # Hash in Ruby
    TableKind,

    // # variant objects in Nim
    // # union in C++
    // # not used in Python, Ruby
    Union,

    // # pointer in C/C++: still can have a referenced type
    // # pointer in Nim
    // # not used in Python, Ruby
    // # TODO: do we need both `Ref` and `Pointer`?
    Pointer,

    // # errors
    Error,

    // # a function in Nim, Ruby, Python
    // # a function pointer in C++
    FunctionKind,

    TypeValue,

    // # a tuple in Nim, Python
    Tuple,

    // # an enum in Rust
    Variant,

    // # visual value produced debugHTML
    Html,

    None,
    NonExpanded,
    Any,
    Slice,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[serde(default)]
pub struct Value {
    pub kind: TypeKind,
    pub i: String,
    pub f: String,
    pub b: bool,
    pub c: String,
    pub text: String,
    pub c_text: String,
    pub elements: Vec<Value>,
    pub msg: String,
    pub r: String,
    pub typ: Type,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[serde(default)]
pub struct Type {
    pub kind: TypeKind,
    pub lang_type: String,
    pub c_type: String,
    pub elements: Vec<Type>,
}

impl Value {
    pub fn new(kind: TypeKind, typ: Type) -> Value {
        Value {
            kind,
            typ,
            ..Default::default()
        }
    }
}

impl Type {
    pub fn new(kind: TypeKind, lang_type: &str) -> Type {
        Type {
            kind,
            lang_type: lang_type.to_string(),
            c_type: lang_type.to_string(),
            ..Default::default()
        }
    }
}

#[allow(dead_code)]
pub fn text_repr(value: &Value) -> String {
    match value.kind {
        TypeKind::Int => value.i.to_string(),
        TypeKind::Float => value.f.to_string(),
        TypeKind::String => {
            format!("\"{}\"", value.text)
        }
        TypeKind::CString => {
            format!("\"{}\"", value.c_text)
        }
        TypeKind::Char => {
            format!("'{}'", value.c)
        }
        TypeKind::Bool => {
            if value.b {
                "true".to_string()
            } else {
                "false".to_string()
            }
        }
        TypeKind::Raw => value.r.to_string(),
        TypeKind::Error => {
            format!("<error: {}>", value.msg)
        }
        _ => {
            // TODO
            format!("{:?}", value)
        }
    }
}

// TODO?

// #[derive(Debug, Default, Clone, Serialize, Deserialize)]
// #[serde(tag = "kind")]
// pub enum Value {
//   Int { i: i64 },
//   Float(f64),
//   Bool(bool),
//   String(std::string::String),
//   CString(std::string::String),
//   Char(char),
//   Error(std::string::String),
//   #[default]
//   Other
// }
