use serde::{Deserialize, Serialize};

use crate::task::{Action, CtLoadLocalsArguments};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum CtRRQuery {
    RunToEntry,
    LoadLocation,
    Step { action: Action, forward: bool },
    LoadLocals { arg: CtLoadLocalsArguments },
}
