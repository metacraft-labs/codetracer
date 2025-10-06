use std::error::Error;
use std::fmt;

#[cfg(feature = "browser-transport")]
use wasm_bindgen::JsError;

#[derive(Debug)]
pub enum DapError {
    Io(std::io::Error),
    Json(serde_json::Error),

    #[cfg(feature = "browser-transport")]
    SerdeWasm(serde_wasm_bindgen::Error),
    #[cfg(feature = "browser-transport")]
    Js(JsErr),

    Msg(String),
}

impl fmt::Display for DapError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DapError::Io(e) => write!(f, "I/O error: {e}"),
            DapError::Json(e) => write!(f, "JSON error: {e}"),

            #[cfg(feature = "browser-transport")]
            DapError::SerdeWasm(e) => write!(f, "serde_wasm_bindgen error: {e}"),
            #[cfg(feature = "browser-transport")]
            DapError::Js(e) => write!(f, "JS error: {e}"),

            DapError::Msg(s) => write!(f, "{s}"),
        }
    }
}

impl Error for DapError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            DapError::Io(e) => Some(e),
            DapError::Json(e) => Some(e),

            #[cfg(feature = "browser-transport")]
            DapError::SerdeWasm(e) => Some(e),
            #[cfg(feature = "browser-transport")]
            DapError::Js(e) => Some(e),

            DapError::Msg(_) => None,
        }
    }
}
impl From<std::io::Error> for DapError {
    fn from(e: std::io::Error) -> Self {
        DapError::Io(e)
    }
}
impl From<serde_json::Error> for DapError {
    fn from(e: serde_json::Error) -> Self {
        DapError::Json(e)
    }
}

#[cfg(feature = "browser-transport")]
impl From<serde_wasm_bindgen::Error> for DapError {
    fn from(e: serde_wasm_bindgen::Error) -> Self {
        DapError::SerdeWasm(e)
    }
}

#[cfg(feature = "browser-transport")]
#[derive(Debug)]
pub struct JsErr(pub wasm_bindgen::JsValue);

#[cfg(feature = "browser-transport")]
impl fmt::Display for JsErr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(s) = self.0.as_string() {
            write!(f, "{s}")
        } else {
            write!(f, "{:?}", self.0)
        }
    }
}

#[cfg(feature = "browser-transport")]
impl Error for JsErr {}

#[cfg(feature = "browser-transport")]
impl From<wasm_bindgen::JsValue> for DapError {
    fn from(v: wasm_bindgen::JsValue) -> Self {
        DapError::Js(JsErr(v))
    }
}
