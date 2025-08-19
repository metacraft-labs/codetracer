#![allow(dead_code)]
// use std::ffi::{c_char, CStr, CString};
// use std::slice;

// use runtime_tracing::EventLogKind;

pub mod calltrace;
pub mod core;
pub mod dap;
pub mod dap_server;
pub mod db;
pub mod distinct_vec;
pub mod event_db;
pub mod expr_loader;
pub mod flow_preloader;
pub mod handler;
pub mod lang;
pub mod paths;
pub mod program_search_tool;
pub mod step_lines_loader;
pub mod task;
pub mod trace_processor;
pub mod types;
pub mod tracepoint_interpreter;
pub mod value;

// use event_db::{DbEventKind, EventDb};
// use task::{ProgramEvent, UpdateTableArgs};

// #[no_mangle]
// pub extern "C" fn new_event_db() -> EventDb {
//     EventDb::new()
// }

// #[no_mangle]
// pub extern "C" fn event_db_register_events(
//     event_db: &mut EventDb,
//     kind: DbEventKind,
//     events: *const ProgramEvent,
//     events_count: usize,
// ) {
//     let events_slice = unsafe { slice::from_raw_parts(events, events_count) };
//     event_db.register_events(kind, events_slice);
// }

// #[no_mangle]
// pub extern "C" fn event_db_program_event(
//     kind: EventLogKind,
//     content: *const c_char,
//     rr_event_id: usize,
//     path: *const c_char,
//     line: i64,
//     filename_metadata: *const c_char,
//     bytes: usize,
//     stdout: bool,
//     direct_location_rr_ticks: i64,
//     tracepoint_result_index: i64,
//     event_index: usize,
// ) -> ProgramEvent {
//     ProgramEvent {
//         kind,
//         content: unsafe { CStr::from_ptr(content) }.to_str().unwrap().to_owned(),
//         rr_event_id,
//         high_level_path: unsafe { CStr::from_ptr(path) }.to_str().unwrap().to_owned(),
//         high_level_line: line,
//         filename_metadata: unsafe { CStr::from_ptr(filename_metadata) }
//             .to_str()
//             .unwrap()
//             .to_owned(),
//         bytes,
//         stdout,
//         direct_location_rr_ticks,
//         tracepoint_result_index,
//         event_index,
//     }
// }

// #[derive(Debug, Clone)]
// #[repr(C)]
// pub struct UpdateTableToJson {
//     trace_update: *const c_char,
//     trace_values: *const c_char,
//     // has_error: bool,
// }

// #[no_mangle]
// pub extern "C" fn event_db_update_table_to_json(
//     event_db: &mut EventDb,
//     args: UpdateTableArgs,
//     json: &mut UpdateTableToJson,
// ) -> bool {
//     if let Ok((trace_update_json, trace_values_json_option)) = event_db.update_table_to_json(args) {
//         let trace_values_json_simple = trace_values_json_option.unwrap_or("".to_string());
//         json.trace_update = CString::new(trace_update_json).unwrap().into_raw();
//         json.trace_values = CString::new(trace_values_json_simple).unwrap().into_raw();
//         false
//     } else {
//         true
//     }
// }
