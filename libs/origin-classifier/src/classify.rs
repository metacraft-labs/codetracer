//! Classification: walk the parsed assignment's RHS and return an
//! [`OriginKind`] plus locators/metadata describing the next backward
//! step. Implements the universal classification table from spec §7.1
//! plus the per-language overrides from §7.2.
//!
//! Pattern matching against [`PatternSet`] happens first; if no
//! user-defined or built-in pattern matches, we fall through to the
//! universal table.

use std::collections::HashMap;

use tree_sitter::Node;

use crate::ast::{AssignmentAst, NodeLocator};
use crate::kinds::{Lang, OriginKind};
use crate::patterns::{MatcherNode, PatternKind, PatternProvenance, PatternSet};

/// Result of classifying one assignment.
///
/// Mirrors the milestone spec's required shape:
/// `(TargetNode, RhsNode, OriginKind, Option<source_variable>, confidence)`
/// plus the `pattern_provenance` data needed by the State Pane's
/// "Show pattern provenance" affordance (spec §7.4).
///
/// `Eq` is intentionally not derived because the confidence is a
/// finite-precision `f32` (NaN never appears here — the classifier
/// only ever sets compile-time constants — but the language doesn't
/// know that).
#[derive(Debug, Clone, PartialEq)]
pub struct Classification {
    /// Locator for the LHS sub-tree the classification applies to.
    /// For destructuring this is the specific element matching
    /// `target_name`, not the enclosing pattern.
    pub target: NodeLocator,
    /// Locator for the RHS sub-tree being classified.
    pub rhs: NodeLocator,
    /// Classification kind.
    pub kind: OriginKind,
    /// Single-variable continuation hint. For trivial-copy /
    /// field-access / index-access this names the next backward
    /// search target (e.g. `a` in `b = a`, or `payload` in
    /// `result = forward(payload)`).
    pub source_variable: Option<String>,
    /// Confidence ∈ [0.0, 1.0] per spec §6.1.5.
    pub confidence: f32,
    /// Where the classification came from (built-in universal table,
    /// built-in catalogue, or a user-defined pattern). Includes
    /// provenance text for the State Pane.
    pub source: ClassificationSource,
    /// For computational kinds: the set of operand-snapshot
    /// identifiers (identifier leaves under the RHS).
    pub operand_snapshots: Vec<String>,
}

/// Describes which rule resolved a classification.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClassificationSource {
    /// Universal table (spec §7.1). Carries the matched grammar node
    /// kind for diagnostics.
    UniversalTable { node_kind: String },
    /// Matched a [`PatternRule`] from the layered pattern set.
    Rule {
        kind: PatternKind,
        provenance: PatternProvenance,
    },
    /// Default terminator when nothing matched (spec §7.1 last row).
    Unknown,
}

impl ClassificationSource {
    /// Human-readable provenance string. Stable for test assertions.
    pub fn render_provenance(&self) -> String {
        match self {
            ClassificationSource::UniversalTable { node_kind } => {
                format!("built-in: universal table ({node_kind})")
            }
            ClassificationSource::Rule { provenance, .. } => provenance.render(),
            ClassificationSource::Unknown => "built-in: unknown terminator".to_string(),
        }
    }
}

/// Classify `ast` for the target named `target_name`. Returns a
/// best-effort [`Classification`]; the chain consumer is responsible
/// for following the continuation backward.
pub fn classify(
    ast: &AssignmentAst,
    target_name: &str,
    lang: Lang,
    patterns: &PatternSet,
) -> Classification {
    // Locate the LHS sub-element matching `target_name` if the
    // assignment is a destructuring pattern; otherwise fall back to
    // the whole LHS.
    let (target_locator, destructuring_index) = locate_target(ast, target_name);

    // Augmented assignment (`a += b`) is Computational regardless of
    // the syntactic RHS shape — semantically it's `a = a + b`
    // (spec §7.2 Python row 3).
    if ast.is_augmented {
        let rhs_text = ast.text_at(ast.rhs);
        let source = ast.source();
        let rhs_node = ast.node_at(ast.rhs);
        let operand_snapshots = match rhs_node {
            Some(n) => {
                let mut ops = collect_identifier_leaves(n, source);
                let target_text = ast.text_at(target_locator);
                if !ops.iter().any(|op| op == target_text) {
                    ops.push(target_text.to_string());
                    ops.sort();
                }
                ops
            }
            None => vec![rhs_text.to_string()],
        };
        return Classification {
            target: target_locator,
            rhs: ast.rhs,
            kind: OriginKind::Computational,
            source_variable: None,
            confidence: 0.9,
            source: ClassificationSource::UniversalTable {
                node_kind: "augmented_assignment".to_string(),
            },
            operand_snapshots,
        };
    }

    // Walk the RHS for classification. If the LHS is a destructuring
    // pattern, the RHS is treated as a tuple/array/object source and
    // the synthesised hop is IndexAccess / FieldAccess (spec §7.2).
    if ast.lhs_is_destructuring {
        if let Some(classification) =
            classify_destructuring(ast, target_locator, destructuring_index, lang)
        {
            return classification;
        }
    }

    let rhs_node = match ast.node_at(ast.rhs) {
        Some(n) => n,
        // Defensive: locator should always resolve, but if grammars
        // shift we'd rather return Unknown than panic.
        None => return unknown_terminator(target_locator, ast.rhs),
    };

    // Custom (user / built-in) pattern matching first. Pattern
    // precedence is "first match wins" (spec §7.4).
    if let Some(c) = match_patterns(ast, rhs_node, target_locator, lang, patterns) {
        return c;
    }

    // Fall through to the universal classification table (§7.1).
    classify_universal(ast, rhs_node, target_locator, lang)
}

fn unknown_terminator(target: NodeLocator, rhs: NodeLocator) -> Classification {
    Classification {
        target,
        rhs,
        kind: OriginKind::Unknown,
        source_variable: None,
        confidence: 0.0,
        source: ClassificationSource::Unknown,
        operand_snapshots: Vec::new(),
    }
}

/// Resolve a target name against the LHS of `ast`.
///
/// Returns the locator for the matching sub-target plus, for
/// destructuring patterns, the 0-based index within the pattern
/// (used to compute the right `IndexAccess` continuation).
fn locate_target(ast: &AssignmentAst, target_name: &str) -> (NodeLocator, Option<usize>) {
    if !ast.lhs_is_destructuring {
        return (ast.lhs, None);
    }
    let Some(lhs_node) = ast.node_at(ast.lhs) else {
        return (ast.lhs, None);
    };
    let source = ast.source();
    let mut cursor = lhs_node.walk();
    for (idx, child) in lhs_node.named_children(&mut cursor).enumerate() {
        // Filter out structural-only nodes (commas, parens). All
        // grammar destructuring elements we care about have at least
        // one identifier descendant; we use the identifier text for
        // the comparison.
        let text = &source[child.byte_range()];
        if text == target_name {
            return (NodeLocator::from_node(child), Some(idx));
        }
        // For nested patterns / typed patterns, look for an
        // identifier descendant whose text matches.
        if let Some(hit) = find_identifier_named(child, target_name, source) {
            return (NodeLocator::from_node(hit), Some(idx));
        }
    }
    (ast.lhs, None)
}

fn find_identifier_named<'a>(node: Node<'a>, target: &str, source: &str) -> Option<Node<'a>> {
    if &source[node.byte_range()] == target && node.named_child_count() == 0 {
        return Some(node);
    }
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        if let Some(hit) = find_identifier_named(child, target, source) {
            return Some(hit);
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Destructuring classification (spec §7.2 — Python tuple / Ruby swap /
// JS `{a, b} = obj` / Rust `let (a, b) = pair` / Go `a, err := foo()`)
// ---------------------------------------------------------------------------

fn classify_destructuring(
    ast: &AssignmentAst,
    target: NodeLocator,
    index: Option<usize>,
    lang: Lang,
) -> Option<Classification> {
    let rhs_node = ast.node_at(ast.rhs)?;
    let lhs_node = ast.node_at(ast.lhs)?;
    let source = ast.source();
    let rhs_text = &source[rhs_node.byte_range()];

    // Per spec §7.2, JS object destructuring `const { a, b } = obj`
    // yields FieldAccess hops (the target name *is* the field name).
    let object_destructuring = matches!(
        lhs_node.kind(),
        "object_pattern" | "struct_pattern" | "hash_pattern"
    );

    // Detect Go multi-return-with-err: RHS is a call expression.
    if matches!(lang, Lang::Go) {
        let rhs_is_call = matches!(rhs_node.kind(), "call_expression");
        if rhs_is_call {
            return Some(Classification {
                target,
                rhs: ast.rhs,
                kind: OriginKind::ReturnCapture,
                source_variable: None,
                confidence: 0.7,
                source: ClassificationSource::UniversalTable {
                    node_kind: "call_expression".to_string(),
                },
                operand_snapshots: collect_identifier_leaves(rhs_node, source),
            });
        }
    }

    // Detect Ruby swap (`a, b = b, a`): RHS is also an expression list
    // of identifiers. Spec §7.2 says two synthetic TrivialCopy hops
    // at confidence 0.9, with the source variable picked by index.
    if matches!(
        rhs_node.kind(),
        "expression_list" | "right_assignment_list" | "array" | "list" | "tuple"
    ) {
        // For an n-tuple LHS, target at index k pulls from RHS index
        // k (same-position binding). Spec §7.2 Ruby row gives this
        // confidence 0.9 — high because the binding is deterministic
        // even though the RHS evaluation order is one extra hop.
        let mut cursor = rhs_node.walk();
        let rhs_children: Vec<Node<'_>> = rhs_node.named_children(&mut cursor).collect();
        let source_var = index
            .and_then(|i| rhs_children.get(i).copied())
            .map(|n| source[n.byte_range()].to_string());
        // The "swap" optimisation only applies when both sides are
        // pure identifier lists of the same length; otherwise treat
        // this as a destructuring read.
        let lhs_count = lhs_node.named_child_count();
        let all_idents = rhs_children
            .iter()
            .all(|n| n.named_child_count() == 0 || n.kind() == "identifier");
        if all_idents && lhs_count == rhs_children.len() && lhs_count >= 2 {
            return Some(Classification {
                target,
                rhs: ast.rhs,
                kind: OriginKind::TrivialCopy,
                source_variable: source_var,
                confidence: 0.9,
                source: ClassificationSource::UniversalTable {
                    node_kind: "swap_destructuring".to_string(),
                },
                operand_snapshots: Vec::new(),
            });
        }
    }

    let kind = if object_destructuring {
        OriginKind::FieldAccess
    } else {
        OriginKind::IndexAccess
    };

    // The source variable for destructuring is the entire RHS
    // expression text if it's a simple identifier; otherwise None
    // (the chain consumer then leans on operand snapshots).
    let source_variable =
        if rhs_node.named_child_count() == 0 || matches!(rhs_node.kind(), "identifier" | "name") {
            Some(rhs_text.to_string())
        } else {
            None
        };

    Some(Classification {
        target,
        rhs: ast.rhs,
        kind,
        source_variable,
        confidence: 0.7,
        source: ClassificationSource::UniversalTable {
            node_kind: format!("destructuring({})", lhs_node.kind()),
        },
        operand_snapshots: Vec::new(),
    })
}

// ---------------------------------------------------------------------------
// Universal classification table (spec §7.1)
// ---------------------------------------------------------------------------

fn classify_universal(
    ast: &AssignmentAst,
    rhs: Node<'_>,
    target: NodeLocator,
    lang: Lang,
) -> Classification {
    let source = ast.source();

    // Strip enclosing parens so `(int)x` → identifier, etc.
    let effective = unwrap_trivial(rhs, lang);

    let kind = effective.kind();
    match kind {
        // Literal terminators (spec §7.1 row 5).
        // M23 additions: `number` (Cairo), `int` (Aiken),
        // `int_literal` (Circom), `unsigned_literal` /
        // `signed_literal` / `field_literal` (Leo's typed integer
        // literals like `10u32`), `base10` / `base16` / `base2` /
        // `base8` (Aiken's per-base integer leaves — when the
        // surrounding `int` wrapper collapses on identical byte
        // ranges, the locator round-trip lands on the base leaf).
        "integer"
        | "integer_literal"
        | "float"
        | "float_literal"
        | "string"
        | "true"
        | "false"
        | "nil"
        | "nil_literal"
        | "null"
        | "string_literal"
        | "char_literal"
        | "number"
        | "number_literal"
        | "int"
        | "int_literal"
        | "base2"
        | "base8"
        | "base10"
        | "base16"
        | "unsigned_literal"
        | "signed_literal"
        | "field_literal"
        | "boolean_literal_token"
        | "address_literal"
        | "interpreted_string_literal"
        | "raw_string_literal"
        | "concatenated_string"
        | "none"
        | "boolean"
        | "boolean_literal" => Classification {
            target,
            rhs: NodeLocator::from_node(rhs),
            kind: OriginKind::Literal,
            source_variable: None,
            confidence: 1.0,
            source: ClassificationSource::UniversalTable {
                node_kind: kind.to_string(),
            },
            operand_snapshots: Vec::new(),
        },

        // Bare identifier copy (spec §7.1 row 1).
        // M23 additions: `variable` (Leo) — tree-sitter-leo wraps
        // identifier-only RHS expressions in a `variable` node.
        "identifier" | "name" | "shorthand_variable" | "variable" => Classification {
            target,
            rhs: NodeLocator::from_node(rhs),
            kind: OriginKind::TrivialCopy,
            source_variable: Some(source[effective.byte_range()].to_string()),
            confidence: 0.95,
            source: ClassificationSource::UniversalTable {
                node_kind: kind.to_string(),
            },
            operand_snapshots: Vec::new(),
        },

        // Field access (spec §7.1 row 2).
        "attribute"
        | "field_expression"
        | "member_expression"
        | "selector_expression"
        | "dot_expression"
        | "scoped_identifier" => {
            let receiver_text = field_receiver_text(effective, source);
            Classification {
                target,
                rhs: NodeLocator::from_node(rhs),
                kind: OriginKind::FieldAccess,
                source_variable: receiver_text,
                confidence: 0.9,
                source: ClassificationSource::UniversalTable {
                    node_kind: kind.to_string(),
                },
                operand_snapshots: Vec::new(),
            }
        }

        // Index / subscript (spec §7.1 row 3).
        "subscript"
        | "subscript_expression"
        | "index_expression"
        | "element_access_expression"
        | "element_reference"
        | "bracket_expression" => {
            let receiver_text = index_receiver_text(effective, source);
            Classification {
                target,
                rhs: NodeLocator::from_node(rhs),
                kind: OriginKind::IndexAccess,
                source_variable: receiver_text,
                confidence: 0.9,
                source: ClassificationSource::UniversalTable {
                    node_kind: kind.to_string(),
                },
                operand_snapshots: Vec::new(),
            }
        }

        // C pointer deref `*p` (spec §7.2 C/C++ table). Tree-sitter
        // names it `pointer_expression` (C/C++) or `unary_expression`
        // with `*` operator (Rust); handle both.
        "pointer_expression" | "deref_expression" => Classification {
            target,
            rhs: NodeLocator::from_node(rhs),
            kind: OriginKind::IndexAccess,
            source_variable: c_deref_receiver(effective, source),
            confidence: 0.85,
            source: ClassificationSource::UniversalTable {
                node_kind: kind.to_string(),
            },
            operand_snapshots: Vec::new(),
        },

        // Computational shapes (spec §7.1 row 4).
        "binary_expression"
        | "binary_operator"
        | "unary_expression"
        | "unary_operator"
        | "comparison_operator"
        | "compound_assignment_expr"
        | "augmented_assignment"
        | "augmented_assignment_expression"
        | "boolean_operator"
        | "string_concatenation"
        | "template_literal"
        | "template_string"
        | "interpolated_string_literal"
        | "conditional_expression"
        | "ternary_expression"
        | "list_comprehension"
        | "set_comprehension"
        | "dict_comprehension"
        | "generator_expression"
        | "binary_op" => Classification {
            target,
            rhs: NodeLocator::from_node(rhs),
            kind: OriginKind::Computational,
            source_variable: None,
            confidence: 0.9,
            source: ClassificationSource::UniversalTable {
                node_kind: kind.to_string(),
            },
            operand_snapshots: collect_identifier_leaves(effective, source),
        },

        // `await foo()` (spec §7.2 Python row).
        "await" | "await_expression" => Classification {
            target,
            rhs: NodeLocator::from_node(rhs),
            kind: OriginKind::ReturnCapture,
            source_variable: None,
            confidence: 0.75,
            source: ClassificationSource::UniversalTable {
                node_kind: kind.to_string(),
            },
            operand_snapshots: collect_identifier_leaves(effective, source),
        },

        // Function call. We've already tried pattern matching; this
        // is the fallthrough (spec §7.1 row 7 — FunctionCall).
        "call" | "call_expression" | "method_call" | "method_invocation" => Classification {
            target,
            rhs: NodeLocator::from_node(rhs),
            kind: OriginKind::FunctionCall,
            source_variable: None,
            confidence: 0.7,
            source: ClassificationSource::UniversalTable {
                node_kind: kind.to_string(),
            },
            operand_snapshots: collect_identifier_leaves(effective, source),
        },

        // Composite literal / tuple / list / array / dict / set
        // constructors classify as Computational with the identifier
        // leaves of the constructor as the operand snapshot set
        // (spec §7.1 row 4 — "single-result computation").
        //
        // Without this the universal table would fall through to
        // `Unknown` for `pair = (11, 22)`, `xs = [a, b]`, etc., and
        // the chain would terminate with a confidence-0 hop even
        // though the source line clearly produced the value.
        "tuple"
        | "list"
        | "array"
        | "dictionary"
        | "set"
        | "list_expression"
        | "array_expression"
        | "dictionary_expression"
        | "tuple_expression"
        | "expression_list"
        | "literal_value"
        | "composite_literal" => Classification {
            target,
            rhs: NodeLocator::from_node(rhs),
            kind: OriginKind::Computational,
            source_variable: None,
            confidence: 0.9,
            source: ClassificationSource::UniversalTable {
                node_kind: kind.to_string(),
            },
            operand_snapshots: collect_identifier_leaves(effective, source),
        },

        // Cast: `(int)x` in C is treated as TrivialCopy with
        // confidence 0.9 (spec §7.2 C/C++ table).
        "cast_expression" => {
            let inner_text = cast_inner_text(effective, source);
            Classification {
                target,
                rhs: NodeLocator::from_node(rhs),
                kind: OriginKind::TrivialCopy,
                source_variable: inner_text,
                confidence: 0.9,
                source: ClassificationSource::UniversalTable {
                    node_kind: kind.to_string(),
                },
                operand_snapshots: Vec::new(),
            }
        }

        // Unknown / unrecognised — terminator with confidence 0.
        _ => unknown_terminator(target, NodeLocator::from_node(rhs)),
    }
}

fn unwrap_trivial<'a>(mut node: Node<'a>, lang: Lang) -> Node<'a> {
    // Some grammars wrap the RHS expression in an
    // `expression`/`parenthesized_expression` node; descend through
    // those so the kind matcher sees the real shape.
    //
    // Nim is the extreme case: tree-sitter-nim encodes operator
    // precedence as a 14-deep chain of single-child nodes
    // (`expression -> infix_expression -> assign_expr -> op2_expr
    //  -> or_expr -> and_expr -> cmp_expr -> range_expr -> amp_expr
    //  -> add_expr -> mul_expr -> pow_expr -> prefix_expr
    //  -> postfix_expr -> postfixable_primary -> symbol -> identifier`).
    // We unwrap any single-named-child wrapper recursively, then stop
    // at a recognisable terminal kind.
    let nim_unwrap = matches!(lang, Lang::Nim);
    loop {
        match node.kind() {
            "parenthesized_expression" | "expression" | "_expression" | "expression_statement" => {
                if let Some(inner) = node.named_child(0) {
                    node = inner;
                } else {
                    return node;
                }
            }
            kind if nim_unwrap && is_nim_passthrough(kind) => {
                if node.named_child_count() == 1 {
                    node = node.named_child(0).unwrap();
                } else {
                    return node;
                }
            }
            _ => return node,
        }
    }
}

fn is_nim_passthrough(kind: &str) -> bool {
    matches!(
        kind,
        "infix_expression"
            | "assign_expr"
            | "op2_expr"
            | "or_expr"
            | "and_expr"
            | "cmp_expr"
            | "range_expr"
            | "amp_expr"
            | "add_expr"
            | "mul_expr"
            | "pow_expr"
            | "prefix_expr"
            | "postfix_expr"
            | "postfixable_primary"
            | "symbol"
            | "qualified_identifier"
            | "literal"
    )
}

fn field_receiver_text(node: Node<'_>, source: &str) -> Option<String> {
    // Tree-sitter exposes a `object` field on `attribute` /
    // `field_expression` / `member_expression`. Fall back to the
    // first named child if the field name isn't present.
    node.child_by_field_name("object")
        .or_else(|| node.child_by_field_name("argument"))
        .or_else(|| node.child_by_field_name("operand"))
        .or_else(|| node.named_child(0))
        .map(|n| source[n.byte_range()].to_string())
}

fn index_receiver_text(node: Node<'_>, source: &str) -> Option<String> {
    node.child_by_field_name("object")
        .or_else(|| node.child_by_field_name("array"))
        .or_else(|| node.child_by_field_name("operand"))
        .or_else(|| node.named_child(0))
        .map(|n| source[n.byte_range()].to_string())
}

fn cast_inner_text(node: Node<'_>, source: &str) -> Option<String> {
    node.child_by_field_name("value")
        .or_else(|| node.child_by_field_name("argument"))
        .or_else(|| node.named_child(node.named_child_count().saturating_sub(1)))
        .map(|n| source[n.byte_range()].to_string())
}

fn c_deref_receiver(node: Node<'_>, source: &str) -> Option<String> {
    node.child_by_field_name("argument")
        .or_else(|| node.child_by_field_name("operand"))
        .or_else(|| node.named_child(0))
        .map(|n| source[n.byte_range()].to_string())
}

fn collect_identifier_leaves(node: Node<'_>, source: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    collect_leaves(node, source, &mut out);
    out.sort();
    out.dedup();
    out
}

fn collect_leaves(node: Node<'_>, source: &str, out: &mut Vec<String>) {
    let kind = node.kind();
    if matches!(kind, "identifier" | "name" | "shorthand_variable") {
        let text = source[node.byte_range()].to_string();
        if !text.is_empty() {
            out.push(text);
        }
        return;
    }
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        collect_leaves(child, source, out);
    }
}

// ---------------------------------------------------------------------------
// Pattern matching
// ---------------------------------------------------------------------------

fn match_patterns(
    ast: &AssignmentAst,
    rhs: Node<'_>,
    target: NodeLocator,
    lang: Lang,
    patterns: &PatternSet,
) -> Option<Classification> {
    let source = ast.source();
    let effective = unwrap_trivial(rhs, lang);
    for rule in patterns.rules() {
        if !rule.languages.is_empty() && !rule.languages.contains(&lang) {
            continue;
        }
        let mut captures: HashMap<String, Node<'_>> = HashMap::new();
        if !match_node(&rule.matcher.root, effective, source, &mut captures) {
            continue;
        }
        let (source_variable, operand_snapshots) = match &rule.continuation {
            Some(cont) => {
                let captured = captures
                    .get(&cont.capture)
                    .map(|n| normalize_continuation_capture(source[n.byte_range()].trim(), lang));
                (captured, Vec::new())
            }
            None => {
                // Computational pattern: collect identifier leaves from
                // the matched RHS (operand snapshots, spec §7.1).
                (None, collect_identifier_leaves(effective, source))
            }
        };
        return Some(Classification {
            target,
            rhs: NodeLocator::from_node(rhs),
            kind: rule.origin_kind,
            source_variable,
            confidence: 0.95,
            source: ClassificationSource::Rule {
                kind: rule.kind,
                provenance: rule.provenance.clone(),
            },
            operand_snapshots,
        });
    }
    None
}

fn normalize_continuation_capture(text: &str, lang: Lang) -> String {
    if matches!(lang, Lang::C | Lang::Cpp) {
        if let Some(stripped) = text.strip_prefix('&').map(str::trim) {
            if is_simple_c_identifier_path(stripped) {
                return stripped.to_string();
            }
        }
    }
    text.to_string()
}

fn is_simple_c_identifier_path(text: &str) -> bool {
    !text.is_empty()
        && text
            .split("::")
            .all(|part| !part.is_empty() && is_identifier_text(part))
}

fn is_identifier_text(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn match_node<'a>(
    pattern: &MatcherNode,
    node: Node<'a>,
    source: &str,
    captures: &mut HashMap<String, Node<'a>>,
) -> bool {
    match pattern {
        MatcherNode::Wildcard => true,
        MatcherNode::Capture(name) => {
            // If the capture has already been bound, require an exact
            // text match (allows patterns like `$x + $x`).
            if let Some(prior) = captures.get(name) {
                source[prior.byte_range()] == source[node.byte_range()]
            } else {
                captures.insert(name.clone(), node);
                true
            }
        }
        MatcherNode::Identifier(name) => {
            // Match a plain identifier node or an identifier embedded
            // in a scoped/qualified reference.
            match node.kind() {
                "identifier" | "name" | "shorthand_variable" | "type_identifier" => {
                    source[node.byte_range()] == *name
                }
                _ => false,
            }
        }
        MatcherNode::Path(segments) => {
            // Match `A::B::C`-style paths. We compare the textual
            // joined form. This catches Rust `Box::new`, `Rc::new`,
            // Python `copy.deepcopy` (also rendered as `Path` because
            // our parser treats `::` and `.` as path separators when
            // the prefix is an identifier sequence).
            let expected = segments.join("::");
            let actual = source[node.byte_range()].to_string();
            actual == expected || actual == segments.join(".")
        }
        MatcherNode::Attribute { receiver, attr } => {
            // Match attribute access. Tree-sitter `attribute`
            // (Python), `field_expression` (Go), `member_expression`
            // (JS) all expose object + attribute children.
            match node.kind() {
                "attribute"
                | "field_expression"
                | "member_expression"
                | "selector_expression"
                | "dot_expression"
                | "scoped_identifier" => {
                    let receiver_node = node
                        .child_by_field_name("object")
                        .or_else(|| node.child_by_field_name("operand"))
                        .or_else(|| node.named_child(0));
                    let attr_node = node
                        .child_by_field_name("attribute")
                        .or_else(|| node.child_by_field_name("field"))
                        .or_else(|| node.named_child(node.named_child_count().saturating_sub(1)));
                    match (receiver_node, attr_node) {
                        (Some(rec), Some(att)) => {
                            source[att.byte_range()] == *attr
                                && match_node(receiver, rec, source, captures)
                        }
                        _ => false,
                    }
                }
                // Ruby renders `x.dup` (no parens) as a `call` node
                // with `receiver` + `method` fields and no
                // `arguments`. We accept that as an attribute
                // match so `$x.dup` patterns hit it.
                "call" | "call_expression" | "method_call" | "method_invocation" => {
                    let receiver_node = node.child_by_field_name("receiver");
                    let method_field = node.child_by_field_name("method");
                    let arg_list = node
                        .child_by_field_name("arguments")
                        .or_else(|| node.child_by_field_name("argument_list"));
                    let no_args = arg_list.map(|a| a.named_child_count() == 0).unwrap_or(true);
                    if !no_args {
                        return false;
                    }
                    match (receiver_node, method_field) {
                        (Some(rec), Some(m)) => {
                            source[m.byte_range()] == *attr
                                && match_node(receiver, rec, source, captures)
                        }
                        _ => false,
                    }
                }
                _ => false,
            }
        }
        MatcherNode::Method {
            receiver,
            method,
            args,
        } => {
            // A method call: `receiver.method(args)`. Tree-sitter
            // shape depends on the grammar:
            //  - Python: `call` whose `function` is an `attribute`.
            //  - Ruby:   `call` whose `receiver` + `method` fields
            //            point at the receiver and method-name
            //            identifier. When no args are present (e.g.
            //            `x.dup`) `arguments` is absent.
            //  - Rust:   `call_expression` whose `function` is a
            //            `field_expression`.
            //  - JS / Go: `call_expression` whose `function` is a
            //            `member_expression` / `selector_expression`.
            //
            // We use a "call-or-field" pattern: if the node itself is
            // already a field access (no args), we accept that for
            // empty-arg patterns.
            if matches!(
                node.kind(),
                "call" | "call_expression" | "method_call" | "method_invocation"
            ) {
                let receiver_node = node.child_by_field_name("receiver");
                let method_field = node.child_by_field_name("method");
                let function_field = node.child_by_field_name("function");
                let arg_list = node
                    .child_by_field_name("arguments")
                    .or_else(|| node.child_by_field_name("argument_list"));
                let (callee_receiver, callee_method) =
                    if let (Some(rec), Some(m)) = (receiver_node, method_field) {
                        (Some(rec), Some(source[m.byte_range()].to_string()))
                    } else if let Some(func) = function_field {
                        extract_method_callee(func, source)
                    } else {
                        (None, None)
                    };
                if callee_method.as_deref() != Some(method.as_str()) {
                    return false;
                }
                let Some(rec) = callee_receiver else {
                    return false;
                };
                if !match_node(receiver, rec, source, captures) {
                    return false;
                }
                return match_arglist(args, arg_list, source, captures);
            }
            // Fall-through: empty-arg method patterns (Ruby `$x.dup`)
            // match a bare attribute/field-access node.
            if args.is_empty() {
                let attr_node = MatcherNode::Attribute {
                    receiver: receiver.clone(),
                    attr: method.clone(),
                };
                return match_node(&attr_node, node, source, captures);
            }
            false
        }
        MatcherNode::Call { callee, args } => {
            if !matches!(
                node.kind(),
                "call" | "call_expression" | "method_call" | "method_invocation"
            ) {
                return false;
            }
            let function = node
                .child_by_field_name("function")
                .or_else(|| node.child_by_field_name("method"));
            let arg_list = node
                .child_by_field_name("arguments")
                .or_else(|| node.child_by_field_name("argument_list"));
            let function = match function {
                Some(f) => f,
                None => return false,
            };
            if !match_node(callee, function, source, captures) {
                return false;
            }
            match_arglist(args, arg_list, source, captures)
        }
        MatcherNode::Index { receiver, index } => match node.kind() {
            "subscript"
            | "subscript_expression"
            | "index_expression"
            | "element_reference"
            | "bracket_expression" => {
                let recv = node
                    .child_by_field_name("object")
                    .or_else(|| node.child_by_field_name("array"))
                    .or_else(|| node.named_child(0));
                let idx = node
                    .child_by_field_name("index")
                    .or_else(|| node.child_by_field_name("subscript"))
                    .or_else(|| node.named_child(1));
                match (recv, idx) {
                    (Some(r), Some(i)) => {
                        match_node(receiver, r, source, captures)
                            && match_node(index, i, source, captures)
                    }
                    _ => false,
                }
            }
            _ => false,
        },
    }
}

fn extract_method_callee<'a>(
    function: Node<'a>,
    source: &str,
) -> (Option<Node<'a>>, Option<String>) {
    match function.kind() {
        "attribute"
        | "member_expression"
        | "field_expression"
        | "selector_expression"
        | "dot_expression"
        | "scoped_identifier" => {
            let recv = function
                .child_by_field_name("object")
                .or_else(|| function.child_by_field_name("operand"))
                .or_else(|| function.named_child(0));
            let attr = function
                .child_by_field_name("attribute")
                .or_else(|| function.child_by_field_name("field"))
                .or_else(|| function.named_child(function.named_child_count().saturating_sub(1)));
            let method = attr.map(|n| source[n.byte_range()].to_string());
            (recv, method)
        }
        _ => (None, None),
    }
}

fn match_arglist<'a>(
    pattern_args: &[MatcherNode],
    arg_list: Option<Node<'a>>,
    source: &str,
    captures: &mut HashMap<String, Node<'a>>,
) -> bool {
    let arg_list = match arg_list {
        Some(a) => a,
        None => return pattern_args.is_empty(),
    };
    let mut cursor = arg_list.walk();
    let args: Vec<Node<'_>> = arg_list.named_children(&mut cursor).collect();
    if args.len() != pattern_args.len() {
        return false;
    }
    for (pat, arg) in pattern_args.iter().zip(args.iter()) {
        if !match_node(pat, *arg, source, captures) {
            return false;
        }
    }
    true
}
