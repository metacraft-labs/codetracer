use serde::{Deserialize, Serialize};

use crate::task::{Action, Breakpoint, CtLoadLocalsArguments, Location};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum CtRRQuery {
    RunToEntry,
    LoadLocation,
    Step { action: Action, forward: bool },
    LoadLocals { arg: CtLoadLocalsArguments },
    LoadReturnValue,
    LoadValue { expression: String },
    AddBreakpoint { path: String, line: i64, },
    DeleteBreakpoint { breakpoint: Breakpoint, },
    DeleteBreakpoints,
    ToggleBreakpoint { breakpoint: Breakpoint, },
    JumpToCall { location: Location },
}
