//! Pattern language: matcher + classification + continuation triples
//! (spec §7).
//!
//! The pattern files are TOML documents whose schema is documented in
//! spec §7.4 "Pattern file schema". A pattern declares one of three
//! tables — `forwarder`, `trivial_copy`, or `computational` — each
//! with a `match` expression and (for the first two) a `continuation`
//! expression. Pattern variables `$name` capture sub-trees; `$_` is
//! the anonymous wildcard.
//!
//! Patterns whose `continuation` references an undeclared capture are
//! rejected at load time with a clear error (spec §7.4 last paragraph
//! and milestones-file M1 verification line for
//! `test_classifier_continuation_capture_validation`).
//!
//! Override precedence is implemented by [`PatternSet::load_layered`]:
//!
//! 1. Trace-local `_overrides.toml`
//! 2. Personal `~/.config/codetracer/origin-patterns.toml`
//! 3. Embedded library patterns in `meta_dat/origin-patterns/<lib>/...`
//! 4. Built-in catalogue (spec §7.1, §7.3)

use std::collections::HashSet;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::kinds::{Lang, OriginKind};

// ---------------------------------------------------------------------------
// Pattern data model
// ---------------------------------------------------------------------------

/// The TOML table that declared the rule. Drives the pattern's
/// classification when no explicit `kind` field is set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PatternKind {
    Forwarder,
    TrivialCopy,
    Computational,
}

impl PatternKind {
    fn default_origin(self) -> OriginKind {
        match self {
            PatternKind::Forwarder | PatternKind::TrivialCopy => OriginKind::TrivialCopy,
            PatternKind::Computational => OriginKind::Computational,
        }
    }

    fn table_name(self) -> &'static str {
        match self {
            PatternKind::Forwarder => "forwarder",
            PatternKind::TrivialCopy => "trivial_copy",
            PatternKind::Computational => "computational",
        }
    }
}

/// Provenance metadata used by the State Pane's "Show pattern
/// provenance" affordance (spec §7.4 "Frontend affordances").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PatternProvenance {
    /// Which precedence layer the rule came from. The string format
    /// matches the M0 fixture `ANSWERS.md` examples
    /// ("personal: …", "trace-local: …", "embedded: <lib>: …",
    /// "built-in: …") so test assertions are stable.
    pub layer: String,
    /// The rule's `description` field, if any.
    pub description: Option<String>,
    /// Library identifier the embedded pattern came from
    /// (e.g. `faux_lib`). `None` for non-embedded rules.
    pub library: Option<String>,
    /// Absolute source path of the TOML file, used by diagnostics.
    pub source_path: Option<PathBuf>,
}

impl PatternProvenance {
    /// Human-readable provenance string suitable for assertions.
    pub fn render(&self) -> String {
        match (&self.description, &self.library) {
            (Some(desc), Some(lib)) => format!("{}: {}: {}", self.layer, lib, desc),
            (Some(desc), None) => format!("{}: {}", self.layer, desc),
            (None, Some(lib)) => format!("{}: {}", self.layer, lib),
            (None, None) => self.layer.clone(),
        }
    }
}

/// A single (matcher, classification, continuation) rule.
#[derive(Debug, Clone)]
pub struct PatternRule {
    /// The matcher expression, e.g. `$x.clone()` or
    /// `memcpy($_dst, $src, $_n)`.
    pub matcher: MatcherExpr,
    /// Pattern kind (which TOML table declared this rule).
    pub kind: PatternKind,
    /// Classification override. Used when a rule wants to declare a
    /// different `OriginKind` than the table default (rare).
    pub origin_kind: OriginKind,
    /// Continuation expression naming the capture(s) the next
    /// backward step should follow. `None` for `computational`
    /// patterns whose continuation set is derived from operand
    /// snapshots.
    pub continuation: Option<ContinuationExpr>,
    /// Languages this rule applies to. Empty = all V1 languages.
    pub languages: Vec<Lang>,
    /// Provenance metadata for diagnostics + frontend display.
    pub provenance: PatternProvenance,
    /// Sequential index inside the source file (1-based). Used by
    /// load-time diagnostics.
    pub rule_index: usize,
}

// ---------------------------------------------------------------------------
// Matcher and continuation expressions
// ---------------------------------------------------------------------------

/// Parsed matcher expression. We keep the structure simple: a matcher
/// is a tree of [`MatcherNode`]s whose leaves are literal tokens,
/// named captures (`$name`), or the anonymous wildcard (`$_`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MatcherExpr {
    pub root: MatcherNode,
    /// Raw matcher text for diagnostics.
    pub raw: String,
}

/// One node of a matcher expression tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MatcherNode {
    /// A named capture `$name`. The name is stored without the `$`.
    Capture(String),
    /// The anonymous wildcard `$_` (matches any sub-tree without
    /// binding).
    Wildcard,
    /// A literal identifier or keyword (`memcpy`, `Box`, `clone`, …).
    Identifier(String),
    /// Method-call form `receiver.method(args)`. `receiver` is one
    /// node; `method` is the textual method name; `args` is the
    /// argument list.
    Method {
        receiver: Box<MatcherNode>,
        method: String,
        args: Vec<MatcherNode>,
    },
    /// Free-standing call `callee(args)`.
    Call {
        callee: Box<MatcherNode>,
        args: Vec<MatcherNode>,
    },
    /// A static path `A::B::C`.
    Path(Vec<String>),
    /// Indexing/subscript `receiver[index]`.
    Index {
        receiver: Box<MatcherNode>,
        index: Box<MatcherNode>,
    },
    /// Attribute access `receiver.attr`.
    Attribute {
        receiver: Box<MatcherNode>,
        attr: String,
    },
}

impl MatcherNode {
    /// Walk the node tree collecting capture names.
    pub fn collect_captures(&self, out: &mut HashSet<String>) {
        match self {
            MatcherNode::Capture(name) => {
                out.insert(name.clone());
            }
            MatcherNode::Wildcard | MatcherNode::Identifier(_) | MatcherNode::Path(_) => {}
            MatcherNode::Method { receiver, args, .. } => {
                receiver.collect_captures(out);
                for arg in args {
                    arg.collect_captures(out);
                }
            }
            MatcherNode::Call { callee, args } => {
                callee.collect_captures(out);
                for arg in args {
                    arg.collect_captures(out);
                }
            }
            MatcherNode::Index { receiver, index } => {
                receiver.collect_captures(out);
                index.collect_captures(out);
            }
            MatcherNode::Attribute { receiver, .. } => {
                receiver.collect_captures(out);
            }
        }
    }
}

/// Continuation expression names a single capture (forwarder /
/// trivial-copy patterns) — the next backward search target.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContinuationExpr {
    pub raw: String,
    pub capture: String,
}

// ---------------------------------------------------------------------------
// Pattern set + fingerprint
// ---------------------------------------------------------------------------

/// SHA-256 over the deterministic textual encoding of every rule in
/// the set (layer + raw matcher + raw continuation, in load order).
/// The hex digest is what M2's continuation-token integrity check
/// (spec §5.3.1) embeds in tokens.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PatternFingerprint {
    pub hex: String,
}

impl fmt::Display for PatternFingerprint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.hex)
    }
}

/// The loaded, ordered pattern set used by the classifier.
///
/// Lower index = higher precedence ("first match wins"). The
/// [`load_layered`] entry point constructs the ordering per spec §7.4.
///
/// [`load_layered`]: PatternSet::load_layered
#[derive(Debug, Clone, Default)]
pub struct PatternSet {
    rules: Vec<PatternRule>,
    fingerprint: PatternFingerprint,
}

impl PatternSet {
    /// Iterate over rules in match precedence order.
    pub fn rules(&self) -> &[PatternRule] {
        &self.rules
    }

    /// Deterministic fingerprint over the full loaded set.
    pub fn fingerprint(&self) -> &PatternFingerprint {
        &self.fingerprint
    }

    /// Construct a [`PatternSet`] containing only the built-in
    /// catalogue (spec §7.3). Useful for tests that want a
    /// well-defined baseline.
    pub fn built_in() -> Self {
        let mut rules = built_in_catalogue();
        let fingerprint = fingerprint_rules(&rules);
        // built-in rules are pre-ordered; nothing to sort.
        // assign rule indices for diagnostics
        for (i, rule) in rules.iter_mut().enumerate() {
            rule.rule_index = i + 1;
        }
        PatternSet { rules, fingerprint }
    }

    /// Load patterns from the four override layers described in
    /// spec §7.4.
    ///
    /// Any of the path arguments may be `None`; missing layers are
    /// silently skipped.
    ///
    /// - `trace_overrides`: absolute path to
    ///   `meta_dat/origin-patterns/_overrides.toml` inside an opened
    ///   trace.
    /// - `personal_overrides`: absolute path to
    ///   `~/.config/codetracer/origin-patterns.toml`.
    /// - `embedded_root`: absolute path to the trace's
    ///   `meta_dat/origin-patterns/` directory. Each sub-directory
    ///   is treated as a `<library_id>` and `*.toml` files within
    ///   are loaded.
    pub fn load_layered(
        trace_overrides: Option<&Path>,
        personal_overrides: Option<&Path>,
        embedded_root: Option<&Path>,
    ) -> Result<Self, LoadError> {
        let mut rules: Vec<PatternRule> = Vec::new();

        // Layer 1: trace-local _overrides.toml ----------------------
        if let Some(path) = trace_overrides {
            if path.exists() {
                let layer_rules = load_file(path, "trace-local", None)?;
                rules.extend(layer_rules);
            }
        }

        // Layer 2: personal overrides --------------------------------
        if let Some(path) = personal_overrides {
            if path.exists() {
                let layer_rules = load_file(path, "personal", None)?;
                rules.extend(layer_rules);
            }
        }

        // Layer 3: embedded library patterns. We enumerate library
        // directories in sorted order so the loaded set is
        // deterministic across machines (the manifest
        // `meta_dat/origin-patterns/index.toml` defines the canonical
        // order at recording time, but M1 doesn't yet emit one —
        // sorting by directory name is a stable fallback).
        if let Some(root) = embedded_root {
            if root.exists() {
                let mut libs: Vec<PathBuf> = fs::read_dir(root)
                    .map_err(|e| LoadError::Io {
                        path: root.to_path_buf(),
                        source: e,
                    })?
                    .filter_map(|entry| entry.ok().map(|e| e.path()))
                    .filter(|p| p.is_dir())
                    .collect();
                libs.sort();
                for lib_dir in libs {
                    let library_id = lib_dir
                        .file_name()
                        .and_then(|s| s.to_str())
                        .unwrap_or_default()
                        .to_string();
                    let mut toml_files: Vec<PathBuf> = fs::read_dir(&lib_dir)
                        .map_err(|e| LoadError::Io {
                            path: lib_dir.clone(),
                            source: e,
                        })?
                        .filter_map(|entry| entry.ok().map(|e| e.path()))
                        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("toml"))
                        .collect();
                    toml_files.sort();
                    for toml_path in toml_files {
                        let layer_rules =
                            load_file(&toml_path, "embedded", Some(library_id.clone()))?;
                        rules.extend(layer_rules);
                    }
                }
            }
        }

        // Layer 4: built-in catalogue --------------------------------
        rules.extend(built_in_catalogue());

        // Assign rule indices (1-based) for diagnostics.
        for (i, rule) in rules.iter_mut().enumerate() {
            rule.rule_index = i + 1;
        }
        let fingerprint = fingerprint_rules(&rules);
        Ok(PatternSet { rules, fingerprint })
    }
}

fn fingerprint_rules(rules: &[PatternRule]) -> PatternFingerprint {
    // Hashing strategy: SHA-256 over the concatenation of
    // (layer | kind | language | matcher.raw | continuation.raw)
    // separated by NUL bytes. This is deterministic across machines
    // because we never include filesystem paths or file mtimes — only
    // the canonical pattern semantics.
    let mut hasher = Sha256::new();
    for rule in rules {
        hasher.update(rule.provenance.layer.as_bytes());
        hasher.update([0u8]);
        hasher.update(rule.kind.table_name().as_bytes());
        hasher.update([0u8]);
        let mut langs: Vec<&str> = rule.languages.iter().map(|l| l.canonical_name()).collect();
        langs.sort();
        for lang in langs {
            hasher.update(lang.as_bytes());
            hasher.update([0u8]);
        }
        hasher.update(rule.matcher.raw.as_bytes());
        hasher.update([0u8]);
        if let Some(continuation) = &rule.continuation {
            hasher.update(continuation.raw.as_bytes());
        }
        hasher.update([0xFFu8]);
    }
    let digest = hasher.finalize();
    PatternFingerprint {
        hex: hex_encode(&digest),
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(char::from_digit((byte >> 4) as u32, 16).unwrap());
        out.push(char::from_digit((byte & 0x0F) as u32, 16).unwrap());
    }
    out
}

// ---------------------------------------------------------------------------
// TOML loading
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct TomlFile {
    #[serde(default)]
    forwarder: Vec<TomlRule>,
    #[serde(default)]
    trivial_copy: Vec<TomlRule>,
    #[serde(default)]
    computational: Vec<TomlRule>,
}

#[derive(Debug, Deserialize)]
struct TomlRule {
    #[serde(rename = "match")]
    match_expr: String,
    #[serde(default)]
    continuation: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    language: Option<String>,
    /// Optional explicit kind override; rarely used.
    #[serde(default)]
    kind: Option<String>,
}

fn load_file(
    path: &Path,
    layer: &str,
    library: Option<String>,
) -> Result<Vec<PatternRule>, LoadError> {
    let text = fs::read_to_string(path).map_err(|e| LoadError::Io {
        path: path.to_path_buf(),
        source: e,
    })?;
    let parsed: TomlFile = toml::from_str(&text).map_err(|e| LoadError::Toml {
        path: path.to_path_buf(),
        source: e,
    })?;
    let mut out = Vec::new();
    let mut local_idx = 0usize;
    let sections = [
        (PatternKind::Forwarder, &parsed.forwarder),
        (PatternKind::TrivialCopy, &parsed.trivial_copy),
        (PatternKind::Computational, &parsed.computational),
    ];
    for (kind, rules) in sections {
        for rule in rules {
            local_idx += 1;
            let matcher = parse_matcher(&rule.match_expr).map_err(|e| LoadError::Matcher {
                path: path.to_path_buf(),
                rule_index: local_idx,
                source: e,
            })?;
            let continuation = match &rule.continuation {
                Some(text) => Some(parse_continuation(text).map_err(|e| LoadError::Matcher {
                    path: path.to_path_buf(),
                    rule_index: local_idx,
                    source: e,
                })?),
                None => None,
            };
            // Spec §7.4: pattern whose continuation references an
            // undeclared capture MUST be rejected at load time.
            if let Some(cont) = &continuation {
                let mut captures = HashSet::new();
                matcher.root.collect_captures(&mut captures);
                if !captures.contains(&cont.capture) {
                    return Err(LoadError::UndeclaredContinuation {
                        path: path.to_path_buf(),
                        rule_index: local_idx,
                        capture: cont.capture.clone(),
                        declared: captures.into_iter().collect(),
                    });
                }
            }
            let origin_kind = match rule.kind.as_deref() {
                Some("trivial_copy") => OriginKind::TrivialCopy,
                Some("computational") => OriginKind::Computational,
                Some("field_access") => OriginKind::FieldAccess,
                Some("index_access") => OriginKind::IndexAccess,
                Some("function_call") => OriginKind::FunctionCall,
                Some(other) => {
                    return Err(LoadError::UnknownKind {
                        path: path.to_path_buf(),
                        rule_index: local_idx,
                        kind: other.to_string(),
                    });
                }
                None => kind.default_origin(),
            };
            let languages = match rule.language.as_deref() {
                Some(name) => match Lang::from_canonical_name(name) {
                    Some(lang) => vec![lang],
                    None => {
                        return Err(LoadError::UnknownLanguage {
                            path: path.to_path_buf(),
                            rule_index: local_idx,
                            language: name.to_string(),
                        });
                    }
                },
                None => Vec::new(),
            };
            out.push(PatternRule {
                matcher,
                kind,
                origin_kind,
                continuation,
                languages,
                provenance: PatternProvenance {
                    layer: layer.to_string(),
                    description: rule.description.clone(),
                    library: library.clone(),
                    source_path: Some(path.to_path_buf()),
                },
                rule_index: 0, // filled in by PatternSet
            });
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Matcher parser
// ---------------------------------------------------------------------------
//
// We parse a small expression grammar covering the shapes that appear
// in spec §7.3 + the M0 ANSWERS.md fixtures:
//
//   expr      := primary postfix*
//   primary   := capture | wildcard | identifier | path | '(' expr ')'
//   postfix   := '.' method-or-attr | '(' arglist? ')' | '[' expr ']'
//   method-or-attr := identifier ('(' arglist? ')')?
//   arglist   := expr (',' expr)*
//   capture   := '$' identifier
//   wildcard  := '$_'
//   identifier := [A-Za-z_][A-Za-z0-9_]*
//   path      := identifier ('::' identifier)+
//
// The parser is deliberately permissive: anything we don't recognise
// becomes a `MatcherError::UnexpectedToken` carrying offset
// information; the load layer wraps it with file + rule context.

#[derive(Debug, Clone, thiserror::Error)]
pub enum MatcherError {
    #[error("unexpected token {token:?} at offset {offset}")]
    UnexpectedToken { token: String, offset: usize },
    #[error("unexpected end of expression at offset {offset}")]
    UnexpectedEnd { offset: usize },
    #[error("continuation expression {raw:?} must name a single capture")]
    InvalidContinuation { raw: String },
}

fn parse_matcher(raw: &str) -> Result<MatcherExpr, MatcherError> {
    let mut parser = MatcherParser::new(raw);
    let root = parser.parse_expr()?;
    parser.skip_ws();
    if parser.pos < parser.input.len() {
        return Err(MatcherError::UnexpectedToken {
            token: parser.input[parser.pos..].chars().take(8).collect(),
            offset: parser.pos,
        });
    }
    Ok(MatcherExpr {
        root,
        raw: raw.to_owned(),
    })
}

fn parse_continuation(raw: &str) -> Result<ContinuationExpr, MatcherError> {
    let trimmed = raw.trim();
    if let Some(name) = trimmed.strip_prefix('$') {
        if !name.is_empty() && name.chars().all(is_ident_continue) {
            return Ok(ContinuationExpr {
                raw: trimmed.to_owned(),
                capture: name.to_owned(),
            });
        }
    }
    Err(MatcherError::InvalidContinuation {
        raw: raw.to_owned(),
    })
}

struct MatcherParser<'a> {
    input: &'a str,
    pos: usize,
}

impl<'a> MatcherParser<'a> {
    fn new(input: &'a str) -> Self {
        Self { input, pos: 0 }
    }

    fn skip_ws(&mut self) {
        while let Some(ch) = self.input[self.pos..].chars().next() {
            if ch.is_whitespace() {
                self.pos += ch.len_utf8();
            } else {
                break;
            }
        }
    }

    fn peek(&self) -> Option<char> {
        self.input[self.pos..].chars().next()
    }

    fn bump(&mut self) -> Option<char> {
        let ch = self.peek()?;
        self.pos += ch.len_utf8();
        Some(ch)
    }

    fn parse_expr(&mut self) -> Result<MatcherNode, MatcherError> {
        let mut node = self.parse_primary()?;
        loop {
            self.skip_ws();
            match self.peek() {
                Some('.') => {
                    self.bump();
                    let name = self.parse_identifier()?;
                    self.skip_ws();
                    if self.peek() == Some('(') {
                        self.bump();
                        let args = self.parse_arglist()?;
                        self.expect(')')?;
                        node = MatcherNode::Method {
                            receiver: Box::new(node),
                            method: name,
                            args,
                        };
                    } else {
                        node = MatcherNode::Attribute {
                            receiver: Box::new(node),
                            attr: name,
                        };
                    }
                }
                Some('(') => {
                    self.bump();
                    let args = self.parse_arglist()?;
                    self.expect(')')?;
                    node = MatcherNode::Call {
                        callee: Box::new(node),
                        args,
                    };
                }
                Some('[') => {
                    self.bump();
                    let index = self.parse_expr()?;
                    self.expect(']')?;
                    node = MatcherNode::Index {
                        receiver: Box::new(node),
                        index: Box::new(index),
                    };
                }
                _ => break,
            }
        }
        Ok(node)
    }

    fn parse_primary(&mut self) -> Result<MatcherNode, MatcherError> {
        self.skip_ws();
        match self.peek() {
            Some('$') => {
                self.bump();
                let name = self.parse_identifier()?;
                if name == "_" {
                    Ok(MatcherNode::Wildcard)
                } else {
                    Ok(MatcherNode::Capture(name))
                }
            }
            Some('(') => {
                self.bump();
                let inner = self.parse_expr()?;
                self.expect(')')?;
                Ok(inner)
            }
            Some(ch) if is_ident_start(ch) => {
                let first = self.parse_identifier()?;
                // Look ahead for `::` path segments.
                let mut segments = vec![first];
                loop {
                    self.skip_ws();
                    if self.input[self.pos..].starts_with("::") {
                        self.pos += 2;
                        segments.push(self.parse_identifier()?);
                    } else {
                        break;
                    }
                }
                if segments.len() == 1 {
                    Ok(MatcherNode::Identifier(
                        segments.into_iter().next().unwrap(),
                    ))
                } else {
                    Ok(MatcherNode::Path(segments))
                }
            }
            Some(other) => Err(MatcherError::UnexpectedToken {
                token: other.to_string(),
                offset: self.pos,
            }),
            None => Err(MatcherError::UnexpectedEnd { offset: self.pos }),
        }
    }

    fn parse_arglist(&mut self) -> Result<Vec<MatcherNode>, MatcherError> {
        let mut args = Vec::new();
        self.skip_ws();
        if self.peek() == Some(')') {
            return Ok(args);
        }
        loop {
            args.push(self.parse_expr()?);
            self.skip_ws();
            if self.peek() == Some(',') {
                self.bump();
            } else {
                break;
            }
        }
        Ok(args)
    }

    fn parse_identifier(&mut self) -> Result<String, MatcherError> {
        self.skip_ws();
        let start = self.pos;
        match self.peek() {
            Some(ch) if is_ident_start(ch) => {
                self.bump();
            }
            Some(other) => {
                return Err(MatcherError::UnexpectedToken {
                    token: other.to_string(),
                    offset: self.pos,
                });
            }
            None => return Err(MatcherError::UnexpectedEnd { offset: self.pos }),
        }
        while let Some(ch) = self.peek() {
            if is_ident_continue(ch) {
                self.bump();
            } else {
                break;
            }
        }
        Ok(self.input[start..self.pos].to_string())
    }

    fn expect(&mut self, ch: char) -> Result<(), MatcherError> {
        self.skip_ws();
        match self.peek() {
            Some(actual) if actual == ch => {
                self.bump();
                Ok(())
            }
            Some(other) => Err(MatcherError::UnexpectedToken {
                token: other.to_string(),
                offset: self.pos,
            }),
            None => Err(MatcherError::UnexpectedEnd { offset: self.pos }),
        }
    }
}

fn is_ident_start(ch: char) -> bool {
    ch.is_ascii_alphabetic() || ch == '_'
}

fn is_ident_continue(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '_'
}

// ---------------------------------------------------------------------------
// Built-in catalogue (spec §7.3)
// ---------------------------------------------------------------------------

fn built_in_catalogue() -> Vec<PatternRule> {
    let mut rules = Vec::new();
    let mut push = |matcher_text: &str,
                    kind: PatternKind,
                    continuation: Option<&str>,
                    languages: Vec<Lang>,
                    description: &str| {
        let matcher = parse_matcher(matcher_text).expect("built-in matcher must parse");
        let continuation =
            continuation.map(|t| parse_continuation(t).expect("built-in continuation must parse"));
        rules.push(PatternRule {
            matcher,
            kind,
            origin_kind: kind.default_origin(),
            continuation,
            languages,
            provenance: PatternProvenance {
                layer: "built-in".to_string(),
                description: Some(description.to_string()),
                library: None,
                source_path: None,
            },
            rule_index: 0,
        });
    };

    // Rust forwarders ---------------------------------------------------
    push(
        "$x.clone()",
        PatternKind::Forwarder,
        Some("$x"),
        vec![Lang::Rust],
        "Rust .clone() forwards the receiver",
    );
    push(
        "$x.to_owned()",
        PatternKind::Forwarder,
        Some("$x"),
        vec![Lang::Rust],
        "Rust .to_owned() forwards the receiver",
    );
    push(
        "$x.into()",
        PatternKind::Forwarder,
        Some("$x"),
        vec![Lang::Rust],
        "Rust .into() forwards the receiver",
    );
    push(
        "Box::new($x)",
        PatternKind::Forwarder,
        Some("$x"),
        vec![Lang::Rust],
        "Box::new wraps without transforming",
    );
    push(
        "Rc::new($x)",
        PatternKind::Forwarder,
        Some("$x"),
        vec![Lang::Rust],
        "Rc::new wraps without transforming",
    );
    push(
        "Arc::new($x)",
        PatternKind::Forwarder,
        Some("$x"),
        vec![Lang::Rust],
        "Arc::new wraps without transforming",
    );

    // Ruby forwarders ---------------------------------------------------
    push(
        "$x.dup",
        PatternKind::Forwarder,
        Some("$x"),
        vec![Lang::Ruby],
        "Ruby #dup forwards the receiver",
    );
    push(
        "$x.clone",
        PatternKind::Forwarder,
        Some("$x"),
        vec![Lang::Ruby],
        "Ruby #clone forwards the receiver",
    );

    // Python forwarders -------------------------------------------------
    push(
        "copy.deepcopy($x)",
        PatternKind::Forwarder,
        Some("$x"),
        vec![Lang::Python],
        "Python copy.deepcopy forwards the argument",
    );
    push(
        "copy.copy($x)",
        PatternKind::Forwarder,
        Some("$x"),
        vec![Lang::Python],
        "Python copy.copy forwards the argument",
    );

    // C++ forwarders ----------------------------------------------------
    push(
        "std::move($x)",
        PatternKind::Forwarder,
        Some("$x"),
        vec![Lang::Cpp],
        "C++ std::move forwards its argument",
    );

    // C forwarder -- memcpy `$src` is the continuation (spec §7.3 row).
    push(
        "memcpy($_, $src, $_)",
        PatternKind::Forwarder,
        Some("$src"),
        vec![Lang::C, Lang::Cpp],
        "memcpy forwards the source argument",
    );
    push(
        "atomic_load($src)",
        PatternKind::Forwarder,
        Some("$src"),
        vec![Lang::C, Lang::Cpp],
        "C atomic_load forwards the loaded object",
    );

    // Nim forwarder example from spec §7.3 (the user-extension hook).
    push(
        "assign_value($x)",
        PatternKind::Forwarder,
        Some("$x"),
        vec![Lang::Nim],
        "Nim assign_value forwards its argument",
    );

    rules
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum LoadError {
    #[error("reading pattern file {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("parsing TOML in {path}: {source}")]
    Toml {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },
    #[error("invalid matcher in {path} (rule #{rule_index}): {source}")]
    Matcher {
        path: PathBuf,
        rule_index: usize,
        #[source]
        source: MatcherError,
    },
    #[error(
        "continuation references undeclared capture ${capture} in {path} (rule #{rule_index}); \
         declared captures: {declared:?}"
    )]
    UndeclaredContinuation {
        path: PathBuf,
        rule_index: usize,
        capture: String,
        declared: Vec<String>,
    },
    #[error("unknown classification kind {kind:?} in {path} (rule #{rule_index})")]
    UnknownKind {
        path: PathBuf,
        rule_index: usize,
        kind: String,
    },
    #[error("unknown language {language:?} in {path} (rule #{rule_index})")]
    UnknownLanguage {
        path: PathBuf,
        rule_index: usize,
        language: String,
    },
}
