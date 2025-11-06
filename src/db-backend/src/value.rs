use num_bigint::BigInt;
use runtime_tracing::{Place, TypeKind, TypeRecord, TypeSpecificInfo};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
// TODO? from types if needed use runtime_tracing::base64;

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, JsonSchema)]
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
    pub typ: Type,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[serde(default)]
pub struct Type {
    pub kind: TypeKind,
    pub lang_type: String,
    pub c_type: String,
    // pub elements: Vec<Type>,
    pub labels: Vec<String>,
    pub element_type: Option<Box<Type>>,
    pub member_types: Vec<Type>,
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

impl Value {
    fn list_repr(&self) -> String {
        let mut res: String = Default::default();
        for (i, element) in self.elements.iter().enumerate() {
            res += &element.text_repr();
            if i < self.elements.len() - 1 {
                res += ", "
            }
        }
        res
    }

    pub fn text_repr(&self) -> String {
        match self.kind {
            TypeKind::Int => self.i.to_string(),
            TypeKind::Float => self.f.to_string(),
            TypeKind::String => {
                format!("\"{}\"", self.text)
            }
            TypeKind::CString => {
                format!("\"{}\"", self.c_text)
            }
            TypeKind::Char => {
                format!("'{}'", self.c)
            }
            TypeKind::Bool => {
                if self.b {
                    "true".to_string()
                } else {
                    "false".to_string()
                }
            }
            TypeKind::Seq => {
                let mut res: String = "[".to_string();
                res += &self.list_repr();
                res += "]";
                res.to_string()
            }
            TypeKind::Struct => {
                let mut res: String = "(".to_string();
                res += &self.list_repr();
                res += ")";
                res.to_string()
            }
            TypeKind::Raw => self.r.to_string(),
            TypeKind::Error => {
                format!("<error: {}>", self.msg)
            }
            TypeKind::None => "nil".to_string(),
            _ => {
                // TODO
                format!("{:?}", self)
            }
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum ValueRecordWithType {
    Int {
        i: i64,
        typ: TypeRecord,
    },
    Float {
        f: f64,
        typ: TypeRecord,
    },
    Bool {
        b: bool,
        typ: TypeRecord,
    },
    String {
        text: String,
        typ: TypeRecord,
    },
    Sequence {
        elements: Vec<ValueRecordWithType>,
        is_slice: bool,
        typ: TypeRecord,
    },
    Tuple {
        elements: Vec<ValueRecordWithType>,
        typ: TypeRecord,
    },
    Struct {
        field_values: Vec<ValueRecordWithType>,
        typ: TypeRecord, // (if TypeId: must point to), must be Type with STRUCT kind and TypeSpecificInfo::Struct
    },
    Variant {
        discriminator: String,              // TODO: eventually a more specific kind of value/type
        contents: Box<ValueRecordWithType>, // usually a Struct or a Tuple
        typ: TypeRecord,
    },
    // TODO: eventually add more pointer-like variants
    // or more fields (address?)
    Reference {
        dereferenced: Box<ValueRecordWithType>,
        address: u64,
        mutable: bool,
        typ: TypeRecord,
    },
    Raw {
        r: String,
        typ: TypeRecord,
    },
    Error {
        msg: String,
        typ: TypeRecord,
    },
    None {
        typ: TypeRecord,
    },
    Cell {
        place: Place,
    },
    BigInt {
        // TODO #[serde(with = "base64")]
        b: Vec<u8>, // Base64 encoded bytes of a big-endian unsigned integer
        negative: bool,
        typ: TypeRecord,
    },
}

pub fn to_ct_value(v: &ValueRecordWithType) -> Value {
    match v {
        ValueRecordWithType::Int { i, typ } => {
            let mut res = Value::new(TypeKind::Int, to_ct_type(typ));
            res.i = i.to_string();
            res
        }
        ValueRecordWithType::Float { f, typ } => {
            let mut res = Value::new(TypeKind::Float, to_ct_type(typ));
            res.f = f.to_string();
            res
        }
        ValueRecordWithType::String { text, typ } => {
            let mut res = Value::new(TypeKind::String, to_ct_type(typ));
            res.text = text.clone();
            res
        }
        ValueRecordWithType::Bool { b, typ } => {
            let mut res = Value::new(TypeKind::Bool, to_ct_type(typ));
            res.b = *b;
            res
        }
        ValueRecordWithType::Sequence {
            elements,
            typ,
            is_slice,
        } => {
            // TODO: is_slice should be in the type kind: SLICE?
            let ct_typ = if !is_slice {
                to_ct_type(typ)
            } else {
                Type::new(TypeKind::Slice, &typ.lang_type)
            };
            let mut res = Value::new(TypeKind::Seq, ct_typ);
            res.elements = elements.iter().map(|e| to_ct_value(e)).collect();
            res
        }
        ValueRecordWithType::Struct { field_values, typ } => {
            let mut res = Value::new(TypeKind::Struct, to_ct_type(typ));
            res.elements = field_values.iter().map(|value| to_ct_value(value)).collect();
            res
        }
        ValueRecordWithType::Tuple { elements, typ } => {
            let mut res = Value::new(TypeKind::Tuple, to_ct_type(typ));
            res.elements = elements.iter().map(|value| to_ct_value(value)).collect();
            res.typ.labels = elements
                .iter()
                .enumerate()
                .map(|(index, _)| format!("{index}"))
                .collect();
            res.typ.member_types = res.elements.iter().map(|value| value.typ.clone()).collect();
            res
        }
        ValueRecordWithType::Variant {
            discriminator: _,
            contents: _,
            typ: _,
        } => {
            // variant-like enums not generated yet from noir tracer:
            //   we should support variants in general, but we'll think a bit first how
            //   to more cleanly/generally represent them in the codetracer code, as the current
            //   `Value` mapping doesn't seem great imo
            //   we can improve it, or we can add a new variant case (something more similar to the runtime_tracing repr?)
            todo!("a more suitable codetracer value/type for variants")
        }
        ValueRecordWithType::Reference {
            dereferenced,
            address,
            mutable,
            typ,
        } => {
            let mut res = Value::new(TypeKind::Pointer, to_ct_type(typ));
            let dereferenced_value = to_ct_value(dereferenced);
            res.typ.element_type = Some(Box::new(dereferenced_value.typ.clone()));
            res.address = (*address).to_string();
            res.ref_value = Some(Box::new(dereferenced_value));
            res.is_mutable = *mutable;
            res
        }
        ValueRecordWithType::Raw { r, typ } => {
            let mut res = Value::new(TypeKind::Raw, to_ct_type(typ));
            res.r = r.clone();
            res
        }
        ValueRecordWithType::Error { msg, typ } => {
            let mut res = Value::new(TypeKind::Error, to_ct_type(typ));
            res.msg = msg.clone();
            res
        }
        ValueRecordWithType::None { typ } => Value::new(TypeKind::None, to_ct_type(typ)),
        ValueRecordWithType::Cell { .. } => {
            // supposed to map to place in value graph
            // TODO
            unimplemented!()
        }
        ValueRecordWithType::BigInt { b, negative, typ } => {
            let sign = if *negative {
                num_bigint::Sign::Minus
            } else {
                num_bigint::Sign::Plus
            };

            let num = BigInt::from_bytes_be(sign, b);

            let mut res = Value::new(TypeKind::Int, to_ct_type(typ));
            res.i = num.to_string();
            res
        }
    }
}

pub fn to_ct_type(typ: &TypeRecord) -> Type {
    match typ.kind {
        TypeKind::Struct => {
            let mut t = Type::new(typ.kind, &typ.lang_type);
            t.labels = get_field_names(typ);
            t
        }
        _ => Type::new(typ.kind, &typ.lang_type),
    }
    // TODO: struct -> instance with labels/eventually other types
    // if type_record.kind != res.type
}

fn get_field_names(typ: &TypeRecord) -> Vec<String> {
    match &typ.specific_info {
        TypeSpecificInfo::Struct { fields } => fields.iter().map(|field| field.name.clone()).collect(),
        _ => Vec::new(),
    }
}
