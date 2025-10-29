use serde::{Deserialize, Serialize};

use crate::task::{Action, Breakpoint, CtLoadLocalsArguments, Location, ProgramEvent};
use crate::lang::Lang;

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
    JumpToCall { location: Location },
    LoadAllEvents,
    EventJump { program_event: ProgramEvent },
}
