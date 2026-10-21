//! The `ct-jsbound` command line, as a library function so the ingest's
//! finaliser (or a test) can run it in process as well as out of process.
//!
//! ```text
//! ct-jsbound assemble --recording-id <uuidv7> --out <file.ct>
//!                     [--idle | --session-cap] [--refused-batch <batch_seq>]...
//!                     <batch file or directory>...
//! ```
//!
//! A directory argument contributes every regular file in it (the staging
//! prefix `staging/js-boundary/{tenant}/{recording_id}/{batch_seq}`,
//! Boundary-Ingest.md §5). File names and argument order do not matter: the
//! batches are ordered by their envelopes' `batch_seq`.

use std::collections::BTreeSet;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use crate::assemble::{assemble, AssembleError, AssembleOptions, Finalisation};

/// The usage text.
pub const USAGE: &str = "usage: ct-jsbound assemble --recording-id <uuidv7> --out <file.ct> \
[--idle | --session-cap] [--refused-batch <batch_seq>]... <batch file or directory>...";

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
    Ok(AssembleArgs {
        options: AssembleOptions {
            recording_id,
            finalisation,
            refused_batches,
        },
        out,
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

/// Run `ct-jsbound` with `args` (without the program name). On success,
/// returns a one-line summary for stdout.
pub fn run(args: &[String]) -> Result<String, CliError> {
    let args = parse_args(args)?;
    let bodies = read_batches(&args.inputs)?;
    let assembled = assemble(&bodies, &args.options).map_err(CliError::Assemble)?;
    write_atomically(&args.out, &assembled.container)?;
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
