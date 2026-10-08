//! No committed recording carries a credential.
//!
//! A recording captures the recorded process's environment (the stack's
//! `envp` and the `guest.env` member), its argv and its memory. One made
//! inside a CI job or a developer shell therefore carries that shell's tokens
//! unless it was recorded under a scrubbed environment, and committing it
//! publishes them. On 2026-10-03 three fixtures did exactly that with a CI
//! installation token (git's `AUTHORIZATION: basic` extraheader).
//!
//! [`every_committed_recording_is_free_of_credentials`] scans every `.ct` the
//! repository tracks, the example-recordings submodule included, as
//! `every_committed_recording_opens` lists them: the raw bytes, every member,
//! and every zstd frame found in either, decompressed (the snapshot pages and
//! the chunked tables are zstd frames). The planted-credential tests below
//! prove the gate catches each pattern, including one visible only after
//! decompression, and that it passes the look-alikes real recordings hold.
//!
//! The same patterns are checked when a fixture is produced, by
//! `codetracer-example-recordings/.github/scripts/ct_credential_scan.nim`.
//!
//! No mocks: containers are real CTFS images written by `write_minimal_ctfs`
//! and read back through `CtfsReader`.

// The planted fakes are split into fragments so the file carries no complete
// credential; cspell sees the fragments as words.
// cspell:ignore AKIA ATION AUTHORIZ caseless extraheader FAKEFAKEFAKE XAKIAABCDEFGHIJKLMNOP alikes

use std::io::Read;
use std::path::{Path, PathBuf};

use db_backend::ctfs_trace_reader::ctfs_container::{CtfsReader, write_minimal_ctfs};

const ZSTD_MAGIC: [u8; 4] = [0x28, 0xB5, 0x2F, 0xFD];
/// A single frame is not inflated past this, so a corrupt size cannot exhaust
/// memory; a fixture is far smaller.
const MAX_INFLATED: u64 = 1 << 30;

#[derive(Debug)]
struct Hit {
    location: String,
    pattern: &'static str,
}

fn run_len(data: &[u8], pos: usize, ok: impl Fn(u8) -> bool) -> usize {
    data[pos.min(data.len())..].iter().take_while(|b| ok(**b)).count()
}

fn starts_with_at(data: &[u8], pos: usize, lit: &[u8], caseless: bool) -> bool {
    data.len() >= pos + lit.len()
        && if caseless {
            data[pos..pos + lit.len()].eq_ignore_ascii_case(lit)
        } else {
            &data[pos..pos + lit.len()] == lit
        }
}

fn is_cred_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'=' | b'.' | b'_' | b'-' | b'~')
}

/// Every credential pattern in `data`. Kept in step with
/// `ct_credential_scan.nim` (see its header for the list and why each is
/// shaped as it is: a header NAME alone, as in nginx's own strings, is not a
/// match; a header with a scheme and a credential is).
fn find_credentials(data: &[u8], location: &str, hits: &mut Vec<Hit>) {
    let mut i = 0;
    while i < data.len() {
        let mut matched = 0usize;
        let mut pattern = "";
        if starts_with_at(data, i, b"gh", false)
            && data.len() > i + 3
            && matches!(data[i + 2], b'p' | b'o' | b'u' | b's' | b'r')
            && data[i + 3] == b'_'
        {
            let n = run_len(data, i + 4, |b| b.is_ascii_alphanumeric());
            if n >= 36 {
                matched = 4 + n;
                pattern = "GitHub token (gh?_)";
            }
        }
        if matched == 0 && starts_with_at(data, i, b"github_pat_", false) {
            let n = run_len(data, i + 11, |b| b.is_ascii_alphanumeric() || b == b'_');
            if n >= 22 {
                matched = 11 + n;
                pattern = "GitHub fine-grained token";
            }
        }
        if matched == 0 && starts_with_at(data, i, b"authorization:", true) {
            let mut p = i + 14;
            p += run_len(data, p, |b| b == b' ' || b == b'\t');
            for scheme in [&b"basic"[..], b"bearer", b"token"] {
                if starts_with_at(data, p, scheme, true) && data.get(p + scheme.len()) == Some(&b' ') {
                    let q = p + scheme.len() + 1;
                    let n = run_len(data, q, is_cred_char);
                    if n >= 8 {
                        matched = q + n - i;
                        pattern = "HTTP authorization header";
                    }
                    break;
                }
            }
        }
        if matched == 0 && starts_with_at(data, i, b"x-access-token:", true) {
            let n = run_len(data, i + 15, is_cred_char);
            if n >= 8 {
                matched = 15 + n;
                pattern = "git token user (x-access-token:)";
            }
        }
        if matched == 0 && starts_with_at(data, i, b"eC1hY2Nlc3MtdG9rZW4", false) {
            matched = 19 + run_len(data, i + 19, is_cred_char);
            pattern = "base64 of x-access-token: (a basic auth header)";
        }
        if matched == 0
            && (starts_with_at(data, i, b"AKIA", false) || starts_with_at(data, i, b"ASIA", false))
            && (i == 0 || !data[i - 1].is_ascii_alphanumeric())
            && run_len(data, i + 4, |b| b.is_ascii_uppercase() || b.is_ascii_digit()) == 16
        {
            matched = 20;
            pattern = "AWS access key id";
        }
        if matched == 0 && starts_with_at(data, i, b"-----BEGIN ", false) {
            let limit = data.len().min(i + 11 + 48);
            let mut p = i + 11;
            while p < limit && (data[p].is_ascii_uppercase() || data[p] == b' ') {
                if starts_with_at(data, p, b"PRIVATE KEY-----", false) {
                    matched = p + 16 - i;
                    pattern = "PEM private key";
                    break;
                }
                p += 1;
            }
        }
        if matched > 0 {
            hits.push(Hit {
                location: format!("{location} @{i}"),
                pattern,
            });
            i += matched;
        } else {
            i += 1;
        }
    }
}

/// Every zstd frame in `data`, decompressed and scanned (and the frames inside
/// it, to a small depth).
fn scan_zstd_frames(data: &[u8], location: &str, hits: &mut Vec<Hit>, depth: u32) {
    if depth > 2 {
        return;
    }
    let mut i = 0;
    while i + 4 <= data.len() {
        if data[i..i + 4] == ZSTD_MAGIC
            && let Ok(len) = zstd_safe::find_frame_compressed_size(&data[i..])
            && len > 0
        {
            let mut inflated = Vec::new();
            let decoded = zstd::stream::read::Decoder::new(&data[i..i + len])
                .and_then(|d| d.take(MAX_INFLATED).read_to_end(&mut inflated));
            if decoded.is_ok() {
                let label = format!("{location} zstd@{i}");
                find_credentials(&inflated, &label, hits);
                scan_zstd_frames(&inflated, &label, hits, depth + 1);
                i += len;
                continue;
            }
        }
        i += 1;
    }
}

fn scan_recording(bytes: Vec<u8>) -> Result<Vec<Hit>, String> {
    let mut hits = Vec::new();
    find_credentials(&bytes, "raw", &mut hits);
    scan_zstd_frames(&bytes, "raw", &mut hits, 0);
    let mut reader = CtfsReader::from_bytes(bytes).map_err(|e| format!("container: {e}"))?;
    let names: Vec<String> = reader.file_names().iter().map(|s| s.to_string()).collect();
    for name in names {
        let member = reader.read_file(&name).map_err(|e| format!("member {name}: {e}"))?;
        find_credentials(&member, &name, &mut hits);
        scan_zstd_frames(&member, &name, &mut hits, 0);
    }
    Ok(hits)
}

fn committed_recordings() -> Vec<PathBuf> {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let listed = std::process::Command::new("git")
        .args(["ls-files", "--recurse-submodules", "-z", "--", "*.ct"])
        .current_dir(&repo)
        .output()
        .expect("git ls-files runs");
    assert!(listed.status.success(), "git ls-files failed");
    listed
        .stdout
        .split(|b| *b == 0)
        .filter(|p| !p.is_empty())
        .map(|p| repo.join(String::from_utf8_lossy(p).as_ref()))
        .collect()
}

#[test]
fn every_committed_recording_is_free_of_credentials() {
    let files = committed_recordings();
    assert!(
        files.len() >= 20,
        "expected the committed .ct fixtures (more than 20 when this was written), found {}",
        files.len()
    );
    let mut dirty = Vec::new();
    for ct in &files {
        let bytes = std::fs::read(ct).unwrap_or_else(|e| panic!("{}: {e}", ct.display()));
        // A recording that predates the current container cannot be read
        // member by member; its raw bytes and frames are still scanned.
        let hits = match scan_recording(bytes.clone()) {
            Ok(hits) => hits,
            Err(_) => {
                let mut hits = Vec::new();
                find_credentials(&bytes, "raw", &mut hits);
                scan_zstd_frames(&bytes, "raw", &mut hits, 0);
                hits
            }
        };
        for h in hits {
            dirty.push(format!("{}: {}: {}", ct.display(), h.location, h.pattern));
        }
    }
    assert!(
        dirty.is_empty(),
        "committed recordings carry credentials (values withheld); re-record them under a \
         scrubbed environment (env -i) and treat the credential as leaked:\n  {}",
        dirty.join("\n  ")
    );
}

// ---------------------------------------------------------------------------
// The gate itself: planted fakes are caught, look-alikes are not.
//
// The fake tokens are assembled at run time, so this file carries no string a
// secret scanner would flag.

fn fake_github_token(kind: char) -> String {
    format!("gh{kind}_{}", "Fake0Token1For2The3Gate".repeat(2)[..36].to_owned())
}

fn fake_basic_header() -> String {
    // base64("x-access-token:" + fake), as git's extraheader carries it.
    format!(
        "{}{}",
        "AUTHORIZ", "ATION: basic eC1hY2Nlc3MtdG9rZW46Z2hzX0ZBS0VGQUtFRkFLRQ=="
    )
}

fn noise(n: usize, seed: u32) -> Vec<u8> {
    let mut x = seed.wrapping_mul(2_654_435_761).wrapping_add(12_345);
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            ((x & 0x7f) as u8) | 0x80 // never printable ASCII
        })
        .collect()
}

fn scan_planted(members: &[(&str, Vec<u8>)]) -> Vec<Hit> {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("planted.ct");
    let entries: Vec<(&str, &[u8])> = members.iter().map(|(n, b)| (*n, b.as_slice())).collect();
    write_minimal_ctfs(&path, &entries).expect("write planted container");
    scan_recording(std::fs::read(&path).expect("read planted container")).expect("scan planted container")
}

#[test]
fn the_gate_catches_the_leaked_environment_entry() {
    let env = format!("PATH=/usr/bin\0GIT_CONFIG_VALUE_0={}\0", fake_basic_header());
    let hits = scan_planted(&[("guest.env", env.into_bytes())]);
    assert!(
        hits.iter().any(|h| h.pattern == "HTTP authorization header"),
        "a git extraheader in guest.env was not caught: {hits:?}"
    );
}

#[test]
fn the_gate_catches_a_token_visible_only_after_decompression() {
    let mut plain = noise(8192, 3);
    plain.extend_from_slice(format!("GITHUB_TOKEN={}\0", fake_github_token('s')).as_bytes());
    plain.extend(noise(4096, 4));
    let compressed = zstd::bulk::compress(&plain, 3).expect("compress");
    assert!(
        !compressed.windows(4).any(|w| w == b"ghs_"),
        "test setup: the planted token is not hidden by compression"
    );
    let hits = scan_planted(&[("cppages.nzd", compressed)]);
    assert!(
        hits.iter()
            .any(|h| h.pattern == "GitHub token (gh?_)" && h.location.contains("zstd@")),
        "a token inside a compressed member was not caught: {hits:?}"
    );
}

#[test]
fn the_gate_catches_every_pattern() {
    let cases: Vec<(&str, String, &str)> = vec![
        ("ghp", format!("x\0{}\0", fake_github_token('p')), "GitHub token (gh?_)"),
        (
            "pat",
            format!("GH_TOKEN=github{}{}\0", "_pat_", "Ab1_".repeat(20)),
            "GitHub fine-grained token",
        ),
        (
            "aws",
            format!("AWS_ACCESS_KEY_ID={}{}FAKEFAKEFAKE0123\0", "AK", "IA"),
            "AWS access key id",
        ),
        (
            "pem",
            format!("-----BEGIN {} KEY-----\nAAAA\n", "OPENSSH PRIVATE"),
            "PEM private key",
        ),
        (
            "user",
            format!(
                "https://x-access{}{}@github.com/o/r",
                "-token:",
                &fake_github_token('s')[..12]
            ),
            "git token user (x-access-token:)",
        ),
    ];
    for (name, body, want) in cases {
        let hits = scan_planted(&[("guest.env", body.into_bytes())]);
        assert!(
            hits.iter().any(|h| h.pattern == want),
            "{name}: expected `{want}`, got {hits:?}"
        );
    }
}

#[test]
fn the_gate_passes_the_look_alikes_a_real_recording_holds() {
    let mut debug =
        b"Authorization\0Proxy-Authorization: \0x-access-token\0-----BEGIN CERTIFICATE-----\0XAKIAABCDEFGHIJKLMNOP\0"
            .to_vec();
    debug.extend(noise(3 * 4096, 1));
    let mut pages = b"Authorization: basic\0".to_vec();
    pages.extend(noise(4096, 2));
    let hits = scan_planted(&[
        ("guest.env", b"PATH=/usr/bin:/bin\0HOME=/nonexistent\0LANG=C\0".to_vec()),
        ("debug.dat", debug),
        ("cppages.nzd", zstd::bulk::compress(&pages, 3).expect("compress")),
    ]);
    assert!(hits.is_empty(), "a clean container was flagged: {hits:?}");
}
