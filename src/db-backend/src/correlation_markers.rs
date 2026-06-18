//! M25 — Correlation markers (tracepoint-based; no protocol shims).
//!
//! Canonical spec:
//! [`codetracer-specs/GUI/Debugging-Features/Correlation-Markers.md`].
//! Milestone catalogue: M25 in
//! [`codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org`].
//!
//! # What this module owns
//!
//! - The [`MarkerDecl`] / [`MarkerDirection`] schema (§1 of the spec).
//!   The marker rides on the existing tracepoint event mechanism —
//!   **no new `TraceLowLevelEvent` variant is introduced**. The marker
//!   metadata travels alongside the tracepoint payload as
//!   `correlation_marker_id` + the marker fields.
//! - The comment scanner (§3.1) — turns a per-language `codetracer:`
//!   comment line into a `MarkerDecl`. The grammar itself is
//!   language-agnostic; per-language behaviour is the comment prefix
//!   the host language uses (table in §2.1 of the spec).
//! - The TOML authoring path (§2.3) — `.codetracer/correlation-markers.toml`
//!   produces the same [`MarkerDecl`] shape as the comment path.
//!
//! # What this module does NOT own
//!
//! - The hidden-tracepoint registration / source-location indexing
//!   work lives in [`crate::event_db`] (extended with a
//!   `(source_location, step)` lookup) and the production tracepoint
//!   evaluator. M25 reaches into the event_db via `MarkerPayload` —
//!   see [`MarkerPayload::encode`] for the on-the-wire shape.
//! - The pairing index (§3.3) lives in
//!   [`crate::correlation_index`]; it consumes `MarkerEventView`s
//!   built from cached tracepoint firings.
//! - The Event Log surface (§5) ships in M25b.
//!
//! # Per-language comment prefix table (spec §2.1)
//!
//! M25 ships the Python prefix end-to-end. The full per-language
//! table lives in [`LANGUAGE_COMMENT_PREFIXES`] so each subsequent
//! language addition is a 1-row change rather than a code-shape
//! change.

#![allow(clippy::expect_used)]

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Direction of a correlation marker. Spec §2: send-side fires before
/// a value crosses a boundary; recv-side fires when it lands on the
/// other side. Two markers pair when they share `(boundary_id, key)`
/// with opposite directions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MarkerDirection {
    Send,
    Recv,
}

impl MarkerDirection {
    /// Parse the `<direction>` token from a comment line or TOML
    /// entry. Spec §2.1 mandates lower-case `send` / `recv`; the
    /// parser is strict so a misspelled `Send` (capitalised) hits the
    /// skip-and-diagnose path rather than silently turning into a
    /// `Send` marker.
    pub fn parse(token: &str) -> Option<Self> {
        match token {
            "send" => Some(Self::Send),
            "recv" => Some(Self::Recv),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Send => "send",
            Self::Recv => "recv",
        }
    }

    /// Opposite-direction counterpart used by the pairing index when
    /// looking up the other side of a (boundary_id, key) match.
    pub fn opposite(self) -> Self {
        match self {
            Self::Send => Self::Recv,
            Self::Recv => Self::Send,
        }
    }
}

/// Optional render hint per spec §5.2. Currently accepted spellings:
/// `text`, `json`, `hex`, `summary:<n>`. We keep the spec form as a
/// `String` so M25b's Event Log renderer (which owns the actual
/// rendering rules) can re-parse without coupling.
pub type MarkerFormatSpec = String;

/// One declared correlation marker — the output of the scanner per
/// spec §3.1.  Source-location-keyed; the marker's hidden tracepoint
/// is registered at `(location.path, location.line)` by the M25
/// integration layer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MarkerDecl {
    pub boundary_id: String,
    pub direction: MarkerDirection,
    pub key_text: String,
    /// Optional separate display payload (§3.4). When `None` the
    /// renderer falls back to the key value.
    pub show_text: Option<String>,
    pub description: Option<String>,
    pub format: Option<MarkerFormatSpec>,
    pub location: MarkerLocation,
}

/// Source-location pin for a [`MarkerDecl`]. Kept as a separate type
/// from [`crate::task::SourceLocation`] so the marker schema can
/// evolve (e.g. carrying a column or a function name from the TOML
/// path) without touching every tracepoint consumer.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MarkerLocation {
    pub path: String,
    pub line: usize,
}

impl MarkerLocation {
    pub fn new(path: impl Into<String>, line: usize) -> Self {
        Self {
            path: path.into(),
            line,
        }
    }
}

/// Payload embedded in a tracepoint firing for a hidden marker
/// tracepoint. Stored as JSON inside the existing
/// `ProgramEvent.metadata` slot — the marker rides on the existing
/// tracepoint event mechanism per spec §1.  M25b decodes this back to
/// a `MarkerEventView` for the Event Log surface; M29 decodes the
/// same payload for the cross-process origin chain.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MarkerPayload {
    /// Stable id of the originating `MarkerDecl`. Indexes into the
    /// scanner's emitted list; the index is also the
    /// `correlation_marker_id` in the Event Log surface.
    pub marker_id: usize,
    pub boundary_id: String,
    pub direction: MarkerDirection,
    /// Textual form of the `key=<expr>` declaration. Kept alongside
    /// the evaluated `key_value` so diagnostics can show "key
    /// `envelope.id`" rather than just the value.
    pub key_text: String,
    pub key_value: String,
    /// Textual form of the optional `show=<expr>` declaration.
    pub show_text: Option<String>,
    /// Evaluated `show=<expr>` value. `None` means show falls back to
    /// the key value per spec §3.4.
    pub show_value: Option<String>,
    pub description: Option<String>,
    pub format: Option<MarkerFormatSpec>,
}

impl MarkerPayload {
    /// Encode the payload as a JSON string suitable for stashing into
    /// the tracepoint event's `metadata` slot. The decode side
    /// ([`MarkerPayload::decode`]) is the canonical inverse and is
    /// exercised in the test suite.
    pub fn encode(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    /// Decode a marker payload from the tracepoint event metadata
    /// slot. Returns `None` when the slot is empty or carries a non-
    /// marker payload — the consumer treats `None` as "not a marker
    /// firing" and falls through to ordinary tracepoint handling.
    pub fn decode(metadata: &str) -> Option<Self> {
        if metadata.is_empty() {
            return None;
        }
        serde_json::from_str(metadata).ok()
    }
}

/// Per-language comment prefix table from spec §2.1. The marker
/// grammar itself is language-agnostic; this table is the only
/// language-aware piece of the scanner. M25 ships the Python prefix
/// end-to-end (the spec-mandated primary path) and the table is
/// trivially extensible to the other languages — each new row is one
/// entry here plus a per-language test row in
/// `test_marker_comment_scanner`.
pub const LANGUAGE_COMMENT_PREFIXES: &[(&str, &[&str])] = &[
    // Languages whose comments start with `#` (Python, Ruby, shell,
    // YAML, TOML, Nim's hash-comment dialect). M25 ships Python end-
    // to-end; the others fall out trivially because the marker
    // grammar is language-agnostic once the comment is identified.
    ("py", &["#"]),
    ("rb", &["#"]),
    ("sh", &["#"]),
    ("bash", &["#"]),
    ("yaml", &["#"]),
    ("yml", &["#"]),
    ("toml", &["#"]),
    // Languages whose comments start with `//` (C, C++, Rust, Go,
    // Java, Swift, JavaScript, TypeScript). Nim accepts both `#` and
    // `//` in the spec but the table only handles the `#` form here
    // because the rest of the Nim toolchain treats `//` as a
    // mathematical operator; consumers wanting both spellings emit
    // the `#` form via [`MarkerDecl`] and rely on Nim's `#` parser.
    ("c", &["//"]),
    ("h", &["//"]),
    ("cc", &["//"]),
    ("cpp", &["//"]),
    ("cxx", &["//"]),
    ("hpp", &["//"]),
    ("rs", &["//"]),
    ("go", &["//"]),
    ("java", &["//"]),
    ("swift", &["//"]),
    ("js", &["//"]),
    ("mjs", &["//"]),
    ("jsx", &["//"]),
    ("ts", &["//"]),
    ("tsx", &["//"]),
    ("nim", &["#"]),
    // HTML / XML
    ("html", &["<!--"]),
    ("htm", &["<!--"]),
    ("xml", &["<!--"]),
    // Erlang / Elixir
    ("erl", &["%"]),
    ("ex", &["#"]),
    ("exs", &["#"]),
    // Pascal / Ada
    ("pas", &["//"]),
    ("pp", &["//"]),
    ("adb", &["--"]),
    ("ads", &["--"]),
];

/// Return the list of comment-prefix tokens for a path. Used by the
/// scanner to decide which lines to feed to the marker grammar.
pub fn comment_prefixes_for_path(path: &Path) -> &'static [&'static str] {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    for (extension, prefixes) in LANGUAGE_COMMENT_PREFIXES {
        if *extension == ext.as_str() {
            return prefixes;
        }
    }
    // Default to no prefixes — the scanner skips files whose
    // extension is unknown. Skip-and-diagnose at the caller.
    &[]
}

/// Errors raised by [`MarkerDecl::parse_comment`] when a line claims
/// to be a `codetracer:` marker but its body cannot be parsed. The
/// scanner translates these into per-file diagnostics surfaced in the
/// session-load banner; well-formed markers in the same file
/// continue to load.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MarkerParseError {
    /// The line is not a `codetracer:` clause (no marker tag,
    /// non-marker comment, etc). Used as the "skip silently" signal.
    NotAMarker,
    MissingDirection,
    UnknownDirection(String),
    MissingBoundaryId,
    UnterminatedQuotedString,
    MissingKeyField,
    UnknownField(String),
    MalformedField(String),
}

impl std::fmt::Display for MarkerParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotAMarker => write!(f, "not a codetracer marker comment"),
            Self::MissingDirection => write!(f, "marker missing direction (`send` or `recv`)"),
            Self::UnknownDirection(t) => write!(f, "marker has unknown direction `{t}`"),
            Self::MissingBoundaryId => write!(f, "marker missing quoted boundary id"),
            Self::UnterminatedQuotedString => write!(f, "marker has unterminated quoted string"),
            Self::MissingKeyField => write!(f, "marker missing mandatory `key=` field"),
            Self::UnknownField(n) => write!(f, "marker has unknown field `{n}`"),
            Self::MalformedField(detail) => write!(f, "marker has malformed field: {detail}"),
        }
    }
}

impl std::error::Error for MarkerParseError {}

impl MarkerDecl {
    /// Parse a single marker comment line against the marker grammar
    /// from spec §2.1:
    ///
    /// ```text
    /// <prefix> codetracer: <direction> "<boundary_id>" <field>*
    /// ```
    ///
    /// `line` is the **raw source line**; `prefix` is the comment
    /// lead-in for the host language (`#`, `//`, `--`, `<!--`, `%`).
    /// The body parser is language-agnostic — once the comment
    /// boundary is identified the grammar is the same for every
    /// language. Returns `Err(NotAMarker)` when the line is not a
    /// `codetracer:` clause at all (silent skip); other variants
    /// carry diagnostic detail surfaced in the session-load banner
    /// per spec §9.
    pub fn parse_comment(line: &str, prefix: &str, location: MarkerLocation) -> Result<Self, MarkerParseError> {
        let trimmed = line.trim();
        // Identify the comment prefix at the start of the trimmed line.
        let after_prefix = trimmed.strip_prefix(prefix).ok_or(MarkerParseError::NotAMarker)?;
        let body = after_prefix.trim_start();
        // For HTML-style multi-line comments, allow the `-->` close.
        let body = body.trim_end_matches("-->").trim_end_matches("*/").trim();
        let body = body
            .strip_prefix("codetracer:")
            .ok_or(MarkerParseError::NotAMarker)?
            .trim();
        parse_marker_body(body, location)
    }
}

/// Parse the body of a `codetracer:` clause — everything after the
/// `codetracer:` keyword. Public so the TOML loader can reuse the
/// field parser for the `key=<expr>` / `show=<expr>` / `desc=…` /
/// `format=…` fields. (The TOML loader does field-by-field assembly
/// directly, but parameterising the field parser keeps the grammar a
/// single source of truth.)
pub(crate) fn parse_marker_body(body: &str, location: MarkerLocation) -> Result<MarkerDecl, MarkerParseError> {
    let mut tokens = Tokenizer::new(body);

    let direction_tok = tokens.next_token()?.ok_or(MarkerParseError::MissingDirection)?;
    let direction = MarkerDirection::parse(&direction_tok)
        .ok_or_else(|| MarkerParseError::UnknownDirection(direction_tok.clone()))?;

    let boundary_id = tokens.next_quoted()?.ok_or(MarkerParseError::MissingBoundaryId)?;

    let mut key_text: Option<String> = None;
    let mut show_text: Option<String> = None;
    let mut description: Option<String> = None;
    let mut format: Option<MarkerFormatSpec> = None;

    while let Some((name, value)) = tokens.next_field()? {
        match name.as_str() {
            "key" => key_text = Some(value),
            "show" => show_text = Some(value),
            "desc" | "description" => description = Some(value),
            "format" => format = Some(value),
            other => return Err(MarkerParseError::UnknownField(other.to_string())),
        }
    }

    let key_text = key_text.ok_or(MarkerParseError::MissingKeyField)?;

    Ok(MarkerDecl {
        boundary_id,
        direction,
        key_text,
        show_text,
        description,
        format,
        location,
    })
}

/// Hand-rolled tokenizer for the marker body. We deliberately avoid
/// pulling in `nom` / `combine` / `regex` here — the grammar is small
/// and a focused tokenizer keeps the diagnostic surface tight.
struct Tokenizer<'a> {
    rest: &'a str,
}

impl<'a> Tokenizer<'a> {
    fn new(rest: &'a str) -> Self {
        Self { rest }
    }

    fn skip_ws(&mut self) {
        self.rest = self.rest.trim_start();
    }

    fn next_token(&mut self) -> Result<Option<String>, MarkerParseError> {
        self.skip_ws();
        if self.rest.is_empty() {
            return Ok(None);
        }
        let end = self
            .rest
            .find(|c: char| c.is_whitespace() || c == '"' || c == '=')
            .unwrap_or(self.rest.len());
        let tok = self.rest[..end].to_string();
        self.rest = &self.rest[end..];
        Ok(Some(tok))
    }

    fn next_quoted(&mut self) -> Result<Option<String>, MarkerParseError> {
        self.skip_ws();
        if !self.rest.starts_with('"') {
            return Ok(None);
        }
        self.rest = &self.rest[1..];
        let end = self.rest.find('"').ok_or(MarkerParseError::UnterminatedQuotedString)?;
        let value = self.rest[..end].to_string();
        self.rest = &self.rest[end + 1..];
        Ok(Some(value))
    }

    fn next_field(&mut self) -> Result<Option<(String, String)>, MarkerParseError> {
        self.skip_ws();
        if self.rest.is_empty() {
            return Ok(None);
        }
        let eq_pos = self.rest.find('=').ok_or_else(|| {
            MarkerParseError::MalformedField(format!("expected `name=value`, found `{}`", self.rest.trim_end()))
        })?;
        let name = self.rest[..eq_pos].trim().to_string();
        self.rest = &self.rest[eq_pos + 1..];
        if name.is_empty() {
            return Err(MarkerParseError::MalformedField("empty field name".to_string()));
        }
        // Value may be quoted (`desc="..."`) or unquoted (`key=msg.id`).
        let value = if self.rest.starts_with('"') {
            self.next_quoted()?
                .ok_or_else(|| MarkerParseError::MalformedField(format!("missing value for `{name}`")))?
        } else {
            self.skip_ws();
            // Unquoted values are terminated by whitespace or the
            // next `<name>=` token. We walk forward until the next
            // whitespace + `=` shape to absorb expressions like
            // `msg.id + 1`.
            let mut end = self.rest.len();
            let bytes = self.rest.as_bytes();
            let mut i = 0;
            while i < bytes.len() {
                let c = bytes[i] as char;
                if c.is_whitespace() {
                    // Peek ahead: if we see `<name>=` after the
                    // whitespace, this value terminates.
                    let after = self.rest[i..].trim_start();
                    if after.is_empty() {
                        end = i;
                        break;
                    }
                    // Look for `<ident>=` to decide if this whitespace
                    // ends the current value.
                    let ident_end = after
                        .find(|ch: char| !(ch.is_alphanumeric() || ch == '_'))
                        .unwrap_or(after.len());
                    if ident_end > 0 && after[ident_end..].starts_with('=') {
                        end = i;
                        break;
                    }
                }
                i += 1;
            }
            let value = self.rest[..end].trim().to_string();
            self.rest = &self.rest[end..];
            value
        };
        Ok(Some((name, value)))
    }
}

// ---------------------------------------------------------------------------
// Comment scanner
// ---------------------------------------------------------------------------

/// One diagnostic emitted by the scanner when a `codetracer:` clause
/// fails to parse. Surfaced in the session-load banner per spec §9.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkerDiagnostic {
    pub path: PathBuf,
    pub line: usize,
    pub error: MarkerParseError,
}

/// Output of [`scan_file_for_markers`] / [`MarkerScanner::scan`] —
/// the markers that parsed cleanly plus any per-line diagnostics.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ScanResult {
    pub markers: Vec<MarkerDecl>,
    pub diagnostics: Vec<MarkerDiagnostic>,
}

impl ScanResult {
    pub fn merge(&mut self, other: ScanResult) {
        self.markers.extend(other.markers);
        self.diagnostics.extend(other.diagnostics);
    }
}

/// Scan a single source file for `codetracer:` marker comments. Uses
/// the per-language comment prefix table from spec §2.1 to identify
/// candidate lines, then runs the language-agnostic marker grammar.
///
/// One marker per parsed clause — spec §2.1 allows multiple markers
/// on the same source line (e.g. a synchronous round-trip that's
/// both a send-side and a recv-side boundary).
pub fn scan_file_for_markers(path: &Path, source: &str) -> ScanResult {
    let prefixes = comment_prefixes_for_path(path);
    if prefixes.is_empty() {
        return ScanResult::default();
    }
    let mut out = ScanResult::default();
    for (lineno_zero, raw_line) in source.lines().enumerate() {
        let line_number = lineno_zero + 1;
        // A single source line can carry multiple comments — e.g.
        // `code(); // codetracer: send "x" key=a /* codetracer: recv "y" key=b */`.
        // For the M25 surface we handle one marker per comment block;
        // additional `codetracer:` clauses on the same line repeat the
        // prefix detection on the residue.
        for prefix in prefixes {
            // Find the comment lead-in on this line, repeat for
            // multiple `<prefix> codetracer:` clauses on the same
            // line (spec §2.1 allows this).
            let mut residue = raw_line;
            while let Some(idx) = residue.find(prefix) {
                let candidate = &residue[idx..];
                let location = MarkerLocation::new(path.to_string_lossy().into_owned(), line_number);
                match MarkerDecl::parse_comment(candidate, prefix, location.clone()) {
                    Ok(decl) => out.markers.push(decl),
                    Err(MarkerParseError::NotAMarker) => {
                        // Plain comment — silent skip per spec.
                    }
                    Err(err) => {
                        out.diagnostics.push(MarkerDiagnostic {
                            path: path.to_path_buf(),
                            line: line_number,
                            error: err,
                        });
                    }
                }
                // Move past the prefix to look for further
                // `codetracer:` clauses on the same line.
                let advance = idx + prefix.len();
                if advance >= residue.len() {
                    break;
                }
                residue = &residue[advance..];
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------
// TOML authoring path (spec §2.3)
// ---------------------------------------------------------------------------

/// On-disk TOML schema for `.codetracer/correlation-markers.toml`.
/// Mirrors the comment grammar field-for-field (per spec §2.3) so a
/// marker can move between authoring paths without renaming.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct TomlMarkerFile {
    #[serde(default, rename = "marker")]
    markers: Vec<TomlMarker>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct TomlMarker {
    /// Either `function` or `path` identifies the source location.
    /// For M25 we accept the explicit `path` + `line` pair (the more
    /// general shape) and treat `function` as an opaque label stashed
    /// in the diagnostic surface when present.
    #[serde(default)]
    function: Option<String>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    line: Option<usize>,
    direction: String,
    boundary_id: String,
    key: String,
    #[serde(default)]
    show: Option<String>,
    #[serde(default)]
    desc: Option<String>,
    #[serde(default)]
    format: Option<String>,
}

/// Errors emitted by [`load_toml_markers`]. The session-load layer
/// surfaces these the same way it surfaces comment-scanner
/// diagnostics.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TomlMarkerError {
    Parse(String),
    MissingLocation(String),
    UnknownDirection(String),
}

impl std::fmt::Display for TomlMarkerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Parse(msg) => write!(f, "correlation-markers.toml parse failure: {msg}"),
            Self::MissingLocation(b) => write!(f, "correlation-markers.toml marker `{b}` has no path+line"),
            Self::UnknownDirection(d) => write!(f, "correlation-markers.toml marker has unknown direction `{d}`"),
        }
    }
}

impl std::error::Error for TomlMarkerError {}

/// Parse a `.codetracer/correlation-markers.toml` document into
/// `MarkerDecl`s. We use a minimal hand-rolled parser over the
/// document text because the M25 crate already has `serde` but does
/// not yet depend on the `toml` crate; for the V1 schema (one
/// `[[marker]]` table at a time with flat scalar fields) the parser
/// stays small and entirely focused on what the spec defines.
pub fn parse_toml_markers(text: &str) -> Result<Vec<MarkerDecl>, TomlMarkerError> {
    let mut markers: Vec<MarkerDecl> = Vec::new();
    let mut current: Option<TomlMarker> = None;
    for (lineno, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line == "[[marker]]" {
            if let Some(prev) = current.take() {
                markers.push(toml_marker_into_decl(prev)?);
            }
            current = Some(TomlMarker {
                function: None,
                path: None,
                line: None,
                direction: String::new(),
                boundary_id: String::new(),
                key: String::new(),
                show: None,
                desc: None,
                format: None,
            });
            continue;
        }
        let Some(eq) = line.find('=') else {
            return Err(TomlMarkerError::Parse(format!(
                "line {}: expected `key = value`, got `{line}`",
                lineno + 1
            )));
        };
        let name = line[..eq].trim();
        let value_raw = line[eq + 1..].trim();
        let value = value_raw.trim_start_matches('"').trim_end_matches('"').to_string();
        let m = current.as_mut().ok_or_else(|| {
            TomlMarkerError::Parse(format!(
                "line {}: `{name}=...` appears before any `[[marker]]` table",
                lineno + 1
            ))
        })?;
        match name {
            "function" => m.function = Some(value),
            "path" => m.path = Some(value),
            "line" => {
                m.line = Some(value.parse::<usize>().map_err(|e| {
                    TomlMarkerError::Parse(format!("line {}: line number not an integer ({e})", lineno + 1))
                })?)
            }
            "direction" => m.direction = value,
            "boundary_id" => m.boundary_id = value,
            "key" => m.key = value,
            "show" => m.show = Some(value),
            "desc" => m.desc = Some(value),
            "format" => m.format = Some(value),
            other => {
                return Err(TomlMarkerError::Parse(format!(
                    "line {}: unknown marker field `{other}`",
                    lineno + 1
                )));
            }
        }
    }
    if let Some(last) = current.take() {
        markers.push(toml_marker_into_decl(last)?);
    }
    Ok(markers)
}

fn toml_marker_into_decl(m: TomlMarker) -> Result<MarkerDecl, TomlMarkerError> {
    let direction =
        MarkerDirection::parse(&m.direction).ok_or(TomlMarkerError::UnknownDirection(m.direction.clone()))?;
    let path = m
        .path
        .clone()
        .or_else(|| m.function.clone())
        .ok_or_else(|| TomlMarkerError::MissingLocation(m.boundary_id.clone()))?;
    // When `function` is the only locator, line defaults to 1 — the
    // session-load layer that owns the §3.1 source resolution
    // upgrades this to the function's entry line through the
    // existing function-index lookup. For M25 we keep the loader
    // scoped to schema construction and leave the function→line
    // resolution to the integrator.
    let line = m.line.unwrap_or(1);
    Ok(MarkerDecl {
        boundary_id: m.boundary_id,
        direction,
        key_text: m.key,
        show_text: m.show,
        description: m.desc,
        format: m.format,
        location: MarkerLocation::new(path, line),
    })
}

/// Scanner facade combining the comment-path and TOML-path inputs
/// per spec §3.1. Inputs are loaded in priority order:
///
///   1. `meta_dat/sources/` inside the trace bundle (self-contained
///      traces);
///   2. The active workspace as resolved by the manifest;
///   3. The recorded absolute paths the trace carries.
///
/// M25's surface here exposes the comment + TOML loaders as pure
/// functions; the session-load integrator owns walking the three
/// candidate roots, picking the highest-priority match per file, and
/// feeding the results to the hidden-tracepoint registration layer.
pub struct MarkerScanner;

impl MarkerScanner {
    /// Walk the on-disk roots in priority order and return all
    /// markers discovered + per-file diagnostics. Path priority
    /// matches spec §3.1 — duplicates between roots are resolved by
    /// taking the first matching file.
    pub fn scan_roots(roots: &[&Path]) -> ScanResult {
        let mut combined = ScanResult::default();
        // We dedupe per relative path so the same source file picked
        // up from two roots is scanned only once (priority order).
        let mut seen: HashMap<PathBuf, ()> = HashMap::new();
        for root in roots {
            if !root.is_dir() {
                continue;
            }
            walk_dir(root, root, &mut seen, &mut combined);
        }
        combined
    }

    /// Convenience: scan a single file's contents. Used by the
    /// per-file integration path (when the integrator already knows
    /// which file to load) and by the tests.
    pub fn scan_text(path: &Path, source: &str) -> ScanResult {
        scan_file_for_markers(path, source)
    }

    /// Convenience: load + parse a TOML marker file from disk.
    pub fn load_toml(path: &Path) -> Result<Vec<MarkerDecl>, TomlMarkerError> {
        let text = fs::read_to_string(path).map_err(|e| TomlMarkerError::Parse(format!("read {path:?}: {e}")))?;
        parse_toml_markers(&text)
    }
}

fn walk_dir(root: &Path, dir: &Path, seen: &mut HashMap<PathBuf, ()>, out: &mut ScanResult) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_dir(root, &path, seen, out);
            continue;
        }
        let rel = path.strip_prefix(root).unwrap_or(&path).to_path_buf();
        if seen.contains_key(&rel) {
            continue;
        }
        let Ok(source) = fs::read_to_string(&path) else {
            continue;
        };
        let result = scan_file_for_markers(&path, &source);
        if !result.markers.is_empty() || !result.diagnostics.is_empty() {
            seen.insert(rel, ());
            out.merge(result);
        }
    }
}

// ---------------------------------------------------------------------------
// Load-progress DAP event protocol (spec §3.2.1.2)
// ---------------------------------------------------------------------------

/// Body of `ct/markerLoadStarted` emitted exactly once when the
/// session-load marker pass begins. The Event Log surface (M25b)
/// uses this to render the "loading correlation markers…" banner.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkerLoadStartedEvent {
    pub session_id: String,
    pub total_declared: usize,
}

/// Body of `ct/markerLoadProgress` — emitted **throttled** to one
/// event per 250 ms per session while hidden tracepoints fire into
/// the cache. The emitter ([`MarkerLoadProgressThrottle`]) enforces
/// the throttle so consumers don't have to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkerLoadProgressEvent {
    pub session_id: String,
    pub loaded: usize,
    pub total: usize,
}

/// Body of `ct/markerLoadCompleted` emitted exactly once when every
/// declared marker has finished evaluating across the session's
/// covered range.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkerLoadCompletedEvent {
    pub session_id: String,
    pub final_loaded: usize,
    pub duration_ms: u64,
}

/// Throttle wrapper for the §3.2.1.2 progress event. Consumers call
/// [`MarkerLoadProgressThrottle::should_emit`] each time a marker
/// fires and only emit an event when the call returns `Some`. The
/// throttle interval is the spec-mandated 250 ms by default; M25
/// owns the emission side and uses this surface in
/// `session_handler::SessionHandler` once M25b's Event Log consumer
/// is wired.
///
/// We deliberately keep the throttle generic over a clock so unit
/// tests can drive it deterministically.
pub struct MarkerLoadProgressThrottle {
    /// Last instant at which an event was emitted, expressed as
    /// milliseconds since session start so tests can drive a
    /// monotonic virtual clock.
    last_emit_ms: Option<u64>,
    /// Spec-mandated throttle interval (250 ms by default).
    pub interval_ms: u64,
}

impl MarkerLoadProgressThrottle {
    pub fn new() -> Self {
        Self {
            last_emit_ms: None,
            interval_ms: 250,
        }
    }

    /// Decide whether an event should fire at `now_ms`. Returns
    /// `true` and updates the last-emit timestamp; returns `false`
    /// without state change when the previous event is within the
    /// throttle window.
    pub fn should_emit(&mut self, now_ms: u64) -> bool {
        match self.last_emit_ms {
            Some(last) if now_ms.saturating_sub(last) < self.interval_ms => false,
            _ => {
                self.last_emit_ms = Some(now_ms);
                true
            }
        }
    }
}

impl Default for MarkerLoadProgressThrottle {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// M27 ↔ M25 bridge: WASM realm-boundary tokens as a `js-wasm-realm`
// correlation-marker family.
// ---------------------------------------------------------------------------
//
// Context: the M27 milestone (`codetracer-wasm-instrumenter`) emits
// realm-crossing events through `__ct_emit_realm_boundary(direction,
// fn_kind, fn_index, token)` in WASM-instrumented modules, paired with
// a JS-side emission whose JSON shape is
// `__ct.emit({kind: "RealmBoundary", token, direction: "enter"|"leave"})`.
// The audit at
// `codetracer-specs/Planned-Features/Cross-Tracer-Origin-Test.audit.md`
// (TCT-M2 — "PairIndex bridge") calls this out as a prerequisite for
// composing the M25 cross-process origin chain over WASM module
// boundaries.
//
// The existing [`MarkerPayload`] schema generalises cleanly to this
// case — every field has a sensible inhabitant for a realm-boundary
// firing — so the bridge is a thin adapter (parse the two wire shapes
// → produce a `MarkerPayload` with the spec's `boundary_id`) rather
// than a refactor. We deliberately keep both adapter functions in the
// same module as the rest of the marker schema so the constant is the
// single source of truth.

/// The boundary id used for every JS↔WASM realm-crossing pair. Spec:
/// the M25 ↔ M27 bridge family name.
///
/// All correlation marker firings produced by either side of a realm
/// crossing share this `boundary_id`; pairing is by `key_value` =
/// the monotonic correlation token.
pub const BOUNDARY_ID_JS_WASM_REALM: &str = "js-wasm-realm";

/// JS-side `direction` field values per the M27 wire shape.
pub const JS_REALM_DIRECTION_ENTER: &str = "enter";
pub const JS_REALM_DIRECTION_LEAVE: &str = "leave";

/// WASM-side `direction` argument values per the
/// `__ct_emit_realm_boundary` ABI documented in
/// `codetracer-wasm-instrumenter/crates/codetracer-wasm-instrumenter/src/hooks.rs`.
///
/// `0` = entering the foreign realm (the JS host) — fired at the call
/// site immediately before control leaves the WASM module.
/// `1` = leaving the foreign realm — fired at the return site
/// immediately after control re-enters the WASM module.
pub const WASM_REALM_DIRECTION_ENTER: i32 = 0;
pub const WASM_REALM_DIRECTION_LEAVE: i32 = 1;

/// Tag byte for a realm-boundary event in the M27 recorder-runtime
/// batch wire format. The reference encoder is `__ct_emit_realm_boundary`
/// in `codetracer-wasm-instrumenter/recorder-runtime/host_runtime.js`.
///
/// # Canonical wire shape (M27 → M25)
///
/// The recorder runtime packs every `__ct_emit_realm_boundary(direction,
/// fn_kind, fn_index, token)` call into a fixed 32-byte little-endian
/// slot inside the batch buffer it flushes through `onBatch(buf)` (the
/// embedder wires that callback to the M26 transport producer in the
/// browser or to a CTFS writer natively). The byte layout shared with
/// the producer:
///
/// ```text
///   offset 0  : u8  tag        (= 4 for realm_boundary)
///   offset 1  : u8  fn_kind    (0 = import, 1 = export)
///   offset 2  : u8  direction  (0 = enter foreign realm, 1 = leave)
///   offset 3  : u8  reserved
///   offset 4  : u32 fn_index   (little-endian)
///   offset 8  : u32 reserved
///   offset 12 : u32 reserved
///   offset 16 : u64 token      (little-endian, monotonic)
///   offset 24 : u64 reserved
/// ```
///
/// Bridge into `wasm_realm_marker_payload`: zero-extend the `direction`
/// and `fn_kind` bytes to `i32` (the WASM ABI's `i32` argument type),
/// pass the decoded `fn_index` as `u32` and the decoded `token` as
/// `u64`. The receiver-side helper [`decode_wasm_realm_event`] performs
/// the round-trip and is exercised by
/// `test_wasm_realm_event_wire_round_trips_into_marker_payload` in
/// `tests/correlation_markers_test.rs`.
pub const WASM_BATCH_TAG_REALM_BOUNDARY: u8 = 4;

/// Total size in bytes of one event slot in the M27 recorder-runtime
/// batch wire format. Pinned here so the receiver-side decoder shares
/// the constant with the test that pins the layout.
pub const WASM_BATCH_EVENT_SIZE_BYTES: usize = 32;

/// Decode the four arguments of an `__ct_emit_realm_boundary` call from
/// a 32-byte slot inside a recorder-runtime batch buffer. Returns
/// `None` when the slot is not a realm-boundary event (tag != 4) or
/// when the buffer is too short — matching the skip-and-diagnose
/// contract of [`MarkerPayload::decode`].
///
/// The returned tuple feeds directly into [`wasm_realm_marker_payload`]:
/// the bridge is `(direction, fn_kind, fn_index, token)` with no
/// further transformation.
pub fn decode_wasm_realm_event(slot: &[u8]) -> Option<(i32, i32, u32, u64)> {
    if slot.len() < WASM_BATCH_EVENT_SIZE_BYTES {
        return None;
    }
    if slot[0] != WASM_BATCH_TAG_REALM_BOUNDARY {
        return None;
    }
    let fn_kind = slot[1] as i32;
    let direction = slot[2] as i32;
    let fn_index = u32::from_le_bytes([slot[4], slot[5], slot[6], slot[7]]);
    let token = u64::from_le_bytes([
        slot[16], slot[17], slot[18], slot[19], slot[20], slot[21], slot[22], slot[23],
    ]);
    Some((direction, fn_kind, fn_index, token))
}

/// JSON-line shape of a realm-boundary event as the M27 recorder
/// runtime ships it through the M26 producer (newline-delimited JSON
/// over the stream socket). The canonical encoder lives in
/// `codetracer-wasm-instrumenter/recorder-runtime/host_runtime.js`
/// (`decodeSlot` → tag 4 branch); the JSON shape is:
///
/// ```json
/// {"kind":"RealmBoundary","token":"<decimal>","direction":0|1,
///  "fn_kind":0|1,"fn_index":<u32>}
/// ```
///
/// `token` is a decimal **string** rather than a JSON number so values
/// above 2^53 survive a `serde_json` round-trip (JSON numbers are
/// IEEE-754 doubles and lose precision above that threshold; the
/// monotonic correlation token is a u64). The two `direction` /
/// `fn_kind` byte fields ride as plain JSON integers.
///
/// We deserialise into this intermediate struct rather than feeding
/// `serde_json::Value` into [`wasm_realm_marker_payload`] so the field
/// names + types are pinned by the schema. Drift in either direction
/// (browser runtime renames a field, or the consumer renames a
/// parameter) shows up at this boundary as a clean deserialisation
/// failure instead of a silently mis-paired event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WasmRealmBoundaryWireEvent {
    /// Discriminator tag — fixed to `"RealmBoundary"` for this event.
    pub kind: String,
    /// Decimal-string-encoded u64 correlation token. The string
    /// representation matches the format
    /// [`wasm_realm_marker_payload`] uses for its `key_value`, so the
    /// pair index lookup is byte-for-byte exact.
    pub token: String,
    /// `0` = entering the foreign realm, `1` = leaving — same encoding
    /// as the WASM ABI's i32 direction argument.
    pub direction: u8,
    /// `0` = imported function (WASM → JS), `1` = exported function
    /// (JS → WASM).
    pub fn_kind: u8,
    /// Stable index within the import / export section.
    pub fn_index: u32,
}

/// Parse one JSON line emitted by the recorder runtime's M26 producer
/// (a single newline-delimited record off the stream socket) into the
/// 4-tuple [`wasm_realm_marker_payload`] consumes.
///
/// Returns `None` when the line is not a well-formed
/// `{"kind":"RealmBoundary", ...}` JSON object, when the `kind`
/// discriminator is not exactly `"RealmBoundary"`, or when the
/// `token` field cannot be parsed as a u64. Matches the
/// skip-and-diagnose contract of [`MarkerPayload::decode`].
pub fn parse_wasm_realm_event_json(line: &str) -> Option<(i32, i32, u32, u64)> {
    let event: WasmRealmBoundaryWireEvent = serde_json::from_str(line).ok()?;
    if event.kind != "RealmBoundary" {
        return None;
    }
    let token = event.token.parse::<u64>().ok()?;
    Some((event.direction as i32, event.fn_kind as i32, event.fn_index, token))
}

/// Convert a JS-side `__ct.emit({kind: "RealmBoundary", ...})` payload
/// into the marker payload that drops into the M25 pair index.
///
/// Pairing convention: the JS-side firing is the **Send** half (the
/// JS realm is the value-producer at the boundary that's relevant for
/// the cross-process origin chain — the WASM side is the consumer),
/// keyed by the monotonic correlation token rendered as decimal so
/// the `key_value` lookup in [`crate::correlation_index::PairIndex`]
/// matches byte-for-byte against the WASM-side counterpart.
///
/// `direction` is the spec wire spelling (`"enter"` or `"leave"`). It
/// only carries diagnostic value here — the pair index uses
/// `MarkerDirection`. We surface the original spelling in
/// `description` so the Event Log render can show "JS enter→WASM" /
/// "JS leave→WASM" without re-decoding the metadata slot.
///
/// Returns `None` when `direction` is neither `"enter"` nor `"leave"`
/// — the caller treats this as "not a realm-boundary marker" and
/// falls through to ordinary tracepoint handling, mirroring
/// [`MarkerPayload::decode`]'s contract.
pub fn js_realm_marker_payload(token: u64, direction: &str) -> Option<MarkerPayload> {
    let (direction_enum, wire_spelling) = match direction {
        JS_REALM_DIRECTION_ENTER => (MarkerDirection::Send, JS_REALM_DIRECTION_ENTER),
        JS_REALM_DIRECTION_LEAVE => (MarkerDirection::Send, JS_REALM_DIRECTION_LEAVE),
        _ => return None,
    };
    Some(MarkerPayload {
        marker_id: 0,
        boundary_id: BOUNDARY_ID_JS_WASM_REALM.to_string(),
        direction: direction_enum,
        key_text: "token".to_string(),
        key_value: token.to_string(),
        show_text: None,
        show_value: None,
        description: Some(format!("js {wire_spelling} wasm")),
        format: None,
    })
}

/// Convert a WASM-side `__ct_emit_realm_boundary(direction, fn_kind,
/// fn_index, token)` tuple into the marker payload that drops into
/// the M25 pair index.
///
/// Pairing convention (see [`js_realm_marker_payload`] for the
/// matching side): the WASM-side firing is the **Recv** half of the
/// pair so [`crate::correlation_index::PairIndex::counterparts_of`]
/// turns a JS Send into the WASM Recv that observes the same token.
///
/// `fn_kind` is the spec's import / export discriminator from the
/// instrumenter ABI:
/// - `0` = imported function (host call from WASM → JS)
/// - `1` = exported function (host call into WASM)
///
/// We surface both `fn_kind` and `fn_index` in `description` so a
/// reader of the Event Log can identify which WASM function the
/// crossing applied to without re-decoding the metadata.
///
/// Returns `None` when `direction` is neither `0` nor `1`, matching
/// the JS-side adapter's skip-and-diagnose contract.
pub fn wasm_realm_marker_payload(direction: i32, fn_kind: i32, fn_index: u32, token: u64) -> Option<MarkerPayload> {
    let wire_spelling = match direction {
        WASM_REALM_DIRECTION_ENTER => "enter",
        WASM_REALM_DIRECTION_LEAVE => "leave",
        _ => return None,
    };
    let kind_label = match fn_kind {
        0 => "import",
        1 => "export",
        _ => "unknown",
    };
    Some(MarkerPayload {
        marker_id: 0,
        boundary_id: BOUNDARY_ID_JS_WASM_REALM.to_string(),
        direction: MarkerDirection::Recv,
        key_text: "token".to_string(),
        key_value: token.to_string(),
        show_text: None,
        show_value: None,
        description: Some(format!("wasm {wire_spelling} {kind_label}#{fn_index}")),
        format: None,
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn loc(line: usize) -> MarkerLocation {
        MarkerLocation::new("test.py", line)
    }

    #[test]
    fn parse_comment_python_send_minimal() {
        let line = r#"    # codetracer: send "order-processing" key=msg.id"#;
        let decl = MarkerDecl::parse_comment(line, "#", loc(7)).unwrap();
        assert_eq!(decl.direction, MarkerDirection::Send);
        assert_eq!(decl.boundary_id, "order-processing");
        assert_eq!(decl.key_text, "msg.id");
        assert!(decl.show_text.is_none());
        assert!(decl.description.is_none());
        assert!(decl.format.is_none());
        assert_eq!(decl.location.line, 7);
    }

    #[test]
    fn parse_comment_python_recv_full() {
        let line = r#"# codetracer: recv "envelope-flow" key=env.id show=env.body desc="Inbound" format=json"#;
        let decl = MarkerDecl::parse_comment(line, "#", loc(11)).unwrap();
        assert_eq!(decl.direction, MarkerDirection::Recv);
        assert_eq!(decl.key_text, "env.id");
        assert_eq!(decl.show_text.as_deref(), Some("env.body"));
        assert_eq!(decl.description.as_deref(), Some("Inbound"));
        assert_eq!(decl.format.as_deref(), Some("json"));
    }

    #[test]
    fn parse_comment_rejects_misspelled_direction() {
        let line = r#"# codetracer: Send "x" key=msg"#;
        match MarkerDecl::parse_comment(line, "#", loc(1)) {
            Err(MarkerParseError::UnknownDirection(d)) => assert_eq!(d, "Send"),
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn parse_comment_skips_non_marker_comment() {
        let line = "# regular comment";
        match MarkerDecl::parse_comment(line, "#", loc(1)) {
            Err(MarkerParseError::NotAMarker) => {}
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn parse_comment_requires_key_field() {
        let line = r#"# codetracer: send "x" show=msg.payload"#;
        match MarkerDecl::parse_comment(line, "#", loc(1)) {
            Err(MarkerParseError::MissingKeyField) => {}
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn marker_payload_roundtrip() {
        let payload = MarkerPayload {
            marker_id: 7,
            boundary_id: "order".to_string(),
            direction: MarkerDirection::Send,
            key_text: "msg.id".to_string(),
            key_value: "42".to_string(),
            show_text: Some("msg.body".to_string()),
            show_value: Some("hello".to_string()),
            description: Some("test".to_string()),
            format: Some("json".to_string()),
        };
        let encoded = payload.encode();
        let decoded = MarkerPayload::decode(&encoded).unwrap();
        assert_eq!(decoded, payload);
    }

    #[test]
    fn comment_prefix_lookup_recognises_python() {
        let p = Path::new("foo.py");
        assert_eq!(comment_prefixes_for_path(p), &["#"]);
    }

    #[test]
    fn toml_path_round_trip() {
        let text = r#"
[[marker]]
direction = "send"
boundary_id = "order-processing"
path = "src/sender.py"
line = 42
key = "msg.id"
show = "msg.body"
desc = "Outbound"
format = "json"
"#;
        let decls = parse_toml_markers(text).unwrap();
        assert_eq!(decls.len(), 1);
        assert_eq!(decls[0].boundary_id, "order-processing");
        assert_eq!(decls[0].direction, MarkerDirection::Send);
        assert_eq!(decls[0].location.path, "src/sender.py");
        assert_eq!(decls[0].location.line, 42);
        assert_eq!(decls[0].key_text, "msg.id");
        assert_eq!(decls[0].show_text.as_deref(), Some("msg.body"));
    }
}
