use serde::{Deserialize, Serialize};

use crate::lang::Lang;
use crate::task::{Action, Breakpoint, CtLoadLocalsArguments, Location, ProgramEvent};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum CtRRQuery {
    RunToEntry,
    LoadLocation,
    Step { action: Action, forward: bool },
    LoadLocals { arg: CtLoadLocalsArguments },
    LoadReturnValue { lang: Lang },
    LoadValue { expression: String, lang: Lang },
    AddBreakpoint { path: String, line: i64 },
    DeleteBreakpoint { breakpoint: Breakpoint },
    DeleteBreakpoints,
    ToggleBreakpoint { breakpoint: Breakpoint },
    EnableBreakpoints,
    DisableBreakpoints,
    JumpToCall { location: Location },
    LoadAllEvents,
    LoadCallstack,
    EventJump { program_event: ProgramEvent },
    CallstackJump { depth: usize },
}
