use std::path::PathBuf;
use std::error::Error;

use serde::{Deserialize, Serialize};
use serde_repr::*;

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

pub enum FileChange {
    #[default]
    Added,
    Deleted,
    Renamed,
    Changed,
}

pub fn index_diff(diff: Diff, output_path: &PathBuf) -> Result<(), Box<dyn Error>> {
    todo!();
}