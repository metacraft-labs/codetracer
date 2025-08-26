use serde::{Deserialize, Serialize};

#[derive(thiserror::Error, Debug)]
pub enum CommError {
    #[error("{0}")]
    Other(String),

    #[cfg(not(target_arch = "wasm32"))]
    #[error("io: {0}")]
    Io(#[from] std::io::Error),

    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
}

#[async_trait::async_trait(?Send)]
pub trait Comm {
    async fn send(&self, msg: &DapMessage) -> Result<(), CommError>;
    async fn recv(&self) -> Result<DapMessage, CommError>;
}

#[cfg(not(target_arch = "wasm32"))]
pub use native::SocketComm as DefaultComm;
#[cfg(target_arch = "wasm32")]
pub use wasm_port::PortComm as DefaultComm;
