use crate::task::{EventId, EventKind, Task};
use serde::Serialize;

// kind, id, payload, is_raw
pub type Event = (EventKind, EventId, String, bool);

// TODO: Box<dyn Serialize> based on erased-serde?
// https://github.com/dtolnay/erased-serde
// otherwise object safety errors
// or some other kind of trait?
// serializing should be responsibility of Sender
// for now doing it in handler
pub type TaskResult = (Task, String);

// pub fn task_result<T: Serialize>(task: Task, value: T) -> TaskResult {
//    (task, serde_json::to_string(&value).unwrap())
//}

//RunToEntry(TaskId),
//  LoadLocals(TaskId),
//}

#[derive(Debug, Clone)]
pub enum Response {
    EventResponse(Event),
    TaskResponse(TaskResult),
}

#[derive(Debug, Clone, Serialize)]
pub struct VoidResult {}

pub const VOID_RESULT: &str = "{}";
// look at TaskResult
//comment VoidResult {};

// could be united to
// enum Response {
//  FlowUpdate()
//  ..,
//  LoadLocals(..)
//}

// and a method for is_event

// rpc call
//
