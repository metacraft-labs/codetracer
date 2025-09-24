use std::path::PathBuf;
use std::error::Error;

use serde::{Deserialize, Serialize};
use serde_repr::*;
use num_derive::FromPrimitive;

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


pub fn index_diff(diff: Diff, output_path: &PathBuf) -> Result<(), Box<dyn Error>> {
    // todo!();
    unimplemented!();
}