use runtime_tracing::TypeKind;
use serde::{Deserialize, Serialize};

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
    pub typ: Type,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[serde(default)]
pub struct Type {
    pub kind: TypeKind,
    pub lang_type: String,
    pub c_type: String,
    // pub elements: Vec<Type>,
    pub labels: Vec<String>,
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
    #[allow(dead_code)]
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
