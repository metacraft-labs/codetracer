use crate::task::{EventId, EventKind};
use serde_json::Value;

#[derive(Debug)]
pub enum Event {
    Keyboard {
        key_event: crossterm::event::KeyEvent,
    },
    CoreEvent {
        event_kind: EventKind,
        event_id: EventId,
        raw: String,
    },
    Error {
        message: String,
    },
}

#[derive(Debug)]
pub enum CtEvent {
    Builtin(Event),
    Dap(Value),
}
