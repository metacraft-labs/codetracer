use serde::{Deserialize, Serialize};
use serde_repr::{Deserialize_repr, Serialize_repr};

/// TypeKind enum matching codetracer_trace_types (repr(u8)).
#[derive(Debug, Default, Copy, Clone, PartialEq, Serialize_repr, Deserialize_repr)]
#[repr(u8)]
pub enum TypeKind {
    #[default]
    Seq,
    Set,
    HashSet,
    OrderedSet,
    Array,
    Varargs,
    Struct,
    Int,
    Float,
    String,
    CString,
    Char,
    Bool,
    Literal,
    Ref,
    Recursion,
    Raw,
    Enum,
    Enum16,
    Enum32,
    C,
    TableKind,
    Union,
    Pointer,
    Error,
    FunctionKind,
    TypeValue,
    Tuple,
    Variant,
    Html,
    None,
    NonExpanded,
    Any,
    Slice,
}

/// Value type matching db-backend's value::Value.
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
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
    pub address: String,
    pub ref_value: Option<Box<Value>>,
    pub is_mutable: bool,
    pub active_variant: String,
    pub active_variant_value: Option<Box<Value>>,
    pub typ: Type,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[serde(default)]
pub struct Type {
    pub kind: TypeKind,
    pub lang_type: String,
    pub c_type: String,
    pub labels: Vec<String>,
    pub element_type: Option<Box<Type>>,
    pub member_types: Vec<Type>,
}

impl Value {
    /// Returns a human-readable text representation of this value.
    pub fn text_repr(&self) -> String {
        match self.kind {
            TypeKind::Int => self.i.clone(),
            TypeKind::Float => self.f.clone(),
            TypeKind::String => format!("\"{}\"", self.text),
            TypeKind::CString => format!("\"{}\"", self.c_text),
            TypeKind::Char => format!("'{}'", self.c),
            TypeKind::Bool => if self.b { "true" } else { "false" }.to_string(),
            TypeKind::Raw => self.r.clone(),
            TypeKind::Error => format!("<error: {}>", self.msg),
            TypeKind::None => "nil".to_string(),
            _ => format!("{:?}", self),
        }
    }
}

/// Field0/Field1 tuple matching db-backend's StringAndValueTuple.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct StringAndValueTuple {
    pub field0: String,
    pub field1: Value,
}
