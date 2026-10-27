//! The `ct-jsbound` command line, as a library function so the ingest's
//! finaliser (or a test) can run it in process as well as out of process.
//!
//! ```text
//! ct-jsbound assemble --recording-id <uuidv7> --out <file.ct>
//!                     [--idle | --session-cap] [--refused-batch <batch_seq>]...
//!                     [--summary <file.json>]
//!                     <batch file or directory>...
//! ct-jsbound summarize <file.ct>
//! ct-jsbound narrate <file.ct> [--out <file.json>]
//! ct-jsbound events <file.ct> [--seq-from <seq>] [--seq-to <seq>]
//!                   [--kinds <Kind,Kind,...>] [--limit <n>] [--out <file.json>]
//! ```
//!
//! `--summary` also writes the assembled session's [`Summary`] as JSON (its
//! `seq` range, gaps, refusals, whether it is replayable, whether it holds an
//! `Error`, the `traceparent`'s trace id and the experiment arms), so that a
//! caller that must not decode recorder bytes itself (the ingest) learns them
//! from this process. It is written, like the `.ct`, through a temporary file
//! and a rename, and only when assembly succeeds. `summarize` reads an
//! assembled `.ct` back, verifies it and prints the same summary with its
//! `recording_id` and member names (for tests and tools that check a stored
//! recording).
//!
//! `narrate` writes the session's narrative document and `events` the
//! decoded records of a `seq` range ([`crate::narrate`]), each as one JSON
//! document, to `--out` (through a temporary file and a rename) or stdout. A
//! caller that must not decode recorder bytes itself runs them sandboxed over
//! a stored recording, as it runs `assemble`.
//!
//! A directory argument contributes every regular file in it (the staging
//! prefix `staging/js-boundary/{tenant}/{recording_id}/{batch_seq}`,
//! Boundary-Ingest.md §5). File names and argument order do not matter: the
//! batches are ordered by their envelopes' `batch_seq`.

use std::collections::BTreeSet;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use crate::assemble::{assemble, summarise, AssembleError, AssembleOptions, Finalisation, Summary};
use crate::container::{BoundaryRecording, MEMBERS};
use crate::narrate::{events, narrate, EventQuery, MAX_EVENTS};

/// The usage text.
pub const USAGE: &str = "usage: ct-jsbound assemble --recording-id <uuidv7> --out <file.ct> \
[--idle | --session-cap] [--refused-batch <batch_seq>]... [--summary <file.json>] \
<batch file or directory>...\n       ct-jsbound summarize <file.ct>\n       \
ct-jsbound narrate <file.ct> [--out <file.json>]\n       \
ct-jsbound events <file.ct> [--seq-from <seq>] [--seq-to <seq>] [--kinds <Kind,...>] \
[--limit <n>] [--out <file.json>]";

/// Why the command failed.
#[derive(Debug)]
pub enum CliError {
    /// The arguments are wrong (exit status 2).
    Usage(String),
    /// A file could not be read or written (exit status 1).
    Io(String),
    /// The assembler refused the batches (exit status 1).
    Assemble(AssembleError),
}

impl CliError {
    /// The process exit status for this error.
    pub fn exit_code(&self) -> i32 {
        match self {
            CliError::Usage(_) => 2,
            CliError::Io(_) | CliError::Assemble(_) => 1,
        }
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CliError::Usage(e) => write!(f, "{e}\n{USAGE}"),
            CliError::Io(e) => write!(f, "{e}"),
            CliError::Assemble(e) => write!(f, "assembly refused: {e}"),
        }
    }
}

impl std::error::Error for CliError {}

/// The parsed `assemble` arguments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssembleArgs {
    pub options: AssembleOptions,
    pub out: PathBuf,
    /// Where to write the [`Summary`] JSON, if anywhere.
    pub summary: Option<PathBuf>,
    pub inputs: Vec<PathBuf>,
}

/// Parse the arguments after the program name.
pub fn parse_args(args: &[String]) -> Result<AssembleArgs, CliError> {
    let usage = |m: String| Err(CliError::Usage(m));
    match args.first().map(String::as_str) {
        Some("assemble") => {}
        Some(other) => return usage(format!("unknown command {other:?}")),
        None => return usage("no command given".into()),
    }
    let mut recording_id = None;
    let mut out = None;
    let mut summary = None;
    let mut finalisation = Finalisation::Ended;
    let mut refused_batches = BTreeSet::new();
    let mut inputs = Vec::new();
    let mut it = args[1..].iter();
    while let Some(arg) = it.next() {
        let mut value = |name: &str| {
            it.next()
                .cloned()
                .ok_or_else(|| CliError::Usage(format!("{name} needs a value")))
        };
        match arg.as_str() {
            "--recording-id" => recording_id = Some(value("--recording-id")?),
            "--out" => out = Some(PathBuf::from(value("--out")?)),
            "--summary" => summary = Some(PathBuf::from(value("--summary")?)),
            "--idle" | "--session-cap" => {
                if finalisation != Finalisation::Ended {
                    return usage(
                        "--idle and --session-cap are exclusive, and each is given once".into(),
                    );
                }
                finalisation = if arg == "--idle" {
                    Finalisation::Idle
                } else {
                    Finalisation::SessionCap
                };
            }
            "--refused-batch" => {
                let v = value("--refused-batch")?;
                let n = v.parse::<u64>().map_err(|_| {
                    CliError::Usage(format!("--refused-batch {v:?} is not a batch_seq"))
                })?;
                refused_batches.insert(n);
            }
            flag if flag.starts_with("--") => return usage(format!("unknown option {flag}")),
            path => inputs.push(PathBuf::from(path)),
        }
    }
    let Some(recording_id) = recording_id else {
        return usage("--recording-id is required".into());
    };
    let Some(out) = out else {
        return usage("--out is required".into());
    };
    if inputs.is_empty() {
        return usage("no batch files given".into());
    }
    // The summary is written after the `.ct`, so at the same path it would
    // replace the recording with JSON and still report success.
    if summary.as_ref() == Some(&out) {
        return usage("--summary must name a different file than --out".into());
    }
    Ok(AssembleArgs {
        options: AssembleOptions {
            recording_id,
            finalisation,
            refused_batches,
        },
        out,
        summary,
        inputs,
    })
}

fn io_err(what: &str, path: &Path, e: std::io::Error) -> CliError {
    CliError::Io(format!("cannot {what} {}: {e}", path.display()))
}

/// Read every batch body named by `inputs` (files, or directories whose
/// regular files are batches), in a sorted, reproducible order.
pub fn read_batches(inputs: &[PathBuf]) -> Result<Vec<Vec<u8>>, CliError> {
    let mut files = Vec::new();
    for input in inputs {
        let meta = fs::metadata(input).map_err(|e| io_err("read", input, e))?;
        if meta.is_dir() {
            let mut entries = Vec::new();
            for entry in fs::read_dir(input).map_err(|e| io_err("list", input, e))? {
                let entry = entry.map_err(|e| io_err("list", input, e))?;
                let ty = entry
                    .file_type()
                    .map_err(|e| io_err("stat", &entry.path(), e))?;
                if ty.is_file() {
                    entries.push(entry.path());
                }
            }
            entries.sort();
            files.extend(entries);
        } else {
            files.push(input.clone());
        }
    }
    files
        .iter()
        .map(|f| fs::read(f).map_err(|e| io_err("read", f, e)))
        .collect()
}

/// `ct-jsbound summarize <file.ct>`: open a boundary recording, verify it as
/// `BoundaryRecording` does (exactly the four members, the log decoded
/// strictly and complete, `jsbound.blb` and `jsbound.chk` agreeing with it),
/// and return its [`Summary`] as one line of JSON, with the container's
/// `recording_id` and member names added. `batches` is 0: a recording does
/// not say how many batches it was assembled from. A file that is not a
/// valid boundary recording exits 1.
fn summarize(args: &[String]) -> Result<String, CliError> {
    let [path] = args else {
        return Err(CliError::Usage(
            "summarize takes exactly one .ct file".into(),
        ));
    };
    let bytes = fs::read(path).map_err(|e| io_err("read", Path::new(path), e))?;
    let len = bytes.len();
    let recording = BoundaryRecording::read(bytes)
        .map_err(|e| CliError::Io(format!("{path} is not a valid boundary recording: {e}")))?;
    let mut value = serde_json::to_value(summarise(&recording.log, 0, len))
        .expect("a Summary always serialises to JSON");
    value["recording_id"] = recording.meta.recording_id.clone().into();
    value["members"] = serde_json::json!(MEMBERS);
    Ok(value.to_string())
}

/// Read and verify the boundary recording at `path` (exit 1 when it is not one).
fn read_recording(path: &str) -> Result<BoundaryRecording, CliError> {
    let bytes = fs::read(path).map_err(|e| io_err("read", Path::new(path), e))?;
    BoundaryRecording::read(bytes)
        .map_err(|e| CliError::Io(format!("{path} is not a valid boundary recording: {e}")))
}

/// The `.ct` path and the options of `narrate` and `events`: `--out` and
/// whatever `value_option` accepts (an option it does not know is a usage
/// error).
fn recording_command<'a>(
    command: &str,
    args: &'a [String],
    mut value_option: impl FnMut(&str, &str) -> Result<bool, CliError>,
) -> Result<(&'a str, Option<PathBuf>), CliError> {
    let mut input = None;
    let mut out = None;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        if arg.starts_with("--") {
            let value = it
                .next()
                .ok_or_else(|| CliError::Usage(format!("{arg} needs a value")))?;
            if arg == "--out" {
                out = Some(PathBuf::from(value));
            } else if !value_option(arg, value)? {
                return Err(CliError::Usage(format!(
                    "unknown option {arg} for {command}"
                )));
            }
        } else if input.replace(arg.as_str()).is_some() {
            return Err(CliError::Usage(format!(
                "{command} takes exactly one .ct file"
            )));
        }
    }
    let input = input.ok_or_else(|| CliError::Usage(format!("{command} needs a .ct file")))?;
    Ok((input, out))
}

/// Write `document` to `out`, or return it for stdout.
fn emit(document: &serde_json::Value, out: Option<PathBuf>) -> Result<String, CliError> {
    let mut bytes = serde_json::to_vec(document).expect("a JSON value always serialises");
    match out {
        Some(path) => {
            bytes.push(b'\n');
            write_atomically(&path, &bytes)?;
            Ok(format!("wrote {} ({} bytes)", path.display(), bytes.len()))
        }
        None => Ok(String::from_utf8(bytes).expect("serde_json writes UTF-8")),
    }
}

fn parse_seq(option: &str, value: &str) -> Result<u64, CliError> {
    value
        .parse::<u64>()
        .map_err(|_| CliError::Usage(format!("{option} {value:?} is not a seq")))
}

/// `ct-jsbound narrate <file.ct> [--out <file.json>]`.
fn narrate_command(args: &[String]) -> Result<String, CliError> {
    let (input, out) = recording_command("narrate", args, |_, _| Ok(false))?;
    let recording = read_recording(input)?;
    emit(&narrate(&recording), out)
}

/// `ct-jsbound events <file.ct> [--seq-from] [--seq-to] [--kinds] [--limit] [--out]`.
fn events_command(args: &[String]) -> Result<String, CliError> {
    let mut query = EventQuery::default();
    let (input, out) = recording_command("events", args, |option, value| {
        match option {
            "--seq-from" => query.seq_from = parse_seq(option, value)?,
            "--seq-to" => query.seq_to = parse_seq(option, value)?,
            "--kinds" => {
                query.kinds = value
                    .split(',')
                    .map(str::trim)
                    .filter(|k| !k.is_empty())
                    .map(str::to_string)
                    .collect();
                if let Some(unknown) = query
                    .kinds
                    .iter()
                    .find(|k| !crate::record::RECORD_KINDS.iter().any(|(_, n)| n == k))
                {
                    return Err(CliError::Usage(format!(
                        "--kinds: {unknown:?} is no record kind"
                    )));
                }
            }
            "--limit" => {
                query.limit = value
                    .parse::<usize>()
                    .ok()
                    .filter(|n| (1..=MAX_EVENTS).contains(n))
                    .ok_or_else(|| {
                        CliError::Usage(format!("--limit {value:?} is not from 1 to {MAX_EVENTS}"))
                    })?;
            }
            _ => return Ok(false),
        }
        Ok(true)
    })?;
    if query.seq_to < query.seq_from {
        return Err(CliError::Usage("--seq-to is before --seq-from".into()));
    }
    let recording = read_recording(input)?;
    emit(&events(&recording, &query), out)
}

/// Run `ct-jsbound` with `args` (without the program name). On success,
/// returns a one-line summary (or the document, for `narrate` and `events`
/// without `--out`) for stdout.
pub fn run(args: &[String]) -> Result<String, CliError> {
    match args.first().map(String::as_str) {
        Some("summarize") => return summarize(&args[1..]),
        Some("narrate") => return narrate_command(&args[1..]),
        Some("events") => return events_command(&args[1..]),
        _ => {}
    }
    let args = parse_args(args)?;
    let bodies = read_batches(&args.inputs)?;
    let assembled = assemble(&bodies, &args.options).map_err(CliError::Assemble)?;
    write_atomically(&args.out, &assembled.container)?;
    if let Some(path) = &args.summary {
        write_atomically(path, &summary_json(&assembled.summary))?;
    }
    Ok(format!(
        "wrote {} ({} bytes: jsbound.log {} B, jsbound.blb {} B, jsbound.chk {} B) from {} batch(es)",
        args.out.display(),
        assembled.container.len(),
        assembled.members.log.len(),
        assembled.members.blb.len(),
        assembled.members.chk.len(),
        bodies.len()
    ))
}

/// The `--summary` document: the [`Summary`] as one line of JSON, newline
/// terminated. A summary always serialises (strings, integers, booleans and
/// a map of strings), so a failure here is a bug.
pub fn summary_json(summary: &Summary) -> Vec<u8> {
    let mut bytes = serde_json::to_vec(summary).expect("a Summary always serialises to JSON");
    bytes.push(b'\n');
    bytes
}

/// Write `bytes` to `out` through a temporary file in the same directory and
/// a rename, so a crash never leaves a partial `.ct` under the final name.
fn write_atomically(out: &Path, bytes: &[u8]) -> Result<(), CliError> {
    let mut tmp = out.as_os_str().to_owned();
    tmp.push(format!(".partial-{}", std::process::id()));
    let tmp = PathBuf::from(tmp);
    fs::write(&tmp, bytes).map_err(|e| io_err("write", &tmp, e))?;
    fs::rename(&tmp, out).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        io_err("rename into place", out, e)
    })
}
