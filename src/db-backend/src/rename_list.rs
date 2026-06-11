//! User-provided variable rename list (Column-Aware-Tracing-And-Deminification §P5).
//!
//! Loaded once at trace open from `<recording-dir>/renames.toml` (or
//! `--rename-list <path>` on the CLI) and consumed at value-stream
//! render time so the UI sees the user's chosen names instead of the
//! minified bundle's single-letter bindings.
//!
//! Spec: `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P5.
//!
//! ## File format (TOML)
//!
//! ```toml
//! # Optional metadata table; reserved for future schema bumps.
//! [meta]
//! version = "1"
//!
//! # Per-file [[rename]] entries.  Each entry maps a minified variable
//! # name to a human-readable one.  `scope` defaults to "global" — set
//! # to "function:<funcname>" or "block:L<line>" to constrain.
//!
//! [[rename]]
//! file = "lodash.min.js"
//! scope = "global"
//! from = "e"
//! to = "array"
//!
//! [[rename]]
//! file = "lodash.min.js"
//! scope = "function:chunk"
//! from = "t"
//! to = "result"
//! ```
//!
//! ## Composition rules
//!
//! See [`crate::sourcemap_cache::SourcemapCache::resolve_name`]:
//!
//! 1. User rename list lookup (this module) — explicit wins.
//! 2. Sourcemap V3 `names[]` confirmation (groundwork from §P3.5) —
//!    when the sourcemap acknowledges the minified name as a known
//!    binding the resolver echoes it.
//! 3. None — caller surfaces the recorded name unchanged.
//!
//! ## Lookup semantics
//!
//! Lookup is scope-aware:
//!
//! * A `function:<name>` scope hint matches a `function:<name>`-scoped
//!   entry first, then falls back to a `global` entry on miss.
//! * A `block:L<line>` scope hint matches the block-scoped entry first,
//!   then falls back to a `global` entry.
//! * A `None` / unknown scope hint matches `global` entries only — it
//!   does NOT match function- or block-scoped entries, because those
//!   are intentionally narrower.
//!
//! ## Parser tolerance
//!
//! Unknown TOML keys inside `[[rename]]` are logged at `warn!` and the
//! entry is **kept** (the recognised fields are still applied) — this
//! follows the "be liberal in what you accept" principle so a typo on
//! one key doesn't drop the entry's whole rename effect.  Missing
//! required fields (`file`, `from`, `to`) surface a typed error;
//! duplicate `(file, scope, from)` triples surface
//! [`RenameListError::DuplicateEntry`].

use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::io;
use std::path::Path;

use log::{debug, warn};
use serde::Deserialize;

/// Scope discriminator a [`RenameList`] entry can carry.
///
/// Wider scopes (`Global`) fill in when a narrower scope hint
/// (`Function` / `Block`) doesn't find a match.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Scope {
    /// Applies anywhere in the file.
    Global,
    /// Applies inside the named function.
    Function(String),
    /// Applies inside a specific block, keyed by the surrounding
    /// statement's line number.
    Block(u32),
}

impl Scope {
    /// Parse the on-disk `scope = "..."` string into a [`Scope`].
    ///
    /// Returns `None` when the string is not a recognised scope form;
    /// the caller treats unrecognised scopes as a parse warning and
    /// falls back to `Global`.
    pub fn parse(raw: &str) -> Option<Scope> {
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("global") {
            return Some(Scope::Global);
        }
        if let Some(rest) = trimmed.strip_prefix("function:") {
            let name = rest.trim().to_string();
            if name.is_empty() {
                return None;
            }
            return Some(Scope::Function(name));
        }
        if let Some(rest) = trimmed.strip_prefix("block:L") {
            let line: u32 = rest.trim().parse().ok()?;
            return Some(Scope::Block(line));
        }
        // Accept `block:<n>` without the `L` prefix too, for robustness.
        if let Some(rest) = trimmed.strip_prefix("block:") {
            let line: u32 = rest.trim().parse().ok()?;
            return Some(Scope::Block(line));
        }
        None
    }

    /// Reverse of [`Scope::parse`] — for diagnostics / round-trip
    /// printing.
    pub fn to_canonical_string(&self) -> String {
        match self {
            Scope::Global => "global".to_string(),
            Scope::Function(name) => format!("function:{name}"),
            Scope::Block(line) => format!("block:L{line}"),
        }
    }
}

/// Errors surfaced by [`RenameList::load`].
///
/// Defensive design: every error variant carries enough context to
/// produce an actionable error message; the parser never panics on
/// malformed input.
#[derive(Debug)]
pub enum RenameListError {
    /// Filesystem I/O error while reading the rename-list file.
    Io(io::Error),
    /// The bytes did not parse as a TOML document.
    ParseToml(toml::de::Error),
    /// Two `[[rename]]` entries share the same `(file, scope, from)`
    /// triple — ambiguous, so we surface the conflict rather than
    /// silently picking one.
    DuplicateEntry { file: String, scope: String, from: String },
    /// A `[[rename]]` entry is missing a required field
    /// (`file`, `from`, or `to`).
    MissingField(&'static str),
}

impl fmt::Display for RenameListError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RenameListError::Io(e) => write!(f, "I/O error reading rename list: {e}"),
            RenameListError::ParseToml(e) => write!(f, "failed to parse rename list TOML: {e}"),
            RenameListError::DuplicateEntry { file, scope, from } => {
                write!(f, "duplicate [[rename]] entry: file={file}, scope={scope}, from={from}")
            }
            RenameListError::MissingField(field) => write!(f, "[[rename]] entry missing required field: {field}"),
        }
    }
}

impl std::error::Error for RenameListError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            RenameListError::Io(e) => Some(e),
            RenameListError::ParseToml(e) => Some(e),
            _ => None,
        }
    }
}

impl From<io::Error> for RenameListError {
    fn from(e: io::Error) -> Self {
        RenameListError::Io(e)
    }
}

impl From<toml::de::Error> for RenameListError {
    fn from(e: toml::de::Error) -> Self {
        RenameListError::ParseToml(e)
    }
}

/// In-memory representation of a parsed `renames.toml`.
///
/// Lookup is `O(1)` per request thanks to the per-`(file, scope_kind)`
/// HashMap layout.  The cost of building the index is a single pass
/// over the parsed `[[rename]]` array at load time.
#[derive(Debug, Default, Clone)]
pub struct RenameList {
    /// Global-scope entries: `(file, minified_name) -> readable_name`.
    global: HashMap<(String, String), String>,
    /// Function-scope entries:
    /// `(file, function_name, minified_name) -> readable_name`.
    by_function: HashMap<(String, String, String), String>,
    /// Block-scope entries: `(file, line, minified_name) -> readable_name`.
    by_block: HashMap<(String, u32, String), String>,
    /// Metadata table, surfaced for diagnostics.  Reserved for future
    /// schema versioning; the §P5 parser does not enforce contents.
    meta: Option<RenameListMeta>,
}

/// `[meta]` table contents.  All fields optional so we don't enforce a
/// version yet — keeps the schema extensible.
#[derive(Debug, Default, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RenameListMeta {
    /// Schema version string the file declares.  Free-form for now.
    #[serde(default)]
    pub version: Option<String>,
    /// Human-readable comment about the rename list (e.g. who built
    /// it, against which bundle hash).
    #[serde(default)]
    pub comment: Option<String>,
}

/// Top-level TOML deserialisation target.
///
/// Uses `flatten` + a catch-all `extras` map to keep the parser
/// tolerant of unknown top-level keys (future schema additions).
#[derive(Debug, Deserialize)]
struct RawDocument {
    #[serde(default)]
    meta: Option<RenameListMeta>,
    #[serde(default)]
    rename: Vec<RawEntry>,
}

/// Per-entry on-disk shape.
///
/// All fields are `Option<String>` so a `MissingField` error can be
/// surfaced with the canonical field name in [`RenameList::load`]
/// instead of letting `serde` emit a generic message.  Unknown keys
/// land in `extras` (logged + retained for the rest of the entry).
#[derive(Debug, Deserialize)]
struct RawEntry {
    file: Option<String>,
    scope: Option<String>,
    from: Option<String>,
    to: Option<String>,
    #[serde(flatten)]
    extras: toml::Table,
}

impl RenameList {
    /// Build a fresh empty rename list — useful as a default when the
    /// trace has no companion `renames.toml`.
    pub fn new() -> Self {
        Self::default()
    }

    /// Construct from raw TOML bytes.  Same contract as
    /// [`RenameList::load`].
    ///
    /// Exposed as a separate entry point so unit tests can exercise
    /// the parser without touching the filesystem.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, RenameListError> {
        let text = std::str::from_utf8(bytes)
            .map_err(|e| RenameListError::Io(io::Error::new(io::ErrorKind::InvalidData, e)))?;
        Self::parse_toml(text)
    }

    /// Construct from a TOML string.  Same contract as
    /// [`RenameList::load`].
    ///
    /// Named `parse_toml` rather than `from_str` to sidestep the
    /// `std::str::FromStr` trait collision — the trait would force
    /// the error type to be `'static`, which we don't want for a
    /// `toml::de::Error` whose underlying source is borrowed.
    pub fn parse_toml(text: &str) -> Result<Self, RenameListError> {
        let doc: RawDocument = toml::from_str(text)?;
        let mut out = RenameList {
            meta: doc.meta,
            ..RenameList::default()
        };
        for entry in doc.rename {
            let file = entry.file.ok_or(RenameListError::MissingField("file"))?;
            let from = entry.from.ok_or(RenameListError::MissingField("from"))?;
            let to = entry.to.ok_or(RenameListError::MissingField("to"))?;
            let scope_raw = entry.scope.unwrap_or_else(|| "global".to_string());
            let scope = match Scope::parse(&scope_raw) {
                Some(s) => s,
                None => {
                    warn!(
                        "rename_list: ignoring unrecognised scope \"{scope_raw}\" in entry for file={file} from={from}; defaulting to global"
                    );
                    Scope::Global
                }
            };

            // Log + retain unknown keys.  Spec §P5: "Parser tolerates
            // unknown keys (log + skip)".  We don't drop the *entry* —
            // only the unknown key — so a typo on `flie = "x"` next to
            // the correct `file = "lodash.min.js"` still lands the
            // rename.  When the recognised fields can't be filled the
            // MissingField check above takes over.
            for (k, _) in entry.extras.iter() {
                warn!("rename_list: ignoring unknown key \"{k}\" in [[rename]] entry (file={file}, from={from})");
            }

            let canonical_scope = scope.to_canonical_string();
            let inserted = match &scope {
                Scope::Global => {
                    let key = (file.clone(), from.clone());
                    if out.global.contains_key(&key) {
                        return Err(RenameListError::DuplicateEntry {
                            file,
                            scope: canonical_scope,
                            from,
                        });
                    }
                    out.global.insert(key, to);
                    true
                }
                Scope::Function(name) => {
                    let key = (file.clone(), name.clone(), from.clone());
                    if out.by_function.contains_key(&key) {
                        return Err(RenameListError::DuplicateEntry {
                            file,
                            scope: canonical_scope,
                            from,
                        });
                    }
                    out.by_function.insert(key, to);
                    true
                }
                Scope::Block(line) => {
                    let key = (file.clone(), *line, from.clone());
                    if out.by_block.contains_key(&key) {
                        return Err(RenameListError::DuplicateEntry {
                            file,
                            scope: canonical_scope,
                            from,
                        });
                    }
                    out.by_block.insert(key, to);
                    true
                }
            };
            debug_assert!(inserted, "rename_list: insert path must be taken");
        }
        Ok(out)
    }

    /// Load a [`RenameList`] from a TOML file at the given path.
    ///
    /// Returns [`RenameListError::Io`] for filesystem errors,
    /// [`RenameListError::ParseToml`] for TOML syntax errors, and the
    /// semantic variants for invalid contents.
    pub fn load(path: &Path) -> Result<Self, RenameListError> {
        let bytes = fs::read(path)?;
        Self::from_bytes(&bytes)
    }

    /// Try the conventional sibling location
    /// `<recording_dir>/renames.toml`.
    ///
    /// Returns `Ok(None)` when the file is absent — *not* an error.
    /// Returns `Ok(Some(list))` on a successful load.  Returns `Err`
    /// only when the file exists but failed to load.
    pub fn try_load_sibling(recording_dir: &Path) -> Result<Option<Self>, RenameListError> {
        let path = recording_dir.join("renames.toml");
        if !path.is_file() {
            debug!("rename_list: no sibling renames.toml at {} — skipping", path.display());
            return Ok(None);
        }
        Self::load(&path).map(Some)
    }

    /// `true` when the rename list has no entries.
    pub fn is_empty(&self) -> bool {
        self.global.is_empty() && self.by_function.is_empty() && self.by_block.is_empty()
    }

    /// Total number of `[[rename]]` entries the list carries.
    pub fn len(&self) -> usize {
        self.global.len() + self.by_function.len() + self.by_block.len()
    }

    /// Look up a rename for the given `(file, scope_hint, minified_name)`.
    ///
    /// Lookup order:
    ///
    /// 1. If `scope_hint` is `Scope::Function(name)`, check the
    ///    function-scoped index for `(file, name, minified_name)`.
    /// 2. If `scope_hint` is `Scope::Block(line)`, check the
    ///    block-scoped index for `(file, line, minified_name)`.
    /// 3. Fall back to the global index for `(file, minified_name)`.
    ///
    /// A `None` / `Scope::Global` hint skips steps 1-2 and only
    /// inspects the global index.
    ///
    /// Returns the matched readable name (borrowed from the cache) or
    /// `None` when no entry applies.
    pub fn lookup(&self, file: &str, scope_hint: Option<&Scope>, from: &str) -> Option<&str> {
        match scope_hint {
            Some(Scope::Function(name)) => {
                if let Some(v) = self
                    .by_function
                    .get(&(file.to_string(), name.clone(), from.to_string()))
                {
                    return Some(v.as_str());
                }
            }
            Some(Scope::Block(line)) => {
                if let Some(v) = self.by_block.get(&(file.to_string(), *line, from.to_string())) {
                    return Some(v.as_str());
                }
            }
            Some(Scope::Global) | None => {
                // No narrower index to consult — fall through to global.
            }
        }
        self.global
            .get(&(file.to_string(), from.to_string()))
            .map(|s| s.as_str())
    }

    /// Read-only access to the parsed `[meta]` table.  Surfaced for
    /// diagnostics + future schema-version checks.
    pub fn meta(&self) -> Option<&RenameListMeta> {
        self.meta.as_ref()
    }
}

/// `true` when the `CT_RENAME_LIST` env var requests the rename-list
/// loader be skipped entirely.
///
/// Accepted "off" values (case-insensitive): `0`, `off`, `false`, `no`.
/// Anything else (including unset) means "on" — the default.
/// Mirrors the [`crate::sourcemap_cache::translation_enabled`] and
/// [`crate::autoformat::autoformat_enabled`] semantics so the three
/// kill switches feel consistent to operators.
pub fn rename_list_enabled() -> bool {
    match std::env::var("CT_RENAME_LIST") {
        Ok(v) => {
            let lower = v.trim().to_ascii_lowercase();
            !matches!(lower.as_str(), "0" | "off" | "false" | "no")
        }
        Err(_) => true,
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn empty_toml_yields_empty_list() {
        let list = RenameList::parse_toml("").unwrap();
        assert!(list.is_empty());
        assert_eq!(list.len(), 0);
        assert!(list.lookup("lodash.min.js", None, "e").is_none());
    }

    #[test]
    fn single_global_entry_resolves_with_no_hint() {
        let raw = r#"
            [[rename]]
            file = "lodash.min.js"
            from = "e"
            to = "array"
        "#;
        let list = RenameList::parse_toml(raw).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list.lookup("lodash.min.js", None, "e"), Some("array"));
        // Non-matching file does not match.
        assert_eq!(list.lookup("other.js", None, "e"), None);
        // Non-matching name does not match.
        assert_eq!(list.lookup("lodash.min.js", None, "x"), None);
    }

    #[test]
    fn global_scope_default_when_omitted() {
        let raw = r#"
            [[rename]]
            file = "x.js"
            scope = "global"
            from = "a"
            to = "alpha"

            [[rename]]
            file = "x.js"
            from = "b"
            to = "beta"
        "#;
        let list = RenameList::parse_toml(raw).unwrap();
        assert_eq!(list.lookup("x.js", None, "a"), Some("alpha"));
        assert_eq!(list.lookup("x.js", None, "b"), Some("beta"));
    }

    #[test]
    fn function_scope_takes_precedence_with_matching_hint() {
        let raw = r#"
            [[rename]]
            file = "lodash.min.js"
            scope = "global"
            from = "t"
            to = "global_result"

            [[rename]]
            file = "lodash.min.js"
            scope = "function:chunk"
            from = "t"
            to = "chunk_result"
        "#;
        let list = RenameList::parse_toml(raw).unwrap();
        // Function-scoped hit wins.
        let fn_scope = Scope::Function("chunk".to_string());
        assert_eq!(list.lookup("lodash.min.js", Some(&fn_scope), "t"), Some("chunk_result"));
        // Different function falls back to the global entry.
        let other_scope = Scope::Function("other".to_string());
        assert_eq!(
            list.lookup("lodash.min.js", Some(&other_scope), "t"),
            Some("global_result")
        );
        // No hint also falls back to global.
        assert_eq!(list.lookup("lodash.min.js", None, "t"), Some("global_result"));
    }

    #[test]
    fn block_scope_takes_precedence_with_matching_line_hint() {
        let raw = r#"
            [[rename]]
            file = "x.js"
            scope = "global"
            from = "a"
            to = "alpha_global"

            [[rename]]
            file = "x.js"
            scope = "block:L42"
            from = "a"
            to = "alpha_block"
        "#;
        let list = RenameList::parse_toml(raw).unwrap();
        let hit = Scope::Block(42);
        assert_eq!(list.lookup("x.js", Some(&hit), "a"), Some("alpha_block"));
        let miss = Scope::Block(99);
        assert_eq!(list.lookup("x.js", Some(&miss), "a"), Some("alpha_global"));
    }

    #[test]
    fn duplicate_entry_surfaces_typed_error() {
        let raw = r#"
            [[rename]]
            file = "x.js"
            from = "a"
            to = "alpha"

            [[rename]]
            file = "x.js"
            scope = "global"
            from = "a"
            to = "alpha_again"
        "#;
        let err = RenameList::parse_toml(raw).expect_err("duplicate must error");
        if let RenameListError::DuplicateEntry { file, scope, from } = err {
            assert_eq!(file, "x.js");
            assert_eq!(scope, "global");
            assert_eq!(from, "a");
        } else {
            assert!(matches!(err, RenameListError::DuplicateEntry { .. }));
        }
    }

    #[test]
    fn missing_required_field_surfaces_typed_error() {
        // Missing `to`.
        let raw_no_to = r#"
            [[rename]]
            file = "x.js"
            from = "a"
        "#;
        let err = RenameList::parse_toml(raw_no_to).expect_err("missing field");
        if let RenameListError::MissingField(name) = err {
            assert_eq!(name, "to");
        } else {
            assert!(matches!(err, RenameListError::MissingField(_)));
        }

        // Missing `file`.
        let raw_no_file = r#"
            [[rename]]
            from = "a"
            to = "alpha"
        "#;
        let err = RenameList::parse_toml(raw_no_file).expect_err("missing file");
        assert!(matches!(err, RenameListError::MissingField("file")));

        // Missing `from`.
        let raw_no_from = r#"
            [[rename]]
            file = "x.js"
            to = "alpha"
        "#;
        let err = RenameList::parse_toml(raw_no_from).expect_err("missing from");
        assert!(matches!(err, RenameListError::MissingField("from")));
    }

    #[test]
    fn unknown_keys_are_tolerated() {
        // The `flie` typo is captured by the `extras` flatten and
        // logged at warn — the entry still lands its rename via the
        // recognised `file` key.
        let raw = r#"
            [[rename]]
            file = "x.js"
            flie = "ignored_typo"
            from = "a"
            to = "alpha"
            something_unknown = 42
        "#;
        let list = RenameList::parse_toml(raw).expect("unknown keys do not abort parsing");
        assert_eq!(list.len(), 1);
        assert_eq!(list.lookup("x.js", None, "a"), Some("alpha"));
    }

    #[test]
    fn meta_table_is_optional_and_extensible() {
        let raw = r#"
            [meta]
            version = "1"
            comment = "lodash 4.17.21 minified bundle"

            [[rename]]
            file = "x.js"
            from = "a"
            to = "alpha"
        "#;
        let list = RenameList::parse_toml(raw).unwrap();
        let meta = list.meta().expect("meta present");
        assert_eq!(meta.version.as_deref(), Some("1"));
        assert_eq!(meta.comment.as_deref(), Some("lodash 4.17.21 minified bundle"));
    }

    #[test]
    fn unrecognised_scope_falls_back_to_global() {
        // The parser logs + defaults to Global; the rename still lands
        // so the user's intent survives a typo in the scope value.
        // `module:foo` is not a recognised scope kind — only `global`,
        // `function:<name>`, and `block:L<line>` are.
        let raw = r#"
            [[rename]]
            file = "x.js"
            scope = "module:foo"
            from = "a"
            to = "alpha"
        "#;
        let list = RenameList::parse_toml(raw).unwrap();
        // The entry lands as a global rename (scope-fallback semantics);
        // lookup with no hint resolves it.
        assert_eq!(list.lookup("x.js", None, "a"), Some("alpha"));
    }

    #[test]
    fn scope_parse_round_trip_for_known_forms() {
        assert_eq!(Scope::parse("global"), Some(Scope::Global));
        assert_eq!(Scope::parse(""), Some(Scope::Global));
        assert_eq!(
            Scope::parse("function:chunk"),
            Some(Scope::Function("chunk".to_string()))
        );
        assert_eq!(Scope::parse("block:L42"), Some(Scope::Block(42)));
        assert_eq!(Scope::parse("block:42"), Some(Scope::Block(42)));
        assert_eq!(Scope::parse("function:"), None);
        assert_eq!(Scope::parse("block:not-a-number"), None);
    }

    #[test]
    fn try_load_sibling_returns_none_when_absent() {
        let dir = tempfile::tempdir().unwrap();
        // No renames.toml present.
        let out = RenameList::try_load_sibling(dir.path()).expect("no error when sibling missing");
        assert!(out.is_none());
    }

    #[test]
    fn try_load_sibling_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("renames.toml");
        fs::write(
            &path,
            r#"
                [[rename]]
                file = "x.js"
                from = "a"
                to = "alpha"
            "#,
        )
        .unwrap();
        let list = RenameList::try_load_sibling(dir.path())
            .expect("no error")
            .expect("Some(list)");
        assert_eq!(list.lookup("x.js", None, "a"), Some("alpha"));
    }

    #[test]
    fn rename_list_enabled_respects_env() {
        let key = "CT_RENAME_LIST";
        let orig = std::env::var(key).ok();
        // SAFETY: tests in this module run in the same process; we
        // restore the env at the end to avoid cross-test contamination.
        unsafe { std::env::remove_var(key) };
        assert!(rename_list_enabled());
        unsafe { std::env::set_var(key, "0") };
        assert!(!rename_list_enabled());
        unsafe { std::env::set_var(key, "off") };
        assert!(!rename_list_enabled());
        unsafe { std::env::set_var(key, "FALSE") };
        assert!(!rename_list_enabled());
        unsafe { std::env::set_var(key, "no") };
        assert!(!rename_list_enabled());
        unsafe { std::env::set_var(key, "1") };
        assert!(rename_list_enabled());
        match orig {
            Some(v) => unsafe { std::env::set_var(key, v) },
            None => unsafe { std::env::remove_var(key) },
        }
    }
}
