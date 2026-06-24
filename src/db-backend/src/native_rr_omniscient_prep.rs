use crate::ctfs_trace_reader::interval_tagged_map::MemWriteEntry;
use crate::ctfs_trace_reader::server_prep_encoding::{
    CollapsedLinehits, CollapsedMemwrites, encode_linehits, encode_memwrites,
};
use crate::omniscient_db::{CTFS_LINEHITS_FILE, CTFS_MEMWRITES_FILE};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::error::Error;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_STEPS: usize = 400_000;
const MAX_RANGE_BYTES: usize = 8 * 1024 * 1024;
const MAX_TOTAL_SNAPSHOT_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug)]
pub struct NativeRrPrepOutput {
    pub capability_count: usize,
}

#[derive(Debug, Deserialize)]
struct TraceDbMetadata {
    program: PathBuf,
    workdir: PathBuf,
}

#[derive(Debug, Deserialize)]
struct JsonWrite {
    tick: u64,
    pc: u64,
    address: u64,
    size: u8,
    old_value: u64,
    new_value: u64,
}

#[derive(Debug, Deserialize)]
struct JsonLineHit {
    file_id: u32,
    line: u32,
    ticks: Vec<u64>,
}

#[derive(Debug, Deserialize)]
struct CollectorOutput {
    writes: Vec<JsonWrite>,
    linehits: Vec<JsonLineHit>,
    diagnostics: Vec<String>,
}

pub fn run(slice_folder: &Path, meta_dat: &Path) -> Result<NativeRrPrepOutput, Box<dyn Error>> {
    let rr_trace = slice_folder.join("rr");
    if !rr_trace.is_dir() {
        return Err(format!(
            "native omniscient-prep expected RR trace directory at {}",
            rr_trace.display()
        )
        .into());
    }

    let program = resolve_recorded_program(slice_folder)?;
    let rr = find_program_on_path("rr").ok_or_else(|| -> Box<dyn Error> { "rr not found on PATH".into() })?;
    let gdb = find_program_on_path("gdb").ok_or_else(|| -> Box<dyn Error> { "gdb not found on PATH".into() })?;

    let port = reserve_tcp_port()?;
    let mut rr_child = RrReplay::spawn(&rr, &rr_trace, port)?;

    let temp = make_temp_dir("ct-native-rr-omniscient")?;
    let script_path = temp.join("collect.py");
    let json_path = temp.join("collector-output.json");
    let script = collector_script(&program, &json_path)?;
    fs::write(&script_path, script)?;

    let gdb_output = Command::new(&gdb)
        .arg("-q")
        .arg("--nx")
        .arg("--batch")
        .arg("-ex")
        .arg("set pagination off")
        .arg("-ex")
        .arg(format!("file {}", program.display()))
        .arg("-ex")
        .arg(format!("target extended-remote :{port}"))
        .arg("-x")
        .arg(&script_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| format!("failed to launch gdb at {}: {e}", gdb.display()))?;
    rr_child.stop();

    if !gdb_output.status.success() {
        return Err(format!(
            "gdb RR omniscient collector failed with {:?}\nstdout:\n{}\nstderr:\n{}",
            gdb_output.status.code(),
            String::from_utf8_lossy(&gdb_output.stdout),
            String::from_utf8_lossy(&gdb_output.stderr)
        )
        .into());
    }

    let output_text = fs::read_to_string(&json_path)
        .map_err(|e| format!("gdb RR omniscient collector did not write {}: {e}", json_path.display()))?;
    let collected: CollectorOutput =
        serde_json::from_str(&output_text).map_err(|e| format!("failed to parse RR omniscient collector JSON: {e}"))?;
    if collected.writes.is_empty() {
        return Err(format!(
            "RR omniscient collector produced no memory writes; diagnostics: {:?}",
            collected.diagnostics
        )
        .into());
    }
    if collected.linehits.is_empty() {
        return Err(format!(
            "RR omniscient collector produced no source line hits; diagnostics: {:?}",
            collected.diagnostics
        )
        .into());
    }

    let mut per_address: BTreeMap<u64, Vec<MemWriteEntry>> = BTreeMap::new();
    for write in collected.writes {
        per_address.entry(write.address).or_default().push(MemWriteEntry {
            tick: write.tick,
            pc: write.pc,
            size: u32::from(write.size),
            old_value: write.old_value,
            new_value: write.new_value,
        });
    }
    for writes in per_address.values_mut() {
        writes.sort_by_key(|w| w.tick);
    }

    let mut per_line = collected
        .linehits
        .into_iter()
        .map(|mut hit| {
            hit.ticks.sort_unstable();
            hit.ticks.dedup();
            (hit.file_id, hit.line, hit.ticks)
        })
        .collect::<Vec<_>>();
    per_line.sort_by_key(|(file_id, line, _)| (*file_id, *line));

    let memwrites = encode_memwrites(&CollapsedMemwrites {
        per_address: per_address.into_iter().collect(),
    });
    let capability_count = per_line.len();
    let linehits = encode_linehits(&CollapsedLinehits { per_line });

    fs::write(meta_dat.join(CTFS_MEMWRITES_FILE), &memwrites)?;
    fs::write(meta_dat.join(CTFS_LINEHITS_FILE), &linehits)?;

    Ok(NativeRrPrepOutput { capability_count })
}

fn resolve_recorded_program(slice_folder: &Path) -> Result<PathBuf, Box<dyn Error>> {
    let metadata_path = slice_folder.join("trace_db_metadata.json");
    let metadata_text = fs::read_to_string(&metadata_path)
        .map_err(|e| format!("native omniscient-prep could not read {}: {e}", metadata_path.display()))?;
    let metadata: TraceDbMetadata = serde_json::from_str(&metadata_text)
        .map_err(|e| format!("failed to parse {}: {e}", metadata_path.display()))?;
    let program = if metadata.program.is_absolute() {
        metadata.program
    } else {
        metadata.workdir.join(metadata.program)
    };
    if !program.is_file() {
        return Err(format!(
            "recorded program from {} is not an executable file: {}",
            metadata_path.display(),
            program.display()
        )
        .into());
    }
    Ok(program)
}

struct RrReplay {
    child: Option<Child>,
    stderr_thread: Option<JoinHandle<()>>,
}

impl RrReplay {
    fn spawn(rr: &Path, trace: &Path, port: u16) -> Result<Self, Box<dyn Error>> {
        let mut child = Command::new(rr)
            .arg("replay")
            .arg(trace)
            .arg("-g")
            .arg("15")
            .arg(format!("--dbgport={port}"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| {
                format!(
                    "failed to launch rr replay server {} for {}: {e}",
                    rr.display(),
                    trace.display()
                )
            })?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| -> Box<dyn Error> { "failed to capture rr replay stderr".into() })?;
        let (tx, rx) = mpsc::channel::<String>();
        let stderr_thread = thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines().map_while(Result::ok) {
                let _ = tx.send(line);
            }
        });

        let needle = format!("127.0.0.1:{port}");
        let mut startup_lines = Vec::new();
        let timeout = Duration::from_secs(20);
        let started = Instant::now();
        loop {
            match rx.recv_timeout(Duration::from_millis(250)) {
                Ok(line) => {
                    let ready = line.contains(&needle);
                    startup_lines.push(line);
                    if ready {
                        thread::sleep(Duration::from_millis(100));
                        break;
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if started.elapsed() >= timeout {
                        return Err(format!(
                            "rr replay did not report debugger port {port}; recent stderr: {:?}",
                            startup_lines
                        )
                        .into());
                    }
                    if let Some(status) = child.try_wait()? {
                        return Err(format!(
                            "rr replay exited before debugger port {port} was ready: {status}; stderr: {:?}",
                            startup_lines
                        )
                        .into());
                    }
                    if startup_lines.is_empty() {
                        thread::sleep(Duration::from_millis(100));
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(format!(
                        "rr replay stderr closed before debugger port {port} was ready; stderr: {:?}",
                        startup_lines
                    )
                    .into());
                }
            }
            if !startup_lines.is_empty() && startup_lines.len() % 200 == 0 {
                startup_lines.drain(0..100);
            }
            if startup_lines.is_empty() {
                continue;
            }
        }

        Ok(Self {
            child: Some(child),
            stderr_thread: Some(stderr_thread),
        })
    }

    fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if let Some(thread) = self.stderr_thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for RrReplay {
    fn drop(&mut self) {
        self.stop();
    }
}

fn reserve_tcp_port() -> Result<u16, Box<dyn Error>> {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0))?;
    let port = listener.local_addr()?.port();
    drop(listener);
    Ok(port)
}

fn find_program_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn make_temp_dir(prefix: &str) -> Result<PathBuf, Box<dyn Error>> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("system clock before UNIX_EPOCH: {e}"))?;
    let dir = std::env::temp_dir().join(format!("{prefix}-{}-{}", std::process::id(), now.as_nanos()));
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn python_literal(path: &Path) -> Result<String, Box<dyn Error>> {
    serde_json::to_string(&path.to_string_lossy().to_string())
        .map_err(|e| format!("failed to encode path literal {}: {e}", path.display()).into())
}

fn collector_script(program: &Path, output: &Path) -> Result<String, Box<dyn Error>> {
    let program_literal = python_literal(program)?;
    let output_literal = python_literal(output)?;
    Ok(format!(
        r#"
import gdb
import json
import os
import re

PROGRAM = {program_literal}
OUTPUT = {output_literal}
PROGRAM_BASE = os.path.basename(PROGRAM)
MAX_STEPS = {MAX_STEPS}
MAX_RANGE_BYTES = {MAX_RANGE_BYTES}
MAX_TOTAL_SNAPSHOT_BYTES = {MAX_TOTAL_SNAPSHOT_BYTES}

writes = []
linehits = {{}}
file_ids = {{}}
diagnostics = []

def rr_tick(fallback):
    for command in ("monitor when", "when"):
        try:
            text = gdb.execute(command, to_string=True)
            match = re.search(r"ticks?[^0-9]*([0-9]+)", text, re.IGNORECASE)
            if match:
                return int(match.group(1))
            match = re.search(r"([0-9]+)", text)
            if match:
                return int(match.group(1))
        except Exception:
            pass
    return fallback

def add_linehit(pc, tick):
    try:
        sal = gdb.find_pc_line(pc)
        if sal is None or sal.symtab is None or sal.line <= 0:
            return
        path = sal.symtab.fullname()
        file_id = file_ids.setdefault(path, len(file_ids) + 1)
        key = "%d:%d" % (file_id, sal.line)
        linehits.setdefault(key, {{"file_id": file_id, "line": sal.line, "ticks": []}})["ticks"].append(tick)
    except Exception as exc:
        if len(diagnostics) < 20:
            diagnostics.append("linehit failed: %s" % exc)

def parse_mappings():
    mappings = []
    total = 0

    def maybe_add(start, end, perms, path):
        nonlocal total
        size = end - start
        if size <= 0 or size > MAX_RANGE_BYTES:
            return
        if total + size > MAX_TOTAL_SNAPSHOT_BYTES:
            return
        total += size
        mappings.append((start, end, perms, path))

    def include_mapping(perms, path):
        if perms and "w" not in perms:
            return False
        return (
            os.path.basename(path) == PROGRAM_BASE
            or path.startswith("[heap]")
            or path.startswith("[stack]")
            or path == ""
        )

    try:
        pid = gdb.selected_inferior().pid
    except Exception:
        pid = 0
    if not pid:
        pass
    else:
        maps_path = "/proc/%d/maps" % pid
        try:
            with open(maps_path, "r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    parts = line.strip().split(None, 5)
                    if len(parts) < 2:
                        continue
                    bounds = parts[0]
                    perms = parts[1]
                    path = parts[5] if len(parts) >= 6 else ""
                    start_s, end_s = bounds.split("-", 1)
                    maybe_add(int(start_s, 16), int(end_s, 16), perms, path)
        except Exception:
            pass
    if mappings:
        return mappings

    try:
        text = gdb.execute("info proc mappings", to_string=True)
        for line in text.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            if not parts[0].startswith("0x") or not parts[1].startswith("0x"):
                continue
            path = parts[-1] if len(parts) >= 5 else ""
            perms = ""
            for part in parts[2:]:
                if re.fullmatch(r"[rwxps-]+", part):
                    perms = part
                    break
            start = int(parts[0], 16)
            end = int(parts[1], 16)
            maybe_add(start, end, perms, path)
    except Exception as exc:
        if len(diagnostics) < 20:
            diagnostics.append("info proc mappings failed: %s" % exc)
    return mappings

def data_ranges():
    ranges = []
    for start, end, perms, path in parse_mappings():
        if perms and "w" not in perms:
            continue
        if (
            os.path.basename(path) == PROGRAM_BASE
            or path.startswith("[heap]")
            or path.startswith("[stack]")
            or path == ""
        ):
            ranges.append((start, end))
    return ranges

def executable_ranges():
    ranges = []
    for start, end, perms, path in parse_mappings():
        if os.path.basename(path) != PROGRAM_BASE:
            continue
        if perms and "x" not in perms:
            continue
        ranges.append((start, end))
    return ranges

USER_EXEC_RANGES = []

def in_user_code(pc):
    if not USER_EXEC_RANGES:
        return True
    for start, end in USER_EXEC_RANGES:
        if start <= pc < end:
            return True
    return False

def current_pc():
    return int(gdb.selected_frame().pc())

def return_to_user_code():
    for _ in range(64):
        try:
            pc = current_pc()
        except Exception:
            return False
        if in_user_code(pc):
            return True
        try:
            gdb.execute("finish", to_string=True)
        except Exception as exc:
            if len(diagnostics) < 20:
                diagnostics.append("finish stopped: %s" % exc)
            return False
    if len(diagnostics) < 20:
        diagnostics.append("finish guard exhausted outside user code")
    return False

def snapshot():
    inferior = gdb.selected_inferior()
    out = {{}}
    for start, end in data_ranges():
        try:
            out[start] = bytes(inferior.read_memory(start, end - start))
        except Exception:
            pass
    return out

def value_from(buf):
    value = 0
    for index, byte in enumerate(buf[:8]):
        value |= int(byte) << (index * 8)
    return value

def diff_snapshots(before, after, tick, pc):
    for start, old in before.items():
        new = after.get(start)
        if new is None:
            continue
        limit = min(len(old), len(new))
        index = 0
        while index < limit:
            if old[index] == new[index]:
                index += 1
                continue
            end = index + 1
            while end < limit and old[end] != new[end] and end - index < 8:
                end += 1
            writes.append({{
                "tick": tick,
                "pc": pc,
                "address": start + index,
                "size": end - index,
                "old_value": value_from(old[index:end]),
                "new_value": value_from(new[index:end]),
            }})
            index = end

def run():
    global USER_EXEC_RANGES
    try:
        gdb.execute("break main", to_string=True)
        gdb.execute("continue", to_string=True)
    except Exception as exc:
        diagnostics.append("failed to reach main: %s" % exc)
        return

    USER_EXEC_RANGES = executable_ranges()
    for step in range(MAX_STEPS):
        try:
            pc = current_pc()
        except Exception:
            break
        if not in_user_code(pc):
            if not return_to_user_code():
                break
            pc = current_pc()
        tick = rr_tick(step)
        add_linehit(pc, tick)
        before = snapshot()
        try:
            gdb.execute("stepi", to_string=True)
        except Exception as exc:
            diagnostics.append("stepi stopped at %d: %s" % (step, exc))
            break
        after = snapshot()
        diff_snapshots(before, after, tick, pc)
        try:
            if not in_user_code(current_pc()):
                return_to_user_code()
        except Exception:
            break
    else:
        diagnostics.append("step limit reached: %d" % MAX_STEPS)

run()
with open(OUTPUT, "w", encoding="utf-8") as handle:
    json.dump({{
        "writes": writes,
        "linehits": list(linehits.values()),
        "diagnostics": diagnostics,
    }}, handle)
"#
    ))
}
