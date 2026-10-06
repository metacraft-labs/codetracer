"""Reconcile only the checkout-owned recorder environment; retain every attempt.

This uses real interpreter/module/filesystem principals, not mock environments.
The shell calls this with its declared interpreter and original source branch.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import traceback
import tomllib

import psutil


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def directory(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise RuntimeError(f"Not an owned regular directory: {path}")
    return info


def ancestors(path):
    for parent in reversed((path, *path.parents)):
        if not stat.S_ISDIR(parent.lstat().st_mode):
            raise RuntimeError(f"Linked/non-directory ancestry: {parent}")


def inventory(root):
    directory(root)
    result = {}
    for parent, directories, files in os.walk(root, followlinks=False):
        for name in sorted(directories + files):
            path = Path(parent) / name
            info = path.lstat()
            if info.st_uid != os.getuid():
                raise RuntimeError(f"Foreign member: {path}")
            entry = dict(mode=stat.S_IMODE(info.st_mode), inode=info.st_ino,
                         dev=info.st_dev, uid=info.st_uid)
            if stat.S_ISREG(info.st_mode):
                entry.update(kind="file", size=info.st_size, sha256=digest(path))
            elif stat.S_ISDIR(info.st_mode):
                entry.update(kind="directory")
            elif stat.S_ISLNK(info.st_mode):
                entry.update(kind="link", target=os.readlink(path))
            else:
                raise RuntimeError(f"Nonregular member: {path}")
            result[str(path.relative_to(root))] = entry
    return result


def validate_existing(root):
    members = inventory(root)
    if members.get("pyvenv.cfg", {}).get("kind") != "file":
        raise RuntimeError("Missing regular pyvenv.cfg")
    config = {}
    for line in (root / "pyvenv.cfg").read_text().splitlines():
        key, separator, value = line.partition(" = ")
        if not separator or key in config:
            raise RuntimeError("Malformed/duplicate virtual environment configuration")
        config[key] = value
    if set(config) != {"home", "include-system-site-packages", "version", "executable", "command"}:
        raise RuntimeError("Unexpected virtual environment configuration")
    home = Path(config["home"])
    if not str(home).startswith("/nix/store/") or home.name != "bin":
        raise RuntimeError("Unrecognized interpreter home")
    if config["include-system-site-packages"] != "true":
        raise RuntimeError("Missing declared system-site-packages constructor")
    python = str(home / "python3")
    if config["command"] != f"{python} -m venv --system-site-packages {root}":
        raise RuntimeError("Environment was not constructed for this checkout")
    executable = Path(config["executable"])
    if executable.parent != home or not executable.name.startswith("python3."):
        raise RuntimeError("Unexpected base executable")
    version = config["version"].split(".")
    if len(version) != 3 or any(not part.isdecimal() for part in version):
        raise RuntimeError("Malformed Python version")
    expected_links = {"bin/python": "python3", "bin/python3": python,
                      f"bin/python{version[0]}.{version[1]}": "python3"}
    if "lib64" in members:
        expected_links["lib64"] = "lib"
    actual_links = {name: entry["target"] for name, entry in members.items()
                    if entry["kind"] == "link"}
    if actual_links != expected_links:
        raise RuntimeError("Unexpected environment link inventory")
    return members


PROBE = """import hashlib,json,pathlib,stat,sys
import codetracer_python_recorder.codetracer_python_recorder as m
p=pathlib.Path(m.__file__).resolve()
members={}
for q in sorted(p.parent.rglob('*')):
    info=q.lstat()
    if stat.S_ISREG(info.st_mode):
        members[str(q.relative_to(p.parent))]=dict(mode=stat.S_IMODE(info.st_mode),
             sha256=hashlib.sha256(q.read_bytes()).hexdigest())
    elif not stat.S_ISDIR(info.st_mode):
        raise RuntimeError('Unexpected module principal member: '+str(q))
print(json.dumps(dict(base=sys.base_prefix,version=list(sys.version_info[:3]),
                     module=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),
                     packageMembers=members)))
"""


def probe(python, work, report, name, required=True):
    row = run([str(python), "-I", "-B", "-c", PROBE], work, report, name,
              required=required)
    if row["exit"]:
        return None
    return json.loads((work / f"{name}.stdout").read_text())



PURE_FILES = ("trace.py", "codetracer_pure_python_recorder/__init__.py",
              "codetracer_pure_python_recorder/cli.py")


def pure_source_principal(source):
    ancestors(source)
    if not stat.S_ISDIR(source.lstat().st_mode):
        raise RuntimeError("Nonregular declared pure source directory")
    declaration = source / "pyproject.toml"
    if not stat.S_ISREG(declaration.lstat().st_mode):
        raise RuntimeError("Nonregular pure package declaration")
    project = tomllib.loads(declaration.read_text())["project"]
    files = {}
    for name in PURE_FILES:
        path = source / "src" / name
        ancestors(path.parent)
        if not stat.S_ISREG(path.lstat().st_mode):
            raise RuntimeError("Nonregular declared pure module: " + name)
        files[name] = digest(path)
    return dict(name=project["name"], version=project["version"],
                scripts=project["scripts"], files=files,
                declarationSha256=digest(declaration))


PURE_PROBE = """import hashlib,importlib.metadata as metadata,json,pathlib,stat
import codetracer_pure_python_recorder as package
import codetracer_pure_python_recorder.cli as cli
names=['trace.py','codetracer_pure_python_recorder/__init__.py',
       'codetracer_pure_python_recorder/cli.py']
dist=metadata.distribution('codetracer-pure-python-recorder')
files={}
paths={}
for name in names:
    path=pathlib.Path(dist.locate_file(name)).resolve()
    if not stat.S_ISREG(path.lstat().st_mode):
        raise RuntimeError('Nonregular installed pure module: '+name)
    paths[name]=path
    files[name]=hashlib.sha256(path.read_bytes()).hexdigest()
if pathlib.Path(package.__file__).resolve()!=paths[names[1]] or pathlib.Path(cli.__file__).resolve()!=paths[names[2]]:
    raise RuntimeError('Imported pure package differs from installed distribution')
scripts={entry.name:entry.value for entry in dist.entry_points if entry.group=='console_scripts'}
print(json.dumps(dict(name=dist.metadata['Name'],version=dist.version,
                     scripts=scripts,files=files)))
"""


def pure_principal(python, work, report, name, required=True):
    row = run([str(python), "-I", "-B", "-c", PURE_PROBE], work, report,
              name, required=required)
    if row["exit"]:
        return None
    return json.loads((work / f"{name}.stdout").read_text())


def pure_matches(actual, expected):
    return actual is not None and all(actual[key] == expected[key]
                                     for key in ("name", "version", "scripts", "files"))


def natural_wait(child):
    while True:
        try:
            return child.wait()
        except KeyboardInterrupt:
            continue


def session_members(sid, birth, report):
    members = []
    unknown = []
    try:
        processes = list(psutil.process_iter())
    except Exception as error:
        report["lifecycleUnverified"] = True
        report.setdefault("sessionCensusFailures", []).append(
            dict(sid=sid, error=repr(error), traceback=traceback.format_exc()))
        raise RuntimeError("Cannot enumerate processes to verify owned session drainage") from error
    for process in processes:
        observed_sid = None
        try:
            observed_sid = os.getsid(process.pid)
            if observed_sid != sid:
                continue
            uid = process.uids().real
            created = process.create_time()
            if birth is not None and created < birth:
                continue
            if process.status() != psutil.STATUS_ZOMBIE:
                members.append(dict(pid=process.pid, sid=observed_sid,
                                    uid=uid, created=created))
        except (psutil.NoSuchProcess, ProcessLookupError):
            continue
        except (psutil.AccessDenied, PermissionError) as error:
            observation = dict(pid=process.pid, error=str(error))
            try:
                observation["uid"] = process.uids().real
                observation["created"] = process.create_time()
                if observed_sid != sid and (observation["uid"] != os.getuid() or (
                        birth is not None and observation["created"] < birth)):
                    observation["excluded"] = True
                    report.setdefault("inaccessibleExcluded", []).append(observation)
                    continue
            except (psutil.AccessDenied, PermissionError) as nested:
                observation["principalError"] = str(nested)
            except (psutil.NoSuchProcess, ProcessLookupError):
                continue
            unknown.append(observation)
    if unknown:
        report.setdefault("unclassifiedProcesses", []).extend(unknown)
        # Drain every known owned descendant before refusing an ambiguous
        # boundary. Never mutate the environment or release its lock on refusal.
        if not members:
            report["lifecycleUnverified"] = True
            raise RuntimeError("Cannot exclude inaccessible processes from owned session")
    return members


def run(argv, work, report, name, required=True):
    with (work / f"{name}.stdout").open("wb") as output, (
            work / f"{name}.stderr").open("wb") as errors:
        child = subprocess.Popen(argv, stdout=output, stderr=errors,
                                 start_new_session=True)
        row = dict(argv=argv, pid=child.pid, sid=child.pid)
        report["commands"].append(row)
        try:
            row["created"] = psutil.Process(child.pid).create_time()
        except psutil.NoSuchProcess:
            row["identityAlreadyTerminal"] = True
        except (psutil.AccessDenied, PermissionError) as error:
            row["identityUnverified"] = repr(error)
            report["lifecycleUnverified"] = True
        finally:
            row["exit"] = natural_wait(child)
            while True:
                try:
                    remaining = session_members(child.pid, row.get("created"), report)
                    if not remaining:
                        break
                    time.sleep(0.25)
                except KeyboardInterrupt:
                    continue
            row["remaining"] = remaining
    row["stdoutSha256"] = digest(work / f"{name}.stdout")
    row["stderrSha256"] = digest(work / f"{name}.stderr")
    if report.get("lifecycleUnverified"):
        raise RuntimeError("Owned command identity or lifecycle could not be verified")
    if row["exit"] and required:
        raise RuntimeError(f"Original {name} command failed: {row['exit']}")
    return row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("python", type=Path)
    parser.add_argument("branch", choices=["pure", "rust"])
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    root = Path(os.path.abspath(args.root))
    ancestors(root)
    directory(root)
    if not args.python.is_absolute() or not args.python.is_file():
        raise RuntimeError("Missing declared absolute interpreter")
    environment = root / ".python-recorder-venv"
    state = root / ".repro"
    if not state.exists():
        state.mkdir(mode=0o700)
    directory(state)
    ancestors(state)
    lock = state / "python-recorder-venv.lock"
    work = Path(tempfile.mkdtemp(prefix="python-recorder-venv-", dir=state))
    report = dict(commands=[], root=str(root), branch=args.branch,
                  source=str(args.source), helperSha256=digest(Path(__file__)),
                  pythonSha256=digest(args.python))
    created_environment = None
    quarantine_created = False
    qualified_environment = None
    qualified_root = None
    previous = None
    fd = None
    lock_identity = None
    try:
        fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        lock_identity = os.fstat(fd)
        os.write(fd, json.dumps(dict(pid=os.getpid(), work=str(work))).encode())
        pure_desired = pure_source_principal(args.source) if args.branch == "pure" else None
        report["pureDesired"] = pure_desired
        desired = probe(args.python, work, report, "declared-principal")
        report["desired"] = desired
        if ".".join(map(str, desired["version"][:2])) != os.environ["CODETRACER_PYTHON_VERSION"]:
            raise RuntimeError("Declared interpreter does not match declared Python version")

        def sdk_guard(name):
            if args.branch == "pure" and pure_source_principal(args.source) != pure_desired:
                raise RuntimeError("Declared pure source principal changed")
            if digest(args.python) != report["pythonSha256"] or (
                    digest(Path(__file__)) != report["helperSha256"]):
                raise RuntimeError("Selected interpreter/helper bytes changed")
            if probe(args.python, work, report, name) != desired:
                raise RuntimeError("Selected SDK principal changed")

        previous = None
        if os.path.lexists(environment):
            previous = validate_existing(environment)
            report["before"] = previous
            current = probe(environment / "bin/python", work, report,
                            "existing-principal", required=False)
            pure_ready = args.branch != "pure" or pure_matches(
                pure_principal(environment / "bin/python", work, report,
                               "existing-pure-principal", required=False), pure_desired)
            if current == desired and pure_ready and ".broken" not in previous:
                if validate_existing(environment) != previous:
                    raise RuntimeError("Environment changed during warm verification")
                qualified_environment = previous
                qualified_root = environment.lstat()
                sdk_guard("warm-final-declared-principal")
                report["result"] = "CURRENT-REUSED"
                return str(environment / "bin/python")
            if validate_existing(environment) != previous:
                raise RuntimeError("Environment changed before quarantine")
            if environment.stat().st_dev != work.stat().st_dev:
                raise RuntimeError("Quarantine is not on the owning filesystem")
            sdk_guard("prequarantine-declared-principal")
            if validate_existing(environment) != previous:
                raise RuntimeError("Environment changed at quarantine boundary")
            os.rename(environment, work / "original-venv")
            quarantine_created = True
            if inventory(work / "original-venv") != previous:
                raise RuntimeError("Quarantine inventory mismatch")
        # Acquire the replacement directory exclusively before invoking the
        # unchanged venv constructor. An existing path is never adopted.
        environment.mkdir(mode=0o700)
        created_environment = environment.lstat()
        run([str(args.python), "-m", "venv", "--system-site-packages", str(environment)],
            work, report, "venv")
        # The declared Nix interpreter may already expose the exact recorder
        # principal through system-site-packages. Retain that immutable principal
        # instead of shadowing it with a second locally compiled Rust extension.
        inherited = probe(environment / "bin/python", work, report,
                          "constructed-declared-principal", required=False)
        if args.branch == "rust" and inherited == desired:
            report["constructorRecorder"] = "declared-sdk-system-site-package"
        else:
            run([str(environment / "bin/pip"), "install", "--quiet", str(args.source)],
                work, report, "install")
            report["constructorRecorder"] = "original-source-install"
        validate_existing(environment)
        actual = probe(environment / "bin/python", work, report, "replacement-principal")
        report["actual"] = actual
        if actual != desired:
            raise RuntimeError("Replacement recorder/interpreter principal differs from declared SDK")
        if args.branch == "pure":
            pure_actual = pure_principal(environment / "bin/python", work, report,
                                         "replacement-pure-principal")
            report["pureActual"] = pure_actual
            if not pure_matches(pure_actual, pure_desired):
                raise RuntimeError("Installed pure package differs from declared source principal")
        if previous is not None and inventory(work / "original-venv") != previous:
            raise RuntimeError("Original quarantine changed")
        qualified_environment = validate_existing(environment)
        qualified_root = environment.lstat()
        sdk_guard("replacement-final-declared-principal")
        report["result"] = "RECONCILED"
    except BaseException:
        report["result"] = "UNAVAILABLE"
        report["failure"] = traceback.format_exc()
        if report.get("lifecycleUnverified"):
            report["partialPreservedWithoutMarker"] = str(environment)
            report["lockRetainedForUnverifiedLifecycle"] = str(lock)
            raise
        if created_environment is not None:
            current = environment.lstat()
            if (current.st_dev, current.st_ino, current.st_uid, stat.S_IFMT(current.st_mode)) != (
                    created_environment.st_dev, created_environment.st_ino,
                    os.getuid(), stat.S_IFDIR):
                raise RuntimeError("Partial environment ownership changed; no marker written")
            marker = environment / ".broken"
            marker_fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(marker_fd, "w") as stream:
                stream.write(report["failure"])
        raise
    finally:
        final_error = None
        try:
            if report.get("result") in ("CURRENT-REUSED", "RECONCILED"):
                try:
                    current_root = directory(environment)
                    if qualified_root is None or (
                            current_root.st_dev, current_root.st_ino, current_root.st_uid) != (
                            qualified_root.st_dev, qualified_root.st_ino, qualified_root.st_uid):
                        raise RuntimeError("Final qualified environment root identity changed")
                    if validate_existing(environment) != qualified_environment:
                        raise RuntimeError("Final qualified environment inventory changed")
                    report["finalEnvironmentQualified"] = True
                except BaseException:
                    report["result"] = "UNAVAILABLE"
                    report["finalEnvironmentError"] = traceback.format_exc()
                    final_error = RuntimeError("Final qualified environment missing, changed or unverifiable")
            if os.path.lexists(environment):
                try:
                    report["retainedEnvironment"] = inventory(environment)
                except BaseException:
                    report["retainedEnvironmentError"] = traceback.format_exc()
                    report["result"] = "UNAVAILABLE"
                    final_error = RuntimeError("Final environment inventory could not be verified")
            if quarantine_created:
                try:
                    report["quarantinePreserved"] = inventory(work / "original-venv") == previous
                except BaseException:
                    report["quarantinePreserved"] = False
                    report["retainedQuarantineError"] = traceback.format_exc()
                if not report["quarantinePreserved"]:
                    report["result"] = "UNAVAILABLE"
                    final_error = RuntimeError("Final original quarantine inventory changed or cannot be verified")
            (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        finally:
            if fd is not None:
                try:
                    observed = lock.lstat()
                    if not report.get("lifecycleUnverified") and (observed.st_ino, observed.st_dev) == (lock_identity.st_ino, lock_identity.st_dev):
                        lock.unlink()
                except FileNotFoundError:
                    pass
                finally:
                    os.close(fd)
        if final_error is not None:
            raise final_error
    return str(environment / "bin/python")


if __name__ == "__main__":
    print(main())
