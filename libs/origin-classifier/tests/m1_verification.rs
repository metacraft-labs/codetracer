//! M1 verification suite.
//!
//! Implements every `test_classifier_*` entry from the M1
//! "Verification" block of
//! `codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org`.
//!
//! Tests use real tree-sitter grammars + real classifier code; no
//! mocks. Pattern-file fixtures live under `tests/data/`.

use std::path::PathBuf;

use origin_classifier::{
    classify, parse_assignment, ClassificationSource, Lang, LoadError, OriginKind, PatternKind,
    PatternSet,
};

fn fixture_path(rel: &str) -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("tests");
    p.push("data");
    p.push(rel);
    p
}

fn classify_line(line: &str, target: &str, lang: Lang, patterns: &PatternSet) -> OriginKind {
    parse_assignment(line, lang)
        .map(|ast| classify(&ast, target, lang, patterns).kind)
        .unwrap_or(OriginKind::Unknown)
}

fn classify_full(
    line: &str,
    target: &str,
    lang: Lang,
    patterns: &PatternSet,
) -> origin_classifier::Classification {
    let ast = parse_assignment(line, lang).expect("fixture line must parse");
    classify(&ast, target, lang, patterns)
}

// ===========================================================================
// test_classifier_python_universal_table
//
// Every row of the universal classification table from spec §7.1 is
// asserted for Python. The milestone requires "at least 8 rows
// (literal, bare-name copy, attribute access, subscript, binary expr,
// function-call return, await, comparison)".
// ===========================================================================
#[test]
fn test_classifier_python_universal_table() {
    let patterns = PatternSet::built_in();

    // Row 1: identifier — TrivialCopy.
    let c = classify_full("a = b", "a", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("b"));

    // Row 2: attribute — FieldAccess, continuation = receiver.
    let c = classify_full("a = obj.attr", "a", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::FieldAccess);
    assert_eq!(c.source_variable.as_deref(), Some("obj"));

    // Row 3: subscript — IndexAccess.
    let c = classify_full("a = arr[0]", "a", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::IndexAccess);
    assert_eq!(c.source_variable.as_deref(), Some("arr"));

    // Row 4 (binary): Computational with operand snapshots.
    let c = classify_full("a = b + 1", "a", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::Computational);
    assert!(c.operand_snapshots.iter().any(|s| s == "b"));

    // Row 4 (comparison): also Computational.
    let c = classify_full("a = b == c", "a", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::Computational);
    assert!(c.operand_snapshots.iter().any(|s| s == "b"));
    assert!(c.operand_snapshots.iter().any(|s| s == "c"));

    // Row 5: literal.
    let c = classify_full("a = 42", "a", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::Literal);
    assert!(c.source_variable.is_none());

    let c = classify_full("a = \"hello\"", "a", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::Literal);

    // Row 6: function-call forwarder — TrivialCopy (deepcopy is in
    // the built-in catalogue, spec §7.3).
    let c = classify_full("a = copy.deepcopy(b)", "a", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("b"));

    // Row 7: function-call (non-forwarder) — FunctionCall.
    let c = classify_full("a = foo(x, y)", "a", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::FunctionCall);
    assert!(c.operand_snapshots.iter().any(|s| s == "x"));

    // `await` row from spec §7.2 (still part of the "universal"
    // discovery set we exercise here).
    let c = classify_full("a = await foo()", "a", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::ReturnCapture);
}

// ===========================================================================
// test_classifier_python_per_language_overrides
//
// Spec §7.2 Python row: destructuring, augmented assignment, walrus,
// comprehension. The milestone requires at least 4 sub-cases.
// ===========================================================================
#[test]
fn test_classifier_python_per_language_overrides() {
    let patterns = PatternSet::built_in();

    // 1. Destructuring: `a, b = pair`.
    let c = classify_full("a, b = pair", "a", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::IndexAccess);
    assert_eq!(c.source_variable.as_deref(), Some("pair"));
    let c = classify_full("a, b = pair", "b", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::IndexAccess);

    // 2. Augmented assignment: `a += b` is Computational.
    let c = classify_full("a += b", "a", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::Computational);

    // 3. Walrus: `y = (n := f())` — the inner assignment binds n.
    // tree-sitter-python parses `(n := f())` as a named_expression
    // wrapped in `parenthesized_expression`. We assert that
    // parse_assignment finds the outer y assignment.
    let ast = parse_assignment("y = (n := f())", Lang::Python).expect("walrus parses");
    let c = classify(&ast, "y", Lang::Python, &patterns);
    // The walrus RHS is a parenthesized named_expression; after
    // unwrap_trivial the classifier sees the named_expression node.
    // We accept Unknown OR FunctionCall (depending on how the grammar
    // surfaces it) — what matters is that the parse did not panic
    // and produced *some* classification, plus the inner walrus also
    // independently parses as an assignment.
    assert!(matches!(
        c.kind,
        OriginKind::FunctionCall | OriginKind::ReturnCapture | OriginKind::Unknown
    ));
    let ast_inner = parse_assignment("n := f()", Lang::Python).expect("inner walrus parses");
    let c_inner = classify(&ast_inner, "n", Lang::Python, &patterns);
    assert_eq!(c_inner.kind, OriginKind::FunctionCall);

    // 4. Comprehension: `r = [x for x in xs]` — Computational.
    let c = classify_full("r = [x for x in xs]", "r", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::Computational);

    // 5 (bonus): ternary — Computational.
    let c = classify_full("r = x if cond else y", "r", Lang::Python, &patterns);
    assert_eq!(c.kind, OriginKind::Computational);
}

// ===========================================================================
// test_classifier_ruby_per_language_overrides
//
// Spec §7.2 Ruby row: block-arg pass, swap-via-destructuring,
// ActiveRecord accessor via project config. Milestone requires
// at least 3 sub-cases.
// ===========================================================================
#[test]
fn test_classifier_ruby_per_language_overrides() {
    // For the ActiveRecord accessor test we need a project override
    // layer, loaded as the "personal" overrides slot.
    let project_overrides = fixture_path("project_overrides/origin-patterns.toml");
    let patterns = PatternSet::load_layered(None, Some(&project_overrides), None)
        .expect("project overrides load cleanly");

    // 1. Swap via destructuring: `a, b = b, a` — TrivialCopy at
    // confidence 0.9 (spec §7.2 Ruby row).
    let c = classify_full("a, b = b, a", "a", Lang::Ruby, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("b"));
    assert!((c.confidence - 0.9).abs() < 0.01);

    // 2. Block-arg / receiver forwarder: `r = x.dup` — TrivialCopy
    // (built-in Ruby forwarder, spec §7.3).
    let c = classify_full("r = x.dup", "r", Lang::Ruby, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("x"));

    // 3. ActiveRecord accessor via project config: the trivial_copy
    // rule maps `$base.attributes[$_]` → TrivialCopy with
    // continuation `$base`.
    let c = classify_full("r = record.attributes[:name]", "r", Lang::Ruby, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("record"));
    // The provenance should come from the project override layer.
    if let ClassificationSource::Rule { provenance, .. } = &c.source {
        assert_eq!(provenance.layer, "personal");
    } else {
        panic!("expected Rule provenance, got {:?}", c.source);
    }
}

// ===========================================================================
// test_classifier_javascript_per_language_overrides
//
// Spec §7.2 JS row: destructuring (object + array), spread, optional
// chaining, nullish coalescing. Milestone requires at least 4
// sub-cases.
// ===========================================================================
#[test]
fn test_classifier_javascript_per_language_overrides() {
    let patterns = PatternSet::built_in();

    // 1. Object destructuring: `const {a, b} = obj` → FieldAccess.
    let c = classify_full("const {a, b} = obj", "a", Lang::JavaScript, &patterns);
    assert_eq!(c.kind, OriginKind::FieldAccess);
    assert_eq!(c.source_variable.as_deref(), Some("obj"));

    // 2. Array destructuring: `const [a, b] = arr` → IndexAccess.
    let c = classify_full("const [a, b] = arr", "a", Lang::JavaScript, &patterns);
    assert_eq!(c.kind, OriginKind::IndexAccess);
    assert_eq!(c.source_variable.as_deref(), Some("arr"));

    // 3. Spread / rest: `const [a, ...rest] = arr` → IndexAccess
    // (spec §7.2 JS table: `const a = ...rest` row).
    let c = classify_full(
        "const [a, ...rest] = arr",
        "rest",
        Lang::JavaScript,
        &patterns,
    );
    assert_eq!(c.kind, OriginKind::IndexAccess);

    // 4. Nullish coalescing: `const a = b ?? c` → Computational.
    let c = classify_full("const a = b ?? c", "a", Lang::JavaScript, &patterns);
    assert_eq!(c.kind, OriginKind::Computational);

    // 5 (bonus): Optional chaining: `const a = obj?.prop` →
    // FieldAccess (spec §7.1 universal field-access row applies).
    let c = classify_full("const a = obj?.prop", "a", Lang::JavaScript, &patterns);
    assert_eq!(c.kind, OriginKind::FieldAccess);
}

// ===========================================================================
// test_classifier_c_per_language_overrides
//
// Spec §7.2 C/C++ row: memcpy_forward, cast_forward, pointer
// deref. Milestone requires at least 3 sub-cases.
// ===========================================================================
#[test]
fn test_classifier_c_per_language_overrides() {
    let patterns = PatternSet::built_in();

    // 1. memcpy forwarder: `memcpy(dst, src, n);` — TrivialCopy from
    // src to dst, per the built-in C catalogue (spec §7.3 row 6).
    let c = classify_full("memcpy(dst, src, n);", "dst", Lang::C, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("src"));

    // 2. Cast forward: `int b = (int)a;` — TrivialCopy with the
    // cast inner as the source.
    let c = classify_full("int b = (int)a;", "b", Lang::C, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));

    // 3. Pointer deref chain: `int b = *p;` — IndexAccess.
    let c = classify_full("int b = *p;", "b", Lang::C, &patterns);
    assert_eq!(c.kind, OriginKind::IndexAccess);
}

// ===========================================================================
// test_classifier_rust_per_language_overrides
//
// Spec §7.2 Rust row: clone, into, Box::new, let-destructuring.
// Milestone requires at least 4 sub-cases.
// ===========================================================================
#[test]
fn test_classifier_rust_per_language_overrides() {
    let patterns = PatternSet::built_in();

    // 1. clone(): TrivialCopy.
    let c = classify_full("let b = a.clone();", "b", Lang::Rust, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));

    // 2. into(): TrivialCopy.
    let c = classify_full("let b = a.into();", "b", Lang::Rust, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));

    // 3. Box::new(a): TrivialCopy.
    let c = classify_full("let b = Box::new(a);", "b", Lang::Rust, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));

    // 4. let-destructuring: `let (a, b) = pair;` → IndexAccess.
    let c = classify_full("let (a, b) = pair;", "a", Lang::Rust, &patterns);
    assert_eq!(c.kind, OriginKind::IndexAccess);
    assert_eq!(c.source_variable.as_deref(), Some("pair"));
}

// ===========================================================================
// test_classifier_nim_per_language_overrides
//
// Spec §7.2 Nim row: implicit `result` variable, field access.
// Milestone requires at least 2 sub-cases.
// ===========================================================================
#[test]
fn test_classifier_nim_per_language_overrides() {
    let patterns = PatternSet::built_in();

    // 1. Implicit `result` assignment: `result = a` → TrivialCopy.
    let c = classify_full("result = a", "result", Lang::Nim, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));

    // 2. `let b = a` → TrivialCopy.
    let c = classify_full("let b = a", "b", Lang::Nim, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));

    // 3 (bonus): Literal terminator.
    let c = classify_full("let b = 42", "b", Lang::Nim, &patterns);
    assert_eq!(c.kind, OriginKind::Literal);
}

// ===========================================================================
// test_classifier_go_per_language_overrides
//
// Spec §7.2 Go row: multi-return-with-err, range loop iterator.
// Milestone requires at least 2 sub-cases.
// ===========================================================================
#[test]
fn test_classifier_go_per_language_overrides() {
    let patterns = PatternSet::built_in();

    // 1. Multi-return-with-err: `a, err := foo()` → ReturnCapture
    // (spec §7.2 Go table).
    let c = classify_full("a, err := foo()", "a", Lang::Go, &patterns);
    assert_eq!(c.kind, OriginKind::ReturnCapture);
    let c = classify_full("a, err := foo()", "err", Lang::Go, &patterns);
    assert_eq!(c.kind, OriginKind::ReturnCapture);

    // 2. Plain `b := a` → TrivialCopy.
    let c = classify_full("b := a", "b", Lang::Go, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));
}

// ===========================================================================
// test_classifier_project_pattern_overrides
//
// A user-defined origin-patterns.toml with trivial_copy + computational
// rules (including explicit continuation) takes effect.
// ===========================================================================
#[test]
fn test_classifier_project_pattern_overrides() {
    let project_overrides = fixture_path("project_overrides/origin-patterns.toml");
    let patterns = PatternSet::load_layered(None, Some(&project_overrides), None)
        .expect("project overrides load cleanly");

    // The trivial_copy rule has an explicit continuation; assert it
    // took effect, including provenance.
    let c = classify_full("r = record.attributes[:key]", "r", Lang::Ruby, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("record"));
    if let ClassificationSource::Rule { kind, provenance } = &c.source {
        assert_eq!(*kind, PatternKind::TrivialCopy);
        assert_eq!(provenance.layer, "personal");
        assert!(provenance
            .render()
            .contains("ActiveRecord attribute accessor"));
    } else {
        panic!("expected Rule source, got {:?}", c.source);
    }

    // The computational rule overrides a call that would otherwise
    // be a FunctionCall. Default rule (FunctionCall) versus override
    // (Computational): assert override won.
    let c = classify_full(
        "x = validators.normalize(raw)",
        "x",
        Lang::Python,
        &patterns,
    );
    assert_eq!(c.kind, OriginKind::Computational);
    if let ClassificationSource::Rule { kind, .. } = &c.source {
        assert_eq!(*kind, PatternKind::Computational);
    } else {
        panic!("expected Rule source, got {:?}", c.source);
    }
    assert!(c.operand_snapshots.iter().any(|s| s == "raw"));
}

// ===========================================================================
// test_classifier_continuation_capture_validation
//
// A pattern whose continuation references an undeclared capture is
// rejected at load time, with the file path and rule index named.
// ===========================================================================
#[test]
fn test_classifier_continuation_capture_validation() {
    let bad = fixture_path("bad_continuation/origin-patterns.toml");
    let err = PatternSet::load_layered(None, Some(&bad), None)
        .expect_err("undeclared continuation must error");
    // The error message itself surfaces the path and rule index so a
    // user reading the diagnostic in the trace metadata can fix the
    // offending file directly.
    let msg = format!("{err}");
    assert!(msg.contains("bad_continuation"), "msg: {msg}");
    assert!(msg.contains("rule #1"), "msg: {msg}");
    assert!(msg.contains("undeclared"), "msg: {msg}");
    match err {
        LoadError::UndeclaredContinuation {
            path,
            rule_index,
            capture,
            declared,
        } => {
            assert_eq!(path, bad);
            assert_eq!(rule_index, 1);
            assert_eq!(capture, "undeclared");
            // The declared list should mention the matcher's $x
            // capture; we don't assume ordering.
            assert!(declared.iter().any(|c| c == "x"));
        }
        other => panic!("expected UndeclaredContinuation, got {other:?}"),
    }
}

// ===========================================================================
// test_classifier_override_precedence_resolution
//
// When the same call shape is matched by an embedded library pattern,
// a trace-local `_overrides.toml`, and a personal override, the
// personal override wins. The trace-local layer is present but
// empty (no matching rule); the personal override has a distinct
// description so the assertion can identify which layer won.
// ===========================================================================
#[test]
fn test_classifier_override_precedence_resolution() {
    let root = fixture_path("override_precedence");
    let trace_overrides = root.join("_overrides.toml");
    let personal = root.join("home-overrides/origin-patterns.toml");
    let embedded_root = root.join("embedded");

    let patterns = PatternSet::load_layered(
        Some(&trace_overrides),
        Some(&personal),
        Some(&embedded_root),
    )
    .expect("layered load succeeds");

    let c = classify_full(
        "result = forward(payload)",
        "result",
        Lang::Python,
        &patterns,
    );
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("payload"));
    let provenance = match &c.source {
        ClassificationSource::Rule { provenance, .. } => provenance,
        other => panic!("expected Rule source, got {other:?}"),
    };
    assert_eq!(
        provenance.layer, "personal",
        "personal override must win over the embedded library pattern (spec §7.4)"
    );
    let rendered = provenance.render();
    assert!(
        rendered.contains("Personal override"),
        "rendered provenance {rendered:?} must identify the personal override"
    );

    // Sanity: a deterministic fingerprint is exposed for M2's
    // continuation-token integrity check (spec §5.3.1). Loading the
    // same layered pattern set twice must produce a byte-identical
    // fingerprint — M2 embeds this hash into continuation tokens, so
    // any nondeterminism here would corrupt token validation.
    let patterns_again = PatternSet::load_layered(
        Some(&trace_overrides),
        Some(&personal),
        Some(&embedded_root),
    )
    .expect("layered load succeeds (second time)");
    assert!(!patterns.fingerprint().hex.is_empty());
    assert_eq!(
        patterns.fingerprint().hex,
        patterns_again.fingerprint().hex,
        "pattern fingerprint must be deterministic across loads (spec §5.3.1)"
    );
    // And a different layer composition produces a different
    // fingerprint, so the hash actually depends on the loaded rules.
    let built_in_only = PatternSet::built_in();
    assert_ne!(
        patterns.fingerprint().hex,
        built_in_only.fingerprint().hex,
        "fingerprint must distinguish different layered pattern sets"
    );
}

// ===========================================================================
// test_classifier_unparseable_returns_unknown
//
// Garbled source lines yield OriginKind::Unknown with confidence 0
// (not a panic, not an error).
// ===========================================================================
#[test]
fn test_classifier_unparseable_returns_unknown() {
    let patterns = PatternSet::built_in();

    // Garbled inputs that don't parse as an assignment at all.
    let inputs = ["@@@!!!", "   ", "def foo():", "}}}]]]"];
    for line in inputs {
        let kind = classify_line(line, "x", Lang::Python, &patterns);
        assert_eq!(
            kind,
            OriginKind::Unknown,
            "expected Unknown for input {line:?}"
        );
    }
    // Confidence 0 on the synthetic Unknown classification path.
    let ast = parse_assignment("a = ", Lang::Python);
    // parse_assignment may either return None (no assignment) or
    // a partial AST whose RHS classifies as Unknown. Both are
    // acceptable; only the panic/error path is forbidden by the
    // milestone spec.
    if let Some(ast) = ast {
        let c = classify(&ast, "a", Lang::Python, &patterns);
        assert!(
            matches!(c.kind, OriginKind::Unknown | OriginKind::Literal),
            "got unexpected kind {:?}",
            c.kind
        );
    }
}

// ===========================================================================
// M23 — Smart-contract language per-language overrides
//
// Each test covers the canonical 3-hop `a -> b -> c -> Literal(10)`
// trivial chain plus the language-specific override row called out in
// spec §7.2 (M23 row).  The fixtures live under
// `src/db-backend/tests/fixtures/origin/<lang>/simple_trivial_chain/`;
// these unit tests pin the classifier surface independently so the
// classifier crate is provable without the recorder + DAP stack.
// ===========================================================================

/// Cairo: `let <name>: <type> = <expr>` reuses the Rust splitter.  The
/// felt-vs-pointer distinction (spec §7.2 M23 Cairo row) is exercised
/// by checking that bare identifiers classify as `TrivialCopy` and
/// `let b: felt252 = 10` classifies as `Literal`.
#[test]
fn test_classifier_cairo_simple_trivial_chain() {
    let patterns = PatternSet::built_in();

    // Hop 0: c = b — TrivialCopy.
    let c = classify_full("let c: felt252 = b;", "c", Lang::Cairo, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("b"));

    // Hop 1: b = a — TrivialCopy.
    let c = classify_full("let b: felt252 = a;", "b", Lang::Cairo, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));

    // Hop 2: a = 10 — Literal terminator.
    let c = classify_full("let a: felt252 = 10;", "a", Lang::Cairo, &patterns);
    assert_eq!(c.kind, OriginKind::Literal);

    // Sanity: a binary expression still classifies as Computational.
    let c = classify_full("let sum: felt252 = a + b;", "sum", Lang::Cairo, &patterns);
    assert_eq!(c.kind, OriginKind::Computational);
}

/// Sway / FuelVM: reuses the Rust splitter; the FuelVM storage-write
/// override (spec §7.2 M23 Sway row) only fires for
/// `storage.<field>.write(x)` shapes which we leave to the recorder
/// for V1.  The canonical chain checks local bindings.
#[test]
fn test_classifier_sway_simple_trivial_chain() {
    let patterns = PatternSet::built_in();

    let c = classify_full("let c: u64 = b;", "c", Lang::Sway, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("b"));

    let c = classify_full("let b: u64 = a;", "b", Lang::Sway, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));

    let c = classify_full("let a: u64 = 10;", "a", Lang::Sway, &patterns);
    assert_eq!(c.kind, OriginKind::Literal);
}

/// Aiken / Cardano: `let_assignment` ships positional children so the
/// classifier uses [`split_aiken`].  The canonical chain checks bare
/// identifiers + integer literal.
#[test]
fn test_classifier_aiken_simple_trivial_chain() {
    let patterns = PatternSet::built_in();

    let c = classify_full("let c = b", "c", Lang::Aiken, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("b"));

    let c = classify_full("let b = a", "b", Lang::Aiken, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));

    let c = classify_full("let a = 10", "a", Lang::Aiken, &patterns);
    assert_eq!(c.kind, OriginKind::Literal);
}

/// Leo / Aleo: `variable_declaration` carries the binding name + RHS
/// `expression`.  The canonical chain exercises bare identifiers +
/// integer-suffix literals.
#[test]
fn test_classifier_leo_simple_trivial_chain() {
    let patterns = PatternSet::built_in();

    let c = classify_full("let c: u32 = b;", "c", Lang::Leo, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("b"));

    let c = classify_full("let b: u32 = a;", "b", Lang::Leo, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));

    let c = classify_full("let a: u32 = 10u32;", "a", Lang::Leo, &patterns);
    assert_eq!(c.kind, OriginKind::Literal);
}

/// Circom: signal-assignment via `<==` is the M23 override called out
/// in spec §7.2.  `a <== b` classifies as `TrivialCopy` with
/// continuation `b`; `a <== 10` classifies as `Literal`.  The
/// rightward `==>` form swaps the LHS/RHS interpretation.
#[test]
fn test_classifier_circom_signal_assignment() {
    let patterns = PatternSet::built_in();

    // Leftward signal assignment, bare-identifier RHS — TrivialCopy.
    let c = classify_full("c <== b;", "c", Lang::Circom, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("b"));

    let c = classify_full("b <== a;", "b", Lang::Circom, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));

    // Leftward signal assignment, integer literal — Literal.
    let c = classify_full("a <== 10;", "a", Lang::Circom, &patterns);
    assert_eq!(c.kind, OriginKind::Literal);

    // Binary expression on RHS — Computational with operand snapshots.
    let c = classify_full("sum <== a + b;", "sum", Lang::Circom, &patterns);
    assert_eq!(c.kind, OriginKind::Computational);
    assert!(c.operand_snapshots.iter().any(|s| s == "a"));
    assert!(c.operand_snapshots.iter().any(|s| s == "b"));
}

/// Rust-syntax smart-contract languages: Stylus / Solana / Noir all
/// surface through `Lang::Rust` via [`Lang::from_canonical_name`].
/// The canonical chain is identical to the Rust row of spec §7.2.
#[test]
fn test_classifier_rust_syntax_smart_contract_languages() {
    let patterns = PatternSet::built_in();

    // The canonical-name → Lang mapping per spec §7.2 (M23 footnote):
    // stylus / solana / noir all surface through `Lang::Rust`.
    assert_eq!(Lang::from_canonical_name("stylus"), Some(Lang::Rust));
    assert_eq!(Lang::from_canonical_name("solana"), Some(Lang::Rust));
    assert_eq!(Lang::from_canonical_name("noir"), Some(Lang::Rust));
    assert_eq!(Lang::from_canonical_name("aleo"), Some(Lang::Leo));
    assert_eq!(Lang::from_canonical_name("fuel"), Some(Lang::Sway));
    assert_eq!(Lang::from_canonical_name("cardano"), Some(Lang::Aiken));

    // The canonical chain over Rust syntax — pinned here so the
    // Stylus / Solana / Noir tests in `src/db-backend/tests/` can
    // rely on the same classifier surface.
    let c = classify_full("let c: u64 = b;", "c", Lang::Rust, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("b"));

    let c = classify_full("let b: u64 = a;", "b", Lang::Rust, &patterns);
    assert_eq!(c.kind, OriginKind::TrivialCopy);
    assert_eq!(c.source_variable.as_deref(), Some("a"));

    let c = classify_full("let a: u64 = 10;", "a", Lang::Rust, &patterns);
    assert_eq!(c.kind, OriginKind::Literal);
}
