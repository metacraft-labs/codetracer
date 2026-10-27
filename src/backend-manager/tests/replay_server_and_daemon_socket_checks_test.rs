//! Two checks that turn a confusing timeout into a named cause.
//!
//! * The MCP test harnesses (`tests/support/mcp_harness.rs`, shared by the
//!   source-reading tests and `mcp_dive_in_fetch_gateway_test.rs`) refuse a
//!   `replay-server` older than the source it is built from, the one named by
//!   `CODETRACER_REPLAY_SERVER_CMD` included.  A stale binary does not answer
//!   a launch argument the daemon learned after it was built, and the test
//!   then times out waiting for `ct/open-trace` instead of saying why.
//! * The daemon refuses to bind a socket path longer than a Unix socket
//!   address holds (`sockaddr_un.sun_path`, unix(7)) with an error naming the
//!   path and the limit, and the harness reports the daemon's exit with that
//!   error instead of "the daemon socket never appeared".
//!
//! What is real: the freshness check runs against files whose modification
//! times the test sets, once through a cargo dep-info file (the list cargo
//! itself rebuilds from, used whenever one is beside the binary) and once
//! through the manifest scan it falls back to, in a directory laid out as
//! db-backend is (path dependencies of path dependencies, an optional
//! grammar the default features enable, its C sources outside its binding
//! crate); and against the real db-backend of this checkout.  The socket check
//! runs the production `session-manager daemon start`.  Nothing stands in
//! for a component: the "binary" whose age is checked is a plain file,
//! because the check reads only its modification time.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

#[path = "support/mcp_harness.rs"]
mod mcp_harness;

use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime};

use tokio::process::Command;

fn write_at(path: &Path, when: SystemTime) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, b"x").unwrap();
    set_time(path, when);
}

fn set_time(path: &Path, when: SystemTime) {
    File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(when)
        .unwrap();
}

/// A tree laid out as db-backend's: `crate/` whose manifest names a required
/// path dependency `../dep` (which itself depends on `../inner`), a build
/// dependency `../built`, a grammar binding `../grammar/bindings/rust` that
/// is optional but enabled by the default features through a chain of two
/// features (its C source is in `grammar/src`, outside the binding crate), an
/// optional `../opt` no default feature enables, and a dev-dependency.
fn source_tree(root: &Path, base: SystemTime) -> PathBuf {
    let krate = root.join("crate");
    write_at(&krate.join("src/main.rs"), base);
    write_at(&krate.join("src/nested/mod.rs"), base);
    write_at(&krate.join("build.rs"), base);
    write_at(&krate.join("Cargo.lock"), base);
    fs::write(
        krate.join("Cargo.toml"),
        "[package]\nname = \"x\"\n\n[build-dependencies]\nbuilt = { path = \"../built\" }\n\n\
         [dependencies]\ndep = { path = \"../dep\" }\n\
         grammar = { path = \"../grammar/bindings/rust\", optional = true }\n\
         opt = { path = \"../opt\", optional = true }\n\n\
         [dev-dependencies]\ntesting = { path = \"../testing\" }\n\n\
         [features]\ndefault = [\"highlight\"]\nhighlight = [\n  \"grammars\",\n]\n\
         grammars = [\"dep:grammar\"]\nextra = [\"dep:opt\"]\n\n[[bin]]\npath = \"src/main.rs\"\n",
    )
    .unwrap();
    set_time(&krate.join("Cargo.toml"), base);
    write_at(&root.join("dep/src/lib.rs"), base);
    fs::write(
        root.join("dep/Cargo.toml"),
        "[package]\nname = \"dep\"\n\n[dependencies]\ninner = { path = \"../inner\" }\n",
    )
    .unwrap();
    set_time(&root.join("dep/Cargo.toml"), base);
    write_at(&root.join("inner/src/lib.rs"), base);
    write_at(&root.join("built/src/lib.rs"), base);
    write_at(&root.join("grammar/bindings/rust/lib.rs"), base);
    write_at(&root.join("grammar/bindings/rust/Cargo.toml"), base);
    write_at(&root.join("grammar/src/parser.c"), base);
    write_at(&root.join("grammar/src/scanner.c"), base);
    write_at(&root.join("opt/src/lib.rs"), base);
    write_at(&root.join("testing/src/lib.rs"), base);
    krate
}

fn refusal_names(refusal: &str, binary: &Path, changed: &Path) {
    assert!(
        refusal.contains(&changed.display().to_string()),
        "{refusal}"
    );
    assert!(refusal.contains(&binary.display().to_string()), "{refusal}");
    assert!(
        refusal.contains("cargo build --bin replay-server"),
        "{refusal}"
    );
}

#[test]
fn without_dep_info_the_manifest_scan_refuses_a_binary_older_than_any_input() {
    let dir = tempfile::tempdir().unwrap();
    let base = SystemTime::now() - Duration::from_secs(3600);
    let krate = source_tree(dir.path(), base);
    let binary = dir.path().join("bin/replay-server");
    let server = dir.path().join("bin/session-manager");
    let later = base + Duration::from_secs(120);

    // Built after its source: accepted, as found beside the server and as
    // named explicitly.
    write_at(&binary, base + Duration::from_secs(60));
    assert_eq!(
        mcp_harness::locate_replay_server(None, &server, &krate).unwrap(),
        binary.canonicalize().unwrap()
    );
    assert_eq!(
        mcp_harness::locate_replay_server(Some(binary.clone()), &server, &krate).unwrap(),
        binary
    );
    let (source, inputs) = mcp_harness::replay_server_inputs(&binary, &krate).unwrap();
    assert_eq!(source, mcp_harness::InputSource::ManifestScan);

    // Each file the binary is built from, changed after it: refused, naming
    // that file, whichever way the binary was found.
    for changed in [
        krate.join("src/nested/mod.rs"),
        krate.join("build.rs"),
        krate.join("Cargo.toml"),
        krate.join("Cargo.lock"),
        dir.path().join("dep/src/lib.rs"),
        dir.path().join("inner/src/lib.rs"),
        dir.path().join("built/src/lib.rs"),
        dir.path().join("grammar/bindings/rust/lib.rs"),
        dir.path().join("grammar/src/parser.c"),
        dir.path().join("grammar/src/scanner.c"),
    ] {
        let changed = changed.canonicalize().unwrap();
        assert!(
            inputs.contains(&changed),
            "{} is not among the inputs: {inputs:?}",
            changed.display()
        );
        set_time(&changed, later);
        for explicit in [None, Some(binary.clone())] {
            let refusal = mcp_harness::locate_replay_server(explicit.clone(), &server, &krate)
                .expect_err(&format!(
                    "a binary older than {} was accepted ({explicit:?})",
                    changed.display()
                ));
            assert!(
                matches!(refusal, mcp_harness::ReplayServerRefusal::Stale(_)),
                "{refusal:?}"
            );
            let refusal = refusal.to_string();
            assert!(refusal.contains("is older than its source"), "{refusal}");
            refusal_names(&refusal, &binary, &changed);
        }
        set_time(&changed, base);
        assert!(
            mcp_harness::locate_replay_server(None, &server, &krate).is_ok(),
            "restored {}",
            changed.display()
        );
    }

    // Negative control: what the binary is not built from does not count:
    // an optional dependency no default feature enables, a dev-dependency.
    for unrelated in [
        dir.path().join("opt/src/lib.rs"),
        dir.path().join("testing/src/lib.rs"),
    ] {
        set_time(&unrelated, later);
        assert!(
            mcp_harness::locate_replay_server(None, &server, &krate).is_ok(),
            "{} made the binary stale",
            unrelated.display()
        );
    }

    // A binary exactly as old as its newest input (a Nix build, where every
    // time is the epoch) is current.
    set_time(&binary, base);
    for unrelated in [
        dir.path().join("opt/src/lib.rs"),
        dir.path().join("testing/src/lib.rs"),
    ] {
        set_time(&unrelated, base);
    }
    assert!(mcp_harness::check_replay_server_fresh(&binary, &krate).is_ok());

    // An explicit path that is not a file is a failure, not a fallback; none
    // built anywhere is the one refusal a test may skip on.
    let missing = dir.path().join("bin/absent");
    let refusal =
        mcp_harness::locate_replay_server(Some(missing.clone()), &server, &krate).unwrap_err();
    assert!(
        matches!(refusal, mcp_harness::ReplayServerRefusal::NotAFile(_)),
        "{refusal:?}"
    );
    assert!(
        refusal.to_string().contains(&missing.display().to_string()),
        "{refusal}"
    );
    fs::remove_file(&binary).unwrap();
    let refusal = mcp_harness::locate_replay_server(None, &server, &krate).unwrap_err();
    assert!(
        matches!(refusal, mcp_harness::ReplayServerRefusal::NotBuilt(_)),
        "{refusal:?}"
    );
}

#[test]
fn cargo_dep_info_is_the_authoritative_input_list() {
    let dir = tempfile::tempdir().unwrap();
    let base = SystemTime::now() - Duration::from_secs(3600);
    let krate = source_tree(dir.path(), base);
    let bin_dir = dir.path().join("target/debug");
    let binary = bin_dir.join("replay-server");
    let server = dir.path().join("elsewhere/session-manager");
    write_at(&binary, base + Duration::from_secs(60));
    // A grammar source outside every crate's src/, a file whose name has a
    // space (cargo writes it as `\ `), and a crate source file.
    let outside = dir.path().join("vendor/grammar/parser.c");
    let spaced = dir.path().join("vendor/with space.h");
    write_at(&outside, base);
    write_at(&spaced, base);
    let listed_source = krate.join("src/main.rs");
    let escaped = |p: &Path| p.display().to_string().replace(' ', "\\ ");
    fs::write(
        bin_dir.join("replay-server.d"),
        format!(
            "{}: {} {} {}\n{}/other: {}\n",
            escaped(&binary),
            escaped(&listed_source),
            escaped(&outside),
            escaped(&spaced),
            bin_dir.display(),
            escaped(&dir.path().join("opt/src/lib.rs")),
        ),
    )
    .unwrap();

    let (source, inputs) = mcp_harness::replay_server_inputs(&binary, &krate).unwrap();
    assert_eq!(source, mcp_harness::InputSource::DepInfo);
    assert_eq!(
        inputs,
        vec![listed_source.clone(), outside.clone(), spaced.clone()]
    );
    assert!(mcp_harness::locate_replay_server(Some(binary.clone()), &server, &krate).is_ok());

    // Every listed file, changed after the build: refused, naming it.
    for changed in [&listed_source, &outside, &spaced] {
        set_time(changed, base + Duration::from_secs(120));
        let refusal = mcp_harness::check_replay_server_fresh(&binary, &krate).unwrap_err();
        assert!(refusal.contains("cargo's dep-info"), "{refusal}");
        refusal_names(&refusal, &binary, changed);
        set_time(changed, base);
    }

    // The dep-info file decides: a file it does not list (here a crate
    // source the manifest scan would count, and the other rule's input)
    // changing is not a refusal.
    for unlisted in [
        krate.join("src/nested/mod.rs"),
        dir.path().join("opt/src/lib.rs"),
    ] {
        set_time(&unlisted, base + Duration::from_secs(120));
        assert!(
            mcp_harness::check_replay_server_fresh(&binary, &krate).is_ok(),
            "{} is not in the dep-info file",
            unlisted.display()
        );
    }

    // A listed input that is gone counts as changed, as it does for cargo.
    fs::remove_file(&spaced).unwrap();
    let refusal = mcp_harness::check_replay_server_fresh(&binary, &krate).unwrap_err();
    assert!(refusal.contains("no longer exists"), "{refusal}");
    assert!(refusal.contains(&spaced.display().to_string()), "{refusal}");
}

#[test]
fn without_dep_info_or_db_backend_source_the_candidate_is_used_as_found() {
    let dir = tempfile::tempdir().unwrap();
    let binary = dir.path().join("replay-server");
    write_at(&binary, SystemTime::UNIX_EPOCH + Duration::from_secs(1));
    assert!(
        mcp_harness::replay_server_inputs(&binary, &dir.path().join("no-such-crate")).is_none()
    );
    assert!(
        mcp_harness::check_replay_server_fresh(&binary, &dir.path().join("no-such-crate")).is_ok()
    );
}

#[test]
fn the_real_db_backend_inputs_include_its_grammars() {
    let db_backend = mcp_harness::db_backend_dir();
    let manifest = fs::read_to_string(db_backend.join("Cargo.toml"))
        .expect("db-backend's manifest in this checkout");
    let deps = mcp_harness::built_path_dependencies(&manifest);
    // The default features (syntax-highlight, nim-reader) enable every
    // optional grammar and the Nim trace writer; the dev-only DAP client is
    // not built into replay-server.
    for expected in [
        "libs/ct-open-beneath",
        "codetracer_trace_reader",
        "libs/tree-sitter-nim/bindings/rust",
        "libs/tree-sitter-cairo",
        "libs/tree-sitter-cadence/bindings/rust",
        "tree-sitter-trace/",
        "codetracer_trace_writer_nim",
    ] {
        assert!(
            deps.iter().any(|d| d.ends_with(expected)),
            "{expected} missing from {deps:?}"
        );
    }
    assert!(
        !deps.iter().any(|d| d.contains("ct-dap-client")),
        "{deps:?}"
    );

    // The manifest scan of the real crate reaches a grammar's C source
    // outside its binding crate (no binary here, so no dep-info file).
    let nowhere = tempfile::tempdir().unwrap();
    let (source, inputs) =
        mcp_harness::replay_server_inputs(&nowhere.path().join("replay-server"), &db_backend)
            .expect("db-backend has source files");
    assert_eq!(source, mcp_harness::InputSource::ManifestScan);
    let parser = db_backend
        .join("../../libs/tree-sitter-nim/src/parser.c")
        .canonicalize()
        .expect("tree-sitter-nim's parser.c in this checkout");
    assert!(inputs.contains(&parser), "{} not scanned", parser.display());

    // Cargo's own record, when this checkout has built replay-server: it is
    // the list used, and it names the same grammar source.
    let built = db_backend.join("target/debug/replay-server");
    if built.with_file_name("replay-server.d").exists() {
        let (source, inputs) = mcp_harness::replay_server_inputs(&built, &db_backend).unwrap();
        assert_eq!(source, mcp_harness::InputSource::DepInfo);
        assert!(inputs.len() > 100, "{} inputs", inputs.len());
        assert!(
            inputs
                .iter()
                .any(|i| i.canonicalize().ok().as_ref() == Some(&parser)),
            "cargo's dep-info does not list {}",
            parser.display()
        );
    } else {
        eprintln!(
            "note: no in-tree replay-server build; the dep-info arm on the real crate was not run"
        );
    }
}

/// A path of exactly `len` bytes under a short directory, ending `.sock`.
fn socket_path_of_length(dir: &Path, len: usize) -> PathBuf {
    let prefix = dir.join("s").as_os_str().len();
    assert!(
        prefix + 5 < len,
        "the test directory {} is too long for this check",
        dir.display()
    );
    let path = dir.join(format!("{}{}", "s".repeat(len - prefix - 5 + 1), ".sock"));
    assert_eq!(path.as_os_str().len(), len);
    path
}

#[cfg(unix)]
#[tokio::test]
async fn the_daemon_names_a_socket_path_longer_than_sun_path() {
    let max = mcp_harness::MAX_UNIX_SOCKET_PATH;
    let (_root, root) = mcp_harness::short_root("ctsock");
    let server = mcp_harness::server_binary();

    let start = |socket: &Path, stderr: &Path| {
        Command::new(&server)
            .args(["daemon", "start"])
            .env("TMPDIR", &root)
            .env("CODETRACER_HOME", root.join("home"))
            .env("CODETRACER_DAEMON_SOCKET", socket)
            .stdout(Stdio::null())
            .stderr(File::create(stderr).unwrap())
            .kill_on_drop(true)
            .spawn()
            .expect("start the daemon")
    };

    // One byte past the limit: the daemon exits, naming the path and the
    // limit, and the harness reports that rather than a timeout.
    let long = socket_path_of_length(&root, max + 1);
    let stderr_log = root.join("long.stderr");
    let mut daemon = start(&long, &stderr_log);
    let status = tokio::time::timeout(Duration::from_secs(15), daemon.wait())
        .await
        .expect("the daemon kept running with a socket path it cannot bind")
        .unwrap();
    assert!(!status.success(), "the daemon exited 0");
    let stderr = fs::read_to_string(&stderr_log).unwrap();
    assert!(stderr.contains(&long.display().to_string()), "{stderr}");
    assert!(
        stderr.contains("sun_path")
            && stderr.contains(&format!("{} bytes", max + 1))
            && stderr.contains(&format!("the {max} a socket address holds")),
        "{stderr}"
    );
    assert!(!long.exists());

    let mut daemon = start(&long, &stderr_log);
    let (long_for_wait, log_for_wait) = (long.clone(), stderr_log.clone());
    let waited = tokio::spawn(async move {
        mcp_harness::wait_for_daemon_socket(&mut daemon, &long_for_wait, &log_for_wait).await;
    })
    .await;
    let message = waited
        .expect_err("the harness waited for a socket the daemon cannot bind")
        .into_panic();
    let message = message
        .downcast_ref::<String>()
        .cloned()
        .or_else(|| message.downcast_ref::<&str>().map(|s| (*s).to_owned()))
        .unwrap_or_default();
    assert!(
        message.contains("exited")
            && message.contains("sun_path")
            && message.contains(&long.display().to_string()),
        "{message}"
    );
    assert!(mcp_harness::socket_path_note(&long).contains("sun_path"));

    // Negative control: exactly at the limit, the daemon binds it.
    let fits = socket_path_of_length(&root, max);
    let stderr_log = root.join("fits.stderr");
    let mut daemon = start(&fits, &stderr_log);
    mcp_harness::wait_for_daemon_socket(&mut daemon, &fits, &stderr_log).await;
    assert!(!mcp_harness::socket_path_note(&fits).contains("sun_path"));
    let _ = std::process::Command::new(&server)
        .args(["daemon", "stop"])
        .env("TMPDIR", &root)
        .env("CODETRACER_HOME", root.join("home"))
        .env("CODETRACER_DAEMON_SOCKET", &fits)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = daemon.start_kill();
}
