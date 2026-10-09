//! Members that are not part of the trace format and make a container
//! unreadable.
//!
//! `events.log` (a single combined event stream) and `events.fmt` (its
//! encoding marker) are not trace-format members: a container's events live in
//! its split streams. The format library refuses a container carrying either,
//! by name, before reading any stream
//! ([`codetracer_trace_reader::retired_streams`]); this module applies the same
//! refusal to the db-backend's own [`CtfsReader`], so a container is never read
//! as if the member were not there, whichever reader opens it.

use codetracer_ctfs::{CompressionMethod, CtfsWriter};
use codetracer_trace_reader::retired_streams::{RETIRED_MEMBERS, refuse_retired_members as library_refusal};

use super::ctfs_container::CtfsReader;

/// `Err` naming the first retired member `ctfs` carries, in the format
/// library's words.
pub fn refuse_retired_members(ctfs: &CtfsReader) -> Result<(), String> {
    match RETIRED_MEMBERS.into_iter().find(|name| ctfs.has_file(name)) {
        Some(name) => Err(refusal_naming(name)),
        None => Ok(()),
    }
}

/// The format library's refusal of a container carrying `name`.
///
/// The library words its refusal over its own reader type, which the
/// db-backend's reader (file, follow, in-memory, HTTP range, overlay sources)
/// is not; it is therefore asked about a container holding nothing but an
/// empty `name`, which it refuses with the sentence it would use for any
/// container carrying that member.
fn refusal_naming(name: &str) -> String {
    let probe = (|| -> Result<codetracer_ctfs::CtfsReader, codetracer_ctfs::CtfsError> {
        let mut writer = CtfsWriter::create_in_memory(4096, 31, CompressionMethod::None)?;
        writer.add_file(name)?;
        codetracer_ctfs::CtfsReader::from_bytes(writer.finish_to_bytes()?)
    })();
    match probe.map(|reader| library_refusal(&reader)) {
        Ok(Err(refusal)) => refusal,
        // Unreachable while `RETIRED_MEMBERS` names what the library refuses;
        // the container is still refused, by name.
        Ok(Ok(())) | Err(_) => format!("this container carries `{name}`, which is not part of the trace format"),
    }
}
