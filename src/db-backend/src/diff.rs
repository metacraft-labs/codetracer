use std::path::{PathBuf, Path};
use std::error::Error;
use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_repr::*;
use num_derive::FromPrimitive;
use runtime_tracing::FunctionId;
use log::info;

use crate::db::{Db,DbReplay};
use crate::trace_processor::{load_trace_data, load_trace_metadata, TraceProcessor};
use crate::flow_preloader::FlowPreloader;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Diff {
    pub files: Vec<FileDiff>,
} 

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileDiff {
    pub chunks: Vec<Chunk>,
    pub previous_path: PathBuf,
    pub current_path: PathBuf,
    pub change: FileChange,
}

#[derive(Clone, Debug, Default, Copy, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum FileChange {
    #[default]
    Added,
    Deleted,
    Renamed,
    Changed,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Chunk {
    pub previous_from: i64,
    pub previous_count: i64,
    pub current_from: i64,
    pub current_count: i64,
    pub lines: Vec<DiffLine>
}

#[derive(Clone, Debug, Default, Copy, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum DiffLineKind {
    #[default]
    NonChanged,
    Deleted,
    Added,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffLine {
    pub kind: DiffLineKind,
    pub text: String,
    pub previous_line_number: i64,
    pub current_line_number: i64,
}


// loop shape 1:
pub fn load_and_postprocess_trace(trace_folder: &Path) -> Result<Db, Box<dyn Error>> {
    info!("load_and_postprocess_trace {:?}", trace_folder.display());
    let mut trace_path = trace_folder.join("trace.json");
    let mut trace_file_format = runtime_tracing::TraceEventsFileFormat::Json;
    if !trace_path.exists() {
        trace_path = trace_folder.join("trace.bin");
        trace_file_format = runtime_tracing::TraceEventsFileFormat::Binary;
    }
    let metadata_path = trace_folder.join("trace_metadata.json");
    
    let meta = load_trace_metadata(&metadata_path)?;
    let trace = load_trace_data(&trace_path, trace_file_format)?;
    let mut db = Db::new(&meta.workdir);
    let mut processor = TraceProcessor::new(&mut db);
    processor.postprocess(&trace)?;

    Ok(db)
}

// loop shape 2:
fn index_function_flow(_db: &Db, function_id: FunctionId) -> Result<(), Box<dyn Error>> {
    // recursion?
    // each call: load current flow view update(eventually first N, but also the total count)
    // send a vector with those and the count
    // step_id: RRTicks & path/line;
    // while 1 {
    //   simple;
    // }

    // IPT: 
    // step_id: RR
    // call_key: name/ticks/depth/origin address
    // global flow: (call index/key, step_count)
    // call_index
    // call_key => Nth function call;
    // (call_key) => index;

    todo!("index function flow for {function_id:?}");
}


pub fn index_diff(diff: Diff, trace_folder: &Path) -> Result<(), Box<dyn Error>> {
    info!("index_diff");
    let db = load_and_postprocess_trace(trace_folder)?;

    // breakpoint on each diff line or at least track it for db-backend
    // collect flow data
    // .. maybe for db-backend; easier for now to collect for all function calls there!

    // either rewrite part of flow
    // or add a new impl of a preloader
    // or somehow construct for now a simpler type
    // or try to fix nestedness and send it

    // or
    // load individual flows for each call and send a new kind of object
    // containing `functions: Vec<FunctionGlobalFlow>` and 
    // Vec<FlowUpdate> ? with special handling
    // or a function flow with loop for each repetition still (but maybe then assumptions for call key etc..? maybe easy to parametrize call keys)

    let mut diff_lines: HashSet<(PathBuf, i64)> = HashSet::new();
    for file in diff.files {
        for chunk in file.chunks {
            for line in chunk.lines {
                // (alexander): TODO: think more: i think `Added`` is most important, otherwise we might get
                //   flow for functions without actual added lines if they accidentally have non-changed lines in the diff chunks
                //
                // for now we also add `NonChanged` , because
                // however sometimes there can be a changed line without a step in the trace, but with steps around it from the same function..
                // in this case non-changed lines can help, but maybe it's better to somehow detect near steps, or
                // to ignore such functions (?)
                if line.kind == DiffLineKind::Added || line.kind == DiffLineKind::NonChanged {
                    diff_lines.insert((file.current_path.clone(), line.current_line_number));
                }
            }
        }
    }    
    
    info!("diff_lines {diff_lines:?}");
    let mut flow_preloader = FlowPreloader::new();
    let mut replay = Box::new(DbReplay::new(db.clone()));
    let flow_update = flow_preloader.load_diff_flow(diff_lines, &db, &mut replay);

    let raw = serde_json::to_string(&flow_update)?;
    std::fs::write(trace_folder.join("diff_index.json"), raw)?;
    Ok(())
}