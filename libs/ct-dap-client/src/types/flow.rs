use serde::{Deserialize, Serialize};
use serde_repr::{Deserialize_repr, Serialize_repr};

use super::navigation::Location;

#[derive(Debug, Default, Clone, Copy, Serialize_repr, Deserialize_repr)]
#[repr(u8)]
pub enum FlowMode {
    #[default]
    Call = 0,
    Diff = 1,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoadFlowArguments {
    pub flow_mode: FlowMode,
    pub location: Location,
}
