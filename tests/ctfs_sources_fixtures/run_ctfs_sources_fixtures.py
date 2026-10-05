"""Generate native protocol fixtures through real declared producers. No mocks.

All containers are generated in owned scratch. No committed .ct files, network
recordings, paid API calls, external source edits, or copied build artifacts.
"""

from pathlib import Path
import hashlib, json, os, shutil, stat, subprocess, tempfile, time
import psutil

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent
FORMAT = Path(os.environ["CODETRACER_CTFS_FIXTURE_FORMAT_SRC"]).resolve()
NIM_SOURCE = Path(os.environ["CODETRACER_CTFS_FIXTURE_NIM_SRC"]).resolve()
PYTHON = Path(os.environ["CODETRACER_PYTHON_CMD"]).resolve()
RECORDER = Path(os.environ["CODETRACER_CTFS_FIXTURE_PYTHON_RECORDER"]).resolve()
TOOLS = {name: Path(shutil.which(name) or "").resolve() for name in ("cargo", "nim")}
SAMPLE = (
    Path(os.environ["CODETRACER_CTFS_FIXTURE_PYTHON_SRC"])
    / "cross-repo/samples/launcher_compat_sample.py"
)
assert FORMAT.is_dir() and NIM_SOURCE.is_dir() and SAMPLE.is_file()
assert PYTHON.is_file() and os.access(PYTHON, os.X_OK)
assert RECORDER.is_file() and os.access(RECORDER, os.X_OK)
assert all(path.is_file() and os.access(path, os.X_OK) for path in TOOLS.values())


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inventory(root):
    result = {}
    for path in sorted(root.rglob("*")):
        if ".git" in path.relative_to(root).parts:
            continue
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            result[str(path.relative_to(root))] = {
                "kind": "link",
                "target": os.readlink(path),
                "mode": stat.S_IMODE(info.st_mode),
            }
        elif stat.S_ISREG(info.st_mode):
            result[str(path.relative_to(root))] = {
                "kind": "regular",
                "sha256": sha(path),
                "mode": stat.S_IMODE(info.st_mode),
            }
    return result


source = inventory(FORMAT)
for name, item in source.items():
    if item["kind"] == "link":
        target = (FORMAT / name).resolve(strict=True)
        assert target.is_relative_to(FORMAT), (
            "fixture source symlink escapes declared input: " + name
        )
sample_hash = sha(SAMPLE)
lock_hash = sha(ROOT / "flake.lock")
stage = subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=ROOT)
owner_files = {
    name: {
        "sha256": sha(ROOT / name),
        "mode": stat.S_IMODE((ROOT / name).lstat().st_mode),
    }
    for name in ("src/ct/trace/ctfs_sources.nim", "tests/ctfs_v5_schema6_sources.nim")
}
inputs = {
    "format_source": str(FORMAT),
    "format_files": source,
    "nim_source": str(NIM_SOURCE),
    "nim_files": inventory(NIM_SOURCE),
    "recorder": str(RECORDER),
    "recorder_sha256": sha(RECORDER),
    "tools": {
        name: {"path": str(path), "sha256": sha(path)} for name, path in TOOLS.items()
    },
    "python": str(PYTHON),
    "python_sha256": sha(PYTHON),
    "sample": str(SAMPLE),
    "sample_sha256": sample_hash,
    "own_stage_sha256": hashlib.sha256(stage).hexdigest(),
    "owner_files": owner_files,
    "own_lock_sha256": lock_hash,
    "driver_sha256": sha(__file__),
}
(ROOT / ".repro").mkdir(exist_ok=True)
scratch = Path(tempfile.mkdtemp(prefix="ctfs-source-fixtures-", dir=ROOT / ".repro"))
report = {
    "inputs": inputs,
    "commands": [],
    "scope": "real current producer/importer fixtures; not full UI/backend/launcher or container6 qualification",
}


def save():
    (scratch / "receipt.json").write_text(json.dumps(report, indent=2) + "\n")


def session_members(sid):
    result = []
    for process in psutil.process_iter(["pid", "uids"]):
        try:
            if os.getsid(process.pid) != sid:
                continue
            if process.status() == psutil.STATUS_ZOMBIE:
                continue
            result.append(
                {"pid": process.pid, "created": process.create_time(), "sid": sid}
            )
        except (ProcessLookupError, psutil.NoSuchProcess):
            continue
        except (PermissionError, psutil.AccessDenied):
            uid = process.info.get("uids")
            if uid is not None and uid.real != os.getuid():
                continue
            raise
    return result


def run(argv, cwd, label):
    row = {"argv": argv, "cwd": str(cwd), "label": label}
    report["commands"].append(row)
    save()
    with (scratch / (label + ".log")).open("w") as output:
        child = subprocess.Popen(
            argv,
            cwd=cwd,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        sid = os.getsid(child.pid)
        row.update(
            pid=child.pid, sid=sid, created=psutil.Process(child.pid).create_time()
        )
        save()
        try:
            while True:
                try:
                    row["exit"] = child.wait()
                    break
                except (KeyboardInterrupt, InterruptedError):
                    continue
        finally:
            while child.poll() is None:
                try:
                    child.wait()
                except (KeyboardInterrupt, InterruptedError):
                    continue
            while True:
                row["remaining_owned_session"] = session_members(sid)
                save()
                if not row["remaining_owned_session"]:
                    break
                try:
                    time.sleep(0.1)
                except (KeyboardInterrupt, InterruptedError):
                    continue
        row["log_sha256"] = sha(scratch / (label + ".log"))
        save()
    assert row["exit"] == 0, label


try:
    copied = scratch / "format-source"
    copied.mkdir()
    for name, item in source.items():
        destination = copied / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        if item["kind"] == "link":
            destination.symlink_to(item["target"])
        else:
            shutil.copy2(FORMAT / name, destination)
    assert inventory(copied) == source
    members = scratch / "members"
    members.mkdir()
    metadata = scratch / "metadata"
    metadata.mkdir()
    recording = scratch / "recording"
    recording.mkdir()
    native = scratch / "native"
    native.mkdir()
    examples = [
        ("codetracer_ctfs", "ctfs_member_fixture.rs"),
        ("codetracer_trace_writer", "ctfs_metadata_fixture.rs"),
    ]
    for crate, name in examples:
        destination = copied / crate / "examples" / name
        destination.parent.mkdir(exist_ok=True)
        shutil.copy2(FIXTURES / name, destination)
    run(
        [str(RECORDER), "--out-dir", str(recording), "--require-trace", str(SAMPLE)],
        ROOT,
        "real-python-producer",
    )
    traces = list(recording.glob("*.ct"))
    assert len(traces) == 1, "real producer must create exactly one container"
    for crate, name in examples:
        args = (
            [str(members)]
            if crate == "codetracer_ctfs"
            else [str(metadata), str(traces[0])]
        )
        run(
            [
                str(TOOLS["cargo"]),
                "run",
                "--locked",
                "--manifest-path",
                str(copied / "Cargo.toml"),
                "-p",
                crate,
                "--example",
                Path(name).stem,
                "--target-dir",
                str(scratch / "rust-target"),
                "--",
                *args,
            ],
            ROOT,
            crate,
        )
    run(
        [
            str(TOOLS["nim"]),
            "c",
            "-r",
            "--nimcache:" + str(scratch / "nimcache"),
            "--out:" + str(scratch / "test-ctfs-sources"),
            "--path:src/ct/trace",
            "--path:" + str(NIM_SOURCE),
            "tests/ctfs_v5_schema6_sources.nim",
            str(members),
            str(metadata),
            str(native),
            str(traces[0]),
        ],
        ROOT,
        "own-native-importer",
    )
finally:
    assert inventory(FORMAT) == source
    assert inventory(NIM_SOURCE) == inputs["nim_files"]
    assert sha(SAMPLE) == sample_hash and sha(ROOT / "flake.lock") == lock_hash
    assert (
        sha(RECORDER) == inputs["recorder_sha256"]
        and sha(PYTHON) == inputs["python_sha256"]
    )
    assert all(
        sha(path) == inputs["tools"][name]["sha256"] for name, path in TOOLS.items()
    )
    assert (
        subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=ROOT) == stage
    )
    assert all(
        sha(ROOT / name) == item["sha256"]
        and stat.S_IMODE((ROOT / name).lstat().st_mode) == item["mode"]
        for name, item in owner_files.items()
    )
    report["source_restored"] = True
    report["artifacts"] = {
        str(p.relative_to(scratch)): {"sha256": sha(p), "bytes": p.stat().st_size}
        for p in scratch.rglob("*")
        if p.is_file()
        and "format-source" not in p.relative_to(scratch).parts
        and "rust-target" not in p.relative_to(scratch).parts
        and "nimcache" not in p.relative_to(scratch).parts
        and p.name != "receipt.json"
    }
    for name in ("format-source", "rust-target", "nimcache"):
        owned = scratch / name
        if owned.exists():
            shutil.rmtree(owned)
    report["disposable_source_and_build_scratch_removed"] = True
    save()
    print(scratch / "receipt.json")
