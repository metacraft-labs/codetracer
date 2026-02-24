use codetracer_trace_types::{TraceLowLevelEvent, TraceMetadata};
use once_cell::sync::Lazy;
use std::{error::Error, path::Path, str};
use vfs::{MemoryFS, VfsPath};

/// In-memory VFS root shared across the process lifetime. The program is fully synchronous,
/// so no synchronization primitive beyond `Lazy` is required.
static TRACE_VFS_ROOT: Lazy<VfsPath> = Lazy::new(|| MemoryFS::new().into());

/// Returns the singleton VFS root that should be used across the application.
pub fn trace_vfs_root() -> &'static VfsPath {
    &TRACE_VFS_ROOT
}

pub fn load_trace_data_vfs(
    root: &VfsPath,
    virtual_path: &str,
    file_format: codetracer_trace_reader::TraceEventsFileFormat,
) -> Result<Vec<TraceLowLevelEvent>, Box<dyn Error>> {
    let mut f = root.join(virtual_path)?.open_file()?;
    let mut bytes = Vec::new();
    f.read_to_end(&mut bytes)?;
    let mut rdr = codetracer_trace_reader::create_trace_reader(file_format);
    Ok(rdr.load_trace_events(Path::new(virtual_path)).unwrap())
}

pub fn load_trace_metadata_vfs(root: &VfsPath, virtual_path: &str) -> Result<TraceMetadata, Box<dyn Error>> {
    let mut f = root.join(virtual_path)?.open_file()?;
    let mut s = String::new();
    f.read_to_string(&mut s)?;
    Ok(serde_json::from_str(&s)?)
}
