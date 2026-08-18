//! A unified-diff reader for the materialized DeepReview collector.
//!
//! # Why here and not reused
//!
//! Three unified-diff readers already exist in the workspace and none of them
//! could be called from this crate:
//!
//! * `codetracer/src/ct/trace/multitrace.nim` (`parseDiff`) is Nim, private,
//!   and resolves every path against `git rev-parse --show-toplevel` of the
//!   *current* directory;
//! * `codetracer/src/frontend/ui/git_cli.nim` (`parseGitDiffHunks`) is Nim and
//!   runs in the renderer;
//! * `codetracer-native-backend/src/deepreview/algorithm.rs` is a different
//!   crate, and reaching it would put the rr backend back on the critical path
//!   of a Python review — the coupling `DeepReview-GUI.md` §1.1 forbids.
//!
//! So this is a fourth reader, and it is kept deliberately small: it reads the
//! parts of `git diff` output the review needs (which files, which hunks,
//! which line numbers) and ignores the rest (index lines, mode changes, binary
//! markers).  It produces the GUI's hunk shape directly so there is no second
//! translation between what was parsed and what is written.
//!
//! Format reference: <https://git-scm.com/docs/diff-format> ("Combined diff
//! format" is *not* supported — a review is over a two-way diff).

use super::json::{FileDiffData, HunkData, HunkLineData};

/// One file of a parsed patch.
#[derive(Debug, Clone, PartialEq)]
pub struct ParsedFile {
    /// Path on the base side, `""` for an added file.
    pub old_path: String,
    /// Path on the new side, `""` for a deleted file.
    pub new_path: String,
    /// The diff record the GUI reads, already in its final shape.
    pub diff: FileDiffData,
}

impl ParsedFile {
    /// The path a review names this file by: the new side when there is one
    /// (the reviewer is reading the code as it now is), the base side for a
    /// deletion.
    pub fn review_path(&self) -> &str {
        if !self.new_path.is_empty() {
            &self.new_path
        } else {
            &self.old_path
        }
    }

    /// New-side line numbers this file's diff touches — the lines a review is
    /// *about*.
    ///
    /// Added lines and context lines both count, and for the same reason
    /// `diff::index_diff` gives: a changed line may have no step of its own in
    /// the trace (a `}` , a declaration folded into another statement), and
    /// the surrounding context lines of the same hunk are what let the flow
    /// search find the enclosing call anyway.  Removed lines have no new-side
    /// position and cannot be executed.
    pub fn touched_new_lines(&self) -> Vec<u32> {
        let mut lines = vec![];
        for hunk in &self.diff.hunks {
            for line in &hunk.lines {
                if line.line_type != "removed" && line.new_line > 0 {
                    lines.push(line.new_line);
                }
            }
        }
        lines.sort_unstable();
        lines.dedup();
        lines
    }
}

/// A parsed patch.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ParsedDiff {
    pub files: Vec<ParsedFile>,
}

/// Strip git's `a/` / `b/` prefix from a `---` / `+++` path.
///
/// `/dev/null` becomes `""`, which is how an addition or a deletion is
/// spelled downstream.
fn strip_prefix(raw: &str) -> String {
    // git appends a tab and a timestamp for some diff flavours.
    let raw = raw.split('\t').next().unwrap_or(raw).trim_end();
    if raw == "/dev/null" {
        return String::new();
    }
    for prefix in ["a/", "b/", "i/", "w/", "c/", "o/"] {
        if let Some(rest) = raw.strip_prefix(prefix) {
            return rest.to_string();
        }
    }
    raw.to_string()
}

/// Parse `@@ -old_start[,old_count] +new_start[,new_count] @@ …`.
///
/// Returns `None` for a header that does not have that shape rather than
/// guessing, so a malformed patch loses one hunk instead of silently
/// misnumbering every line after it.
fn parse_hunk_header(line: &str) -> Option<(u32, u32, u32, u32)> {
    let rest = line.strip_prefix("@@ ")?;
    let end = rest.find(" @@")?;
    let ranges = &rest[..end];
    let mut parts = ranges.split_whitespace();
    let old = parts.next()?.strip_prefix('-')?;
    let new = parts.next()?.strip_prefix('+')?;

    fn split_range(range: &str) -> Option<(u32, u32)> {
        let mut it = range.split(',');
        let start: u32 = it.next()?.parse().ok()?;
        let count: u32 = match it.next() {
            Some(text) => text.parse().ok()?,
            // "@@ -5 +5 @@" means a one-line range.
            None => 1,
        };
        Some((start, count))
    }

    let (old_start, old_count) = split_range(old)?;
    let (new_start, new_count) = split_range(new)?;
    Some((old_start, old_count, new_start, new_count))
}

/// Decide a file's status from the two sides of its header plus its counts.
fn status_for(old_path: &str, new_path: &str) -> &'static str {
    if old_path.is_empty() {
        "A"
    } else if new_path.is_empty() {
        "D"
    } else if old_path != new_path {
        "R"
    } else {
        "M"
    }
}

/// Parse a unified diff.
///
/// Never fails: a patch this reader cannot make sense of yields fewer files,
/// and the collector reports how many files it found.  Refusing the whole
/// collection over one unrecognised header would be worse — the review would
/// vanish rather than shrink.
pub fn parse_unified_diff(patch: &str) -> ParsedDiff {
    let mut result = ParsedDiff::default();

    // The file currently being read, and the hunk currently being read.
    let mut old_path = String::new();
    let mut new_path = String::new();
    let mut hunks: Vec<HunkData> = vec![];
    let mut current: Option<HunkData> = None;
    let mut old_line = 0u32;
    let mut new_line = 0u32;
    let mut started = false;

    // Emit whatever has been accumulated so far as one file.
    fn flush(
        result: &mut ParsedDiff,
        started: &mut bool,
        old_path: &mut String,
        new_path: &mut String,
        hunks: &mut Vec<HunkData>,
        current: &mut Option<HunkData>,
    ) {
        if let Some(hunk) = current.take() {
            hunks.push(hunk);
        }
        if !*started {
            hunks.clear();
            return;
        }
        let mut lines_added = 0u32;
        let mut lines_removed = 0u32;
        for hunk in hunks.iter() {
            for line in &hunk.lines {
                match line.line_type.as_str() {
                    "added" => lines_added += 1,
                    "removed" => lines_removed += 1,
                    _ => {}
                }
            }
        }
        result.files.push(ParsedFile {
            old_path: old_path.clone(),
            new_path: new_path.clone(),
            diff: FileDiffData {
                status: status_for(old_path, new_path).to_string(),
                lines_added,
                lines_removed,
                hunks: std::mem::take(hunks),
            },
        });
        *started = false;
        old_path.clear();
        new_path.clear();
    }

    for line in patch.lines() {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            flush(
                &mut result,
                &mut started,
                &mut old_path,
                &mut new_path,
                &mut hunks,
                &mut current,
            );
            started = true;
            // `diff --git a/x b/x` carries the paths too, and it is the only
            // place they appear for a pure rename or a mode change (no `---`
            // / `+++` pair follows those).  Read them here and let a later
            // `---` / `+++` overwrite them.
            let mut parts = rest.split_whitespace();
            if let (Some(a), Some(b)) = (parts.next(), parts.next()) {
                old_path = strip_prefix(a);
                new_path = strip_prefix(b);
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("--- ") {
            if let Some(hunk) = current.take() {
                hunks.push(hunk);
            }
            started = true;
            old_path = strip_prefix(rest);
            continue;
        }
        if let Some(rest) = line.strip_prefix("+++ ") {
            new_path = strip_prefix(rest);
            continue;
        }
        if line.starts_with("@@ ") {
            if let Some(hunk) = current.take() {
                hunks.push(hunk);
            }
            match parse_hunk_header(line) {
                Some((old_start, old_count, new_start, new_count)) => {
                    old_line = old_start;
                    new_line = new_start;
                    current = Some(HunkData {
                        old_start,
                        old_count,
                        new_start,
                        new_count,
                        lines: vec![],
                    });
                }
                None => current = None,
            }
            continue;
        }
        let Some(hunk) = current.as_mut() else {
            continue;
        };
        // "\ No newline at end of file" annotates the previous line; it is not
        // a line of the file.
        if line.starts_with('\\') {
            continue;
        }
        let (kind, content) = match line.as_bytes().first() {
            Some(b'+') => ("added", &line[1..]),
            Some(b'-') => ("removed", &line[1..]),
            Some(b' ') => ("context", &line[1..]),
            // An empty line inside a hunk is a context line whose leading
            // space some tools drop.
            None => ("context", ""),
            _ => continue,
        };
        let (old_no, new_no) = match kind {
            "added" => {
                let n = new_line;
                new_line += 1;
                (0, n)
            }
            "removed" => {
                let o = old_line;
                old_line += 1;
                (o, 0)
            }
            _ => {
                let (o, n) = (old_line, new_line);
                old_line += 1;
                new_line += 1;
                (o, n)
            }
        };
        hunk.lines.push(HunkLineData {
            line_type: kind.to_string(),
            // The GUI renders `content` verbatim; the sample dataset shows
            // added/removed lines keeping their marker and context lines
            // keeping their leading space, so the raw line is passed through
            // for the changed kinds and the marker is dropped for context.
            content: if kind == "context" {
                content.to_string()
            } else {
                line.to_string()
            },
            old_line: old_no,
            new_line: new_no,
        });
    }

    flush(
        &mut result,
        &mut started,
        &mut old_path,
        &mut new_path,
        &mut hunks,
        &mut current,
    );
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    const MODIFY: &str = "\
diff --git a/src/main.rs b/src/main.rs
index 1111111..2222222 100644
--- a/src/main.rs
+++ b/src/main.rs
@@ -1,4 +1,5 @@
 fn main() {
-    let x = 1;
+    let x = 2;
+    let y = x + 1;
     println!(\"{}\", x);
 }
";

    #[test]
    fn reads_paths_status_and_counts() {
        let parsed = parse_unified_diff(MODIFY);
        assert_eq!(parsed.files.len(), 1);
        let file = &parsed.files[0];
        assert_eq!(file.old_path, "src/main.rs");
        assert_eq!(file.new_path, "src/main.rs");
        assert_eq!(file.review_path(), "src/main.rs");
        assert_eq!(file.diff.status, "M");
        assert_eq!(file.diff.lines_added, 2);
        assert_eq!(file.diff.lines_removed, 1);
    }

    #[test]
    fn numbers_both_sides_of_a_hunk() {
        let parsed = parse_unified_diff(MODIFY);
        let hunk = &parsed.files[0].diff.hunks[0];
        assert_eq!((hunk.old_start, hunk.old_count), (1, 4));
        assert_eq!((hunk.new_start, hunk.new_count), (1, 5));
        let numbered: Vec<(&str, u32, u32)> = hunk
            .lines
            .iter()
            .map(|l| (l.line_type.as_str(), l.old_line, l.new_line))
            .collect();
        assert_eq!(
            numbered,
            vec![
                ("context", 1, 1),
                ("removed", 2, 0),
                ("added", 0, 2),
                ("added", 0, 3),
                ("context", 3, 4),
                ("context", 4, 5),
            ]
        );
    }

    #[test]
    fn touched_lines_are_new_side_and_exclude_removals() {
        let parsed = parse_unified_diff(MODIFY);
        assert_eq!(parsed.files[0].touched_new_lines(), vec![1, 2, 3, 4, 5]);
    }

    #[test]
    fn an_added_file_has_no_base_side() {
        let patch = "\
diff --git a/new.py b/new.py
new file mode 100644
--- /dev/null
+++ b/new.py
@@ -0,0 +1,2 @@
+def f():
+    return 1
";
        let parsed = parse_unified_diff(patch);
        assert_eq!(parsed.files.len(), 1);
        assert_eq!(parsed.files[0].old_path, "");
        assert_eq!(parsed.files[0].diff.status, "A");
        assert_eq!(parsed.files[0].diff.lines_added, 2);
        assert_eq!(parsed.files[0].touched_new_lines(), vec![1, 2]);
    }

    #[test]
    fn a_deleted_file_has_no_new_side() {
        let patch = "\
diff --git a/gone.rb b/gone.rb
deleted file mode 100644
--- a/gone.rb
+++ /dev/null
@@ -1,2 +0,0 @@
-puts 1
-puts 2
";
        let parsed = parse_unified_diff(patch);
        assert_eq!(parsed.files[0].new_path, "");
        assert_eq!(parsed.files[0].review_path(), "gone.rb");
        assert_eq!(parsed.files[0].diff.status, "D");
        assert_eq!(parsed.files[0].diff.lines_removed, 2);
        assert!(parsed.files[0].touched_new_lines().is_empty());
    }

    #[test]
    fn several_files_and_several_hunks() {
        let patch = "\
diff --git a/a.js b/a.js
--- a/a.js
+++ b/a.js
@@ -1 +1 @@
-let a = 1;
+let a = 2;
@@ -10,2 +10,3 @@
 tail();
+more();
 end();
diff --git a/b.js b/b.js
--- a/b.js
+++ b/b.js
@@ -5,1 +5,1 @@
-old();
+new();
";
        let parsed = parse_unified_diff(patch);
        assert_eq!(parsed.files.len(), 2);
        assert_eq!(parsed.files[0].diff.hunks.len(), 2);
        // "@@ -1 +1 @@" — a range with no count is one line.
        assert_eq!(parsed.files[0].diff.hunks[0].old_count, 1);
        assert_eq!(parsed.files[0].touched_new_lines(), vec![1, 10, 11, 12]);
        assert_eq!(parsed.files[1].review_path(), "b.js");
    }

    #[test]
    fn a_rename_keeps_both_paths() {
        let patch = "\
diff --git a/old/name.py b/new/name.py
similarity index 90%
rename from old/name.py
rename to new/name.py
--- a/old/name.py
+++ b/new/name.py
@@ -1 +1 @@
-x = 1
+x = 2
";
        let parsed = parse_unified_diff(patch);
        assert_eq!(parsed.files[0].old_path, "old/name.py");
        assert_eq!(parsed.files[0].new_path, "new/name.py");
        assert_eq!(parsed.files[0].diff.status, "R");
    }

    #[test]
    fn an_empty_patch_yields_no_files() {
        assert!(parse_unified_diff("").files.is_empty());
        assert!(parse_unified_diff("\n\n").files.is_empty());
    }

    #[test]
    fn a_malformed_hunk_header_drops_only_that_hunk() {
        let patch = "\
diff --git a/x.rb b/x.rb
--- a/x.rb
+++ b/x.rb
@@ nonsense @@
+ignored
@@ -3,1 +3,2 @@
 kept
+added
";
        let parsed = parse_unified_diff(patch);
        assert_eq!(parsed.files.len(), 1);
        assert_eq!(parsed.files[0].diff.hunks.len(), 1);
        assert_eq!(parsed.files[0].diff.lines_added, 1);
        assert_eq!(parsed.files[0].touched_new_lines(), vec![3, 4]);
    }

    #[test]
    fn a_no_newline_marker_is_not_a_line() {
        let patch = "\
diff --git a/x.rb b/x.rb
--- a/x.rb
+++ b/x.rb
@@ -1,1 +1,1 @@
-a
\\ No newline at end of file
+b
\\ No newline at end of file
";
        let parsed = parse_unified_diff(patch);
        let hunk = &parsed.files[0].diff.hunks[0];
        assert_eq!(hunk.lines.len(), 2);
        assert_eq!(parsed.files[0].diff.lines_added, 1);
        assert_eq!(parsed.files[0].diff.lines_removed, 1);
    }

    #[test]
    fn a_patch_without_a_diff_git_line_still_reads() {
        // `diff -u` output, and what `git diff --no-prefix` looks like once a
        // tool has stripped the header.
        let patch = "\
--- src/a.py
+++ src/a.py
@@ -2,2 +2,3 @@
 def f():
+    log()
     return 1
";
        let parsed = parse_unified_diff(patch);
        assert_eq!(parsed.files.len(), 1);
        assert_eq!(parsed.files[0].review_path(), "src/a.py");
        assert_eq!(parsed.files[0].touched_new_lines(), vec![2, 3, 4]);
    }
}
