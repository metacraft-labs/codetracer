//! Core enumerations: supported languages and origin classification kinds.
//!
//! These mirror the wire types sketched in spec §4.1 and §7.1; field
//! names are expected to drift during M1–M3 implementation (per the
//! spec's "provisional code" disclaimer in the milestones file
//! Introduction).

use std::fmt;

use tree_sitter::Language;

/// Languages whose assignment statements this crate can parse.
///
/// The V1 set per spec §7.2 covers Python, Ruby, JavaScript, C, C++,
/// Rust, Nim, Go. M23 extends the set with the smart-contract languages
/// that already ship a `*_flow_dap_test.rs` baseline (Cairo, Stylus,
/// Sway, Solana, Aiken, Leo, Circom, Noir). Their per-language
/// overrides live in spec §7.2; Stylus / Solana / Noir all compile down
/// to a Rust-syntax surface and reuse the [`Lang::Rust`] grammar
/// internally (no new `Lang` variant needed for them).  Cairo, Sway,
/// Aiken, Leo, and Circom have distinct tree-sitter grammars and so
/// surface as their own `Lang` variants.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Lang {
    Python,
    Ruby,
    JavaScript,
    C,
    Cpp,
    Rust,
    Nim,
    Go,
    /// Cairo / StarkNet — felt252-typed bindings; see spec §7.2 M23
    /// Cairo row (felt-vs-pointer distinction).
    Cairo,
    /// Sway / FuelVM — Rust-like surface syntax; see spec §7.2 M23
    /// Sway row (storage-write override).
    Sway,
    /// Aiken / Cardano — Rust-like surface syntax with pipeline-`|>`;
    /// see spec §7.2 M23 Aiken row.
    Aiken,
    /// Leo / Aleo — Rust-like surface syntax with record / circuit
    /// types; see spec §7.2 M23 Leo row.
    Leo,
    /// Circom — `<==` signal-assignment idiom; see spec §7.2 M23
    /// Circom row.  The classifier ships a dedicated splitter
    /// because Circom's `assignment_expression` exposes its
    /// children positionally rather than via `left`/`right`
    /// fields.
    Circom,
}

impl Lang {
    /// Return the tree-sitter [`Language`] for `self`. Used by the
    /// thin per-language parsers under [`crate::ast`].
    pub fn tree_sitter_language(self) -> Language {
        match self {
            Lang::Python => tree_sitter_python::LANGUAGE.into(),
            Lang::Ruby => tree_sitter_ruby::LANGUAGE.into(),
            Lang::JavaScript => tree_sitter_javascript::LANGUAGE.into(),
            Lang::C => tree_sitter_c::LANGUAGE.into(),
            Lang::Cpp => tree_sitter_cpp::LANGUAGE.into(),
            Lang::Rust => tree_sitter_rust::LANGUAGE.into(),
            Lang::Nim => tree_sitter_nim::LANGUAGE.into(),
            Lang::Go => tree_sitter_go::LANGUAGE.into(),
            Lang::Cairo => tree_sitter_cairo::LANGUAGE.into(),
            Lang::Sway => tree_sitter_sway::LANGUAGE.into(),
            Lang::Aiken => tree_sitter_aiken::LANGUAGE.into(),
            Lang::Leo => tree_sitter_leo::LANGUAGE.into(),
            Lang::Circom => tree_sitter_circom::LANGUAGE.into(),
        }
    }

    /// Canonical lowercase name used in pattern files (the `language`
    /// field of a TOML rule, see spec §7.4 "Pattern file schema").
    pub fn canonical_name(self) -> &'static str {
        match self {
            Lang::Python => "python",
            Lang::Ruby => "ruby",
            Lang::JavaScript => "javascript",
            Lang::C => "c",
            Lang::Cpp => "cpp",
            Lang::Rust => "rust",
            Lang::Nim => "nim",
            Lang::Go => "go",
            Lang::Cairo => "cairo",
            Lang::Sway => "sway",
            Lang::Aiken => "aiken",
            Lang::Leo => "leo",
            Lang::Circom => "circom",
        }
    }

    /// Parse the canonical name back into a `Lang`. Returns `None`
    /// for unrecognised names so pattern-file loaders can surface
    /// helpful diagnostics rather than panic.
    ///
    /// Smart-contract languages that reuse a sibling grammar map onto
    /// the sibling here so embedded pattern files written against
    /// "stylus" / "solana" / "noir" still resolve at load time:
    ///
    /// - `stylus`, `solana`, `noir` → [`Lang::Rust`] (Rust-syntax
    ///   surface; classifier rules already covered by the Rust row of
    ///   spec §7.2).
    /// - `aleo` → [`Lang::Leo`].
    pub fn from_canonical_name(name: &str) -> Option<Self> {
        Some(match name {
            "python" => Lang::Python,
            "ruby" => Lang::Ruby,
            "javascript" | "js" | "typescript" | "ts" => Lang::JavaScript,
            "c" => Lang::C,
            "cpp" | "c++" | "cxx" => Lang::Cpp,
            "rust" | "rs" => Lang::Rust,
            "nim" => Lang::Nim,
            "go" => Lang::Go,
            "cairo" => Lang::Cairo,
            "sway" | "fuel" => Lang::Sway,
            "aiken" | "cardano" => Lang::Aiken,
            "leo" | "aleo" => Lang::Leo,
            "circom" => Lang::Circom,
            // Smart-contract languages whose source surface IS Rust
            // (Stylus, Solana, Noir) — reuse the Rust splitter so
            // built-in patterns keyed on `language = "rust"` still
            // apply.  See spec §7.2 M23 rows for the override
            // semantics.
            "stylus" | "solana" | "noir" => Lang::Rust,
            _ => return None,
        })
    }
}

impl fmt::Display for Lang {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.canonical_name())
    }
}

/// The classification kind assigned to an assignment hop, mirroring
/// spec §4.1 and the universal table in §7.1.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OriginKind {
    /// Bare identifier copy (`b = a`), a forwarder call recognised as
    /// such (`b = a.clone()`), or a destructured tuple alias whose
    /// element is trivially aliased.
    TrivialCopy,
    /// Attribute / member access (`b = a.field`).
    FieldAccess,
    /// Indexed read (`b = a[i]`), pointer deref (`b = *p`), or
    /// destructured collection element.
    IndexAccess,
    /// Binary / unary / comparison / template-literal / generic
    /// "single-result computation". The RHS identifier leaves are the
    /// continuation set (operand snapshots).
    Computational,
    /// Function-call return whose callee is *not* a forwarder.
    /// Subtype of [`OriginKind::Computational`] in the chain view but
    /// surfaced distinctly so the UI can render "→ inside foo()".
    FunctionCall,
    /// A literal terminator (`42`, `"hi"`, `nil`, …).
    Literal,
    /// `result = await foo()` style (Python `await`, JS async/await,
    /// Rust `.await`, etc.). The chain crosses into another frame.
    ReturnCapture,
    /// Function parameter, written at entry to the current frame.
    ParameterPass,
    /// A hop that crosses a thread boundary (M14+). Surfaced now so
    /// the type space is closed.
    CrossThread,
    /// Garbled source, an unrecognised AST shape, or a deliberate
    /// "we don't know" terminator. The contract here is *no panic*:
    /// the classifier returns this rather than failing.
    Unknown,
}

impl OriginKind {
    /// True for kinds that participate in a backward chain via a
    /// single-source continuation (the next backward step targets one
    /// variable). False for terminators and for `Computational`
    /// kinds, which use the operand-snapshot continuation set.
    pub fn is_single_source(self) -> bool {
        matches!(
            self,
            OriginKind::TrivialCopy
                | OriginKind::FieldAccess
                | OriginKind::IndexAccess
                | OriginKind::ReturnCapture
                | OriginKind::ParameterPass
        )
    }

    /// True when the chain terminates at this hop with no further
    /// backward search (spec §6.1.6 "Recording-boundary terminators"
    /// covers the dynamic terminator cases; this method covers the
    /// static-classifier ones).
    pub fn is_terminator(self) -> bool {
        matches!(self, OriginKind::Literal | OriginKind::Unknown)
    }

    /// Canonical lowercase name used when serialising back into
    /// `pattern_provenance` metadata.
    pub fn canonical_name(self) -> &'static str {
        match self {
            OriginKind::TrivialCopy => "trivial_copy",
            OriginKind::FieldAccess => "field_access",
            OriginKind::IndexAccess => "index_access",
            OriginKind::Computational => "computational",
            OriginKind::FunctionCall => "function_call",
            OriginKind::Literal => "literal",
            OriginKind::ReturnCapture => "return_capture",
            OriginKind::ParameterPass => "parameter_pass",
            OriginKind::CrossThread => "cross_thread",
            OriginKind::Unknown => "unknown",
        }
    }
}

impl fmt::Display for OriginKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.canonical_name())
    }
}
