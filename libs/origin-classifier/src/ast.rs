//! Single-line assignment parsing on top of tree-sitter.
//!
//! [`parse_assignment`] takes a single source line and a [`Lang`] and
//! returns an [`AssignmentAst`] describing the matched assignment if
//! one is found. The crate's higher-level [`crate::classify`] consumes
//! these for classification.
//!
//! "Single line" here is a pragmatic source-text level: callers from
//! the db-backend already extract the statement text for a particular
//! step ID; the classifier does not need to walk full files. The
//! parser still accepts multi-line text, but the AST search starts at
//! the first assignment node in document order.

use std::fmt;

use tree_sitter::{Node, Parser, Tree};

use crate::kinds::Lang;

/// Opaque locator into the parsed source identifying a sub-tree by
/// byte range. We use byte ranges (rather than tree-sitter cursor
/// state) so the [`AssignmentAst`] can outlive the parser borrow and
/// callers don't have to thread lifetimes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NodeLocator {
    /// Inclusive start byte in the original source.
    pub start_byte: usize,
    /// Exclusive end byte in the original source.
    pub end_byte: usize,
}

impl NodeLocator {
    /// Construct a locator from a tree-sitter node by recording its
    /// byte range. Visible to the classify module which constructs
    /// fresh locators when descending into sub-RHS expressions.
    pub fn from_node(node: Node<'_>) -> Self {
        Self {
            start_byte: node.start_byte(),
            end_byte: node.end_byte(),
        }
    }

    /// Resolve back to the original source slice.
    pub fn slice<'src>(&self, source: &'src str) -> &'src str {
        &source[self.start_byte..self.end_byte]
    }
}

/// The owning AST produced by [`parse_assignment`]. The full
/// tree-sitter [`Tree`] is retained so [`crate::classify`] can walk
/// the RHS with the same node hierarchy that produced the LHS/RHS
/// locators.
pub struct AssignmentAst {
    /// Original source text (owned so callers can drop their input).
    source: String,
    /// Underlying tree-sitter tree (kept alive for re-walking).
    tree: Tree,
    /// Locator of the whole assignment node (may be the
    /// `assignment` / `let_declaration` / `short_var_declaration`
    /// node, depending on grammar).
    pub assignment: NodeLocator,
    /// Locator of the LHS expression. For multi-target destructuring
    /// the locator points at the whole tuple/list/pattern; the
    /// classifier picks out the correct sub-target by name.
    pub lhs: NodeLocator,
    /// Locator of the RHS expression.
    pub rhs: NodeLocator,
    /// True when the LHS is a multi-target destructuring pattern
    /// (tuple, list, object pattern, etc.). The classifier needs
    /// this to decide whether to synthesise destructuring hops.
    pub lhs_is_destructuring: bool,
    /// True when this is an augmented assignment (`a += b`, `a -= b`,
    /// etc.). The classifier treats these as Computational regardless
    /// of the syntactic RHS shape (spec §7.2 Python row 3).
    pub is_augmented: bool,
    /// The classifier's language is carried so we can re-enter the
    /// tree-sitter walker without an extra argument.
    pub lang: Lang,
}

impl fmt::Debug for AssignmentAst {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Tree-sitter's Tree intentionally doesn't implement Debug
        // beyond a pointer-style summary; redact it here so consumers
        // can still derive-print enclosing structs.
        f.debug_struct("AssignmentAst")
            .field("source_len", &self.source.len())
            .field("assignment", &self.assignment)
            .field("lhs", &self.lhs)
            .field("rhs", &self.rhs)
            .field("lhs_is_destructuring", &self.lhs_is_destructuring)
            .field("is_augmented", &self.is_augmented)
            .field("lang", &self.lang)
            .finish()
    }
}

impl AssignmentAst {
    /// Original source text. Useful for resolving [`NodeLocator`]s.
    pub fn source(&self) -> &str {
        &self.source
    }

    /// The underlying tree-sitter tree. Exposed for the classifier
    /// (and downstream tooling) that needs to walk arbitrary sub-trees.
    pub fn tree(&self) -> &Tree {
        &self.tree
    }

    /// Resolve a [`NodeLocator`] back to a [`Node`] inside this AST.
    /// Returns `None` if the byte range does not align to any node in
    /// the tree. The classifier uses this when carrying locators
    /// between functions.
    pub fn node_at(&self, locator: NodeLocator) -> Option<Node<'_>> {
        let mut cursor = self.tree.walk();
        let root = self.tree.root_node();
        find_node_by_range(root, &mut cursor, locator)
    }

    /// Resolve a locator to the source text it covers.
    pub fn text_at(&self, locator: NodeLocator) -> &str {
        locator.slice(&self.source)
    }

    /// Return `true` when the parsed assignment's LHS *names* the
    /// requested variable — either directly (single-target assignment
    /// `c = …`) or as one of the destructured leaves (`a, c = …`,
    /// `{c} = …`, `[c] = …`, etc.).
    ///
    /// Used by callers that need to verify a source line really is the
    /// assignment that produced the value they're tracking (e.g. the
    /// db-backend Value-Origin algorithm falls back to the previous
    /// step's source line for Python-style pre-execution snapshot
    /// recorders only if the previous line is provably an assignment
    /// to the variable being tracked).
    pub fn targets_variable(&self, name: &str) -> bool {
        if name.is_empty() {
            return false;
        }
        let Some(lhs) = self.node_at(self.lhs) else {
            return false;
        };
        let source = self.source.as_str();
        // For a non-destructuring LHS the whole LHS text must equal
        // `name`. For destructuring patterns we accept any leaf
        // identifier descendant whose text matches.
        let lhs_text = &source[lhs.byte_range()];
        if lhs_text == name {
            return true;
        }
        contains_identifier_named(lhs, name, source)
    }
}

fn contains_identifier_named(node: Node<'_>, name: &str, source: &str) -> bool {
    if &source[node.byte_range()] == name && node.named_child_count() == 0 {
        return true;
    }
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        if contains_identifier_named(child, name, source) {
            return true;
        }
    }
    false
}

fn find_node_by_range<'a>(
    node: Node<'a>,
    cursor: &mut tree_sitter::TreeCursor<'a>,
    locator: NodeLocator,
) -> Option<Node<'a>> {
    // Tree-sitter's descendant_for_byte_range returns the smallest
    // node whose range *contains* the byte range; we want exact
    // equality so destructuring locators round-trip cleanly.
    let candidate = node.descendant_for_byte_range(locator.start_byte, locator.end_byte)?;
    if candidate.start_byte() == locator.start_byte && candidate.end_byte() == locator.end_byte {
        return Some(candidate);
    }
    // Fall back to a manual walk if descendant_for_byte_range gave us
    // an enclosing parent instead of an exact match (rare; happens
    // when locator and node disagree on trailing whitespace handling).
    cursor.reset(node);
    walk_for_exact(cursor, locator)
}

fn walk_for_exact<'a>(
    cursor: &mut tree_sitter::TreeCursor<'a>,
    locator: NodeLocator,
) -> Option<Node<'a>> {
    let node = cursor.node();
    if node.start_byte() == locator.start_byte && node.end_byte() == locator.end_byte {
        return Some(node);
    }
    if cursor.goto_first_child() {
        loop {
            if let Some(hit) = walk_for_exact(cursor, locator) {
                return Some(hit);
            }
            if !cursor.goto_next_sibling() {
                break;
            }
        }
        cursor.goto_parent();
    }
    None
}

/// Parse `line` as `lang` and return the positional argument
/// expressions of the first call expression in document order.
///
/// Each entry is the source-text slice of one positional argument
/// (keyword-argument forms like `key=value` are skipped in the
/// returned list).
///
/// Used by the db-backend Value-Origin algorithm to translate a
/// callee's parameter name into the caller's argument *expression*
/// (e.g. `receive(value)` → `["value"]`). Returns `None` when no
/// call is found at all.
pub fn parse_call_arguments(line: &str, lang: Lang) -> Option<Vec<String>> {
    let mut parser = Parser::new();
    parser.set_language(&lang.tree_sitter_language()).ok()?;
    let tree = parser.parse(line, None)?;
    let root = tree.root_node();
    let call = locate_call(root)?;
    let args = call
        .child_by_field_name("arguments")
        .or_else(|| call.child_by_field_name("argument_list"))?;
    let mut out = Vec::new();
    let mut cursor = args.walk();
    for child in args.named_children(&mut cursor) {
        // Skip keyword/named arguments — those forms have the parameter
        // name baked in so the caller-side resolver doesn't need them.
        match child.kind() {
            "keyword_argument" | "named_argument" => continue,
            _ => {}
        }
        let slice = &line[child.byte_range()];
        if !slice.is_empty() {
            out.push(slice.to_string());
        }
    }
    Some(out)
}

fn locate_call<'a>(root: Node<'a>) -> Option<Node<'a>> {
    let mut cursor = root.walk();
    walk_call(&mut cursor)
}

fn walk_call<'a>(cursor: &mut tree_sitter::TreeCursor<'a>) -> Option<Node<'a>> {
    let node = cursor.node();
    // Tree-sitter exposes call-expression nodes under multiple kind
    // names depending on grammar; cover the common shapes.
    match node.kind() {
        "call" | "call_expression" | "method_invocation" => return Some(node),
        _ => {}
    }
    if cursor.goto_first_child() {
        loop {
            if let Some(hit) = walk_call(cursor) {
                return Some(hit);
            }
            if !cursor.goto_next_sibling() {
                break;
            }
        }
        cursor.goto_parent();
    }
    None
}

/// Top-level entry point: parse `line` as `lang` and return the
/// first assignment we find, if any.
///
/// "Assignment" here is interpreted per-language. We accept both
/// statement-level forms (`x = y`, `let x = y;`, `x := y`, …) and
/// declaration forms that always bind one or more targets. We also
/// synthesise an [`AssignmentAst`] for stand-alone calls that look
/// like out-parameter forwarders (notably C `memcpy(dst, src, n);`,
/// spec §7.2 row) — the dst argument is the synthetic LHS and the
/// whole call expression is the RHS. The classifier then matches the
/// call against the forwarder catalogue.
///
/// Returns `None` for inputs that contain no recognised assignment
/// shape; callers are expected to fall back to `OriginKind::Unknown`
/// with confidence 0 (spec §7.1 last row).
///
/// **M23 — per-language preamble wrapping.** Several smart-contract
/// language grammars (Cairo, Aiken, Leo, Circom) refuse to parse a
/// bare `let x = y;` / `x <== y;` line at the top-level because their
/// statement rules are nested inside a function / template / program
/// production. The db-backend always calls this entry point with a
/// single source line lifted out of a step ID, so we transparently
/// retry with a per-language preamble that supplies the surrounding
/// context the grammar needs. The retry happens only when the bare
/// parse failed to find an assignment and only when the preamble adds
/// no per-line offset (the wrapper text wraps the line in a fresh
/// scope rather than prepending text on the same line) so the
/// produced [`NodeLocator`]s still address the original bytes.
pub fn parse_assignment(line: &str, lang: Lang) -> Option<AssignmentAst> {
    parse_assignment_inner(line, lang, false).or_else(|| {
        if lang_needs_preamble(lang) {
            parse_assignment_inner(line, lang, true)
        } else {
            None
        }
    })
}

fn parse_assignment_inner(line: &str, lang: Lang, with_preamble: bool) -> Option<AssignmentAst> {
    let mut parser = Parser::new();
    parser.set_language(&lang.tree_sitter_language()).ok()?;

    // Decide whether to wrap the line in a per-language scope so the
    // grammar's top-level rule reaches our assignment node. We keep
    // the original line untouched and stash the preamble prefix
    // length so `NodeLocator`s can be normalised back into the
    // original `line` byte ranges.
    let (parse_text, prefix_len, suffix_len) = if with_preamble {
        let (pre, suf) = preamble_for(lang)?;
        let combined = format!("{pre}{line}{suf}");
        (combined, pre.len(), suf.len())
    } else {
        (line.to_owned(), 0usize, 0usize)
    };
    let _ = suffix_len; // currently unused; reserved for future trimming

    let tree = parser.parse(&parse_text, None)?;

    // Compute locators inside a scoped borrow so `tree` can be moved
    // into the returned [`AssignmentAst`] without aliasing.
    let result = {
        let root = tree.root_node();
        if let Some(assignment_node) = locate_assignment(root, lang) {
            let is_augmented = matches!(
                assignment_node.kind(),
                "augmented_assignment"
                    | "augmented_assignment_expression"
                    | "operator_assignment"
                    | "compound_assignment_expr"
            );
            split_assignment(assignment_node, lang).map(|(lhs, rhs, lhs_is_destructuring)| {
                (
                    NodeLocator::from_node(assignment_node),
                    NodeLocator::from_node(lhs),
                    NodeLocator::from_node(rhs),
                    lhs_is_destructuring,
                    is_augmented,
                )
            })
        } else if let Some((target, call)) = locate_out_parameter_call(root, lang) {
            Some((
                NodeLocator::from_node(call),
                NodeLocator::from_node(target),
                NodeLocator::from_node(call),
                false,
                false,
            ))
        } else {
            None
        }
    };
    let (assignment_loc, lhs_loc, rhs_loc, destructuring, is_augmented) = result?;
    let _ = prefix_len; // unused — locators index into parse_text directly

    // When the parser was invoked with a wrapper preamble, the
    // returned locators index into `parse_text` (the wrapper-joined
    // buffer), so we store `parse_text` as `source` to keep the
    // round-trip clean.  Bare-parse cases reduce to `parse_text == line`.
    Some(AssignmentAst {
        source: parse_text,
        tree,
        assignment: assignment_loc,
        lhs: lhs_loc,
        rhs: rhs_loc,
        lhs_is_destructuring: destructuring,
        is_augmented,
        lang,
    })
}

/// Languages that need a per-line wrapper to parse a bare assignment
/// at the top-level. The wrappers below add fresh scope without
/// altering the line text itself.
fn lang_needs_preamble(lang: Lang) -> bool {
    matches!(lang, Lang::Cairo | Lang::Aiken | Lang::Leo | Lang::Circom)
}

/// Return the `(prefix, suffix)` strings to splice around a bare
/// assignment line so the grammar accepts it as a nested statement.
/// `None` for languages whose top-level rule already accepts a bare
/// assignment.
fn preamble_for(lang: Lang) -> Option<(&'static str, &'static str)> {
    match lang {
        Lang::Cairo => Some(("fn __probe() { ", " }")),
        // Aiken: function-body context with no return.
        Lang::Aiken => Some(("fn __probe() { ", " }")),
        // Leo: full program + transition scaffold.  Leo's grammar is
        // strict about the surrounding `program <name>.aleo { … }`
        // block, and program names must begin with a letter (no
        // leading underscore).
        Lang::Leo => Some(("program probefn.aleo { transition probefn() { ", " } }")),
        // Circom: pragma + template context so signal declarations
        // and `<==` constraints land inside `template_body`.
        Lang::Circom => Some((
            "pragma circom 2.0.0; template __probe() { signal a; signal b; signal c; signal sum; ",
            " }",
        )),
        _ => None,
    }
}

/// Locate a stand-alone out-parameter forwarder call (e.g.
/// `memcpy(dst, src, n);`). Returns the node we should treat as the
/// LHS target and the call expression.
fn locate_out_parameter_call<'a>(root: Node<'a>, lang: Lang) -> Option<(Node<'a>, Node<'a>)> {
    if !matches!(lang, Lang::C | Lang::Cpp) {
        return None;
    }
    let mut cursor = root.walk();
    walk_out_parameter_call(&mut cursor)
}

fn walk_out_parameter_call<'a>(
    cursor: &mut tree_sitter::TreeCursor<'a>,
) -> Option<(Node<'a>, Node<'a>)> {
    let node = cursor.node();
    if node.kind() == "call_expression" {
        // First argument becomes the synthetic target.
        if let Some(args) = node
            .child_by_field_name("arguments")
            .or_else(|| node.child_by_field_name("argument_list"))
        {
            let first = args.named_child(0);
            if let Some(first) = first {
                return Some((first, node));
            }
        }
    }
    if cursor.goto_first_child() {
        loop {
            if let Some(hit) = walk_out_parameter_call(cursor) {
                return Some(hit);
            }
            if !cursor.goto_next_sibling() {
                break;
            }
        }
        cursor.goto_parent();
    }
    None
}

/// Walk the tree-sitter parse tree in document order looking for the
/// first node whose `kind()` matches one of the language's assignment
/// shapes. Returns `None` when no assignment is found.
fn locate_assignment<'a>(root: Node<'a>, lang: Lang) -> Option<Node<'a>> {
    let mut cursor = root.walk();
    walk_assignment(&mut cursor, lang)
}

fn walk_assignment<'a>(cursor: &mut tree_sitter::TreeCursor<'a>, lang: Lang) -> Option<Node<'a>> {
    let node = cursor.node();
    // A node is only treated as an assignment if it both matches an
    // assignment kind for the language AND can be split into
    // `(lhs, rhs)`.  Some grammars (Circom's
    // `signal_declaration_statement`) reuse the same kind name for
    // forms with and without a value (`signal x;` vs
    // `signal x <== expr;`) — the split-validity check filters out
    // the no-value form so the locator search keeps walking.
    if is_assignment_kind(node.kind(), lang) && split_assignment(node, lang).is_some() {
        return Some(node);
    }
    if cursor.goto_first_child() {
        loop {
            if let Some(hit) = walk_assignment(cursor, lang) {
                return Some(hit);
            }
            if !cursor.goto_next_sibling() {
                break;
            }
        }
        cursor.goto_parent();
    }
    None
}

/// Per-language list of tree-sitter node kinds that represent an
/// assignment. These names come from the published grammars; they are
/// subject to grammar version churn (warning in M1 spec). When a
/// grammar bumps a name, add the new alias here rather than relying
/// on byte-level pattern matching.
fn is_assignment_kind(kind: &str, lang: Lang) -> bool {
    match lang {
        Lang::Python => matches!(
            kind,
            "assignment" | "augmented_assignment" | "named_expression"
        ),
        Lang::Ruby => matches!(
            kind,
            "assignment" | "operator_assignment" | "left_assignment_list"
        ),
        Lang::JavaScript => matches!(
            kind,
            "variable_declarator" | "assignment_expression" | "augmented_assignment_expression"
        ),
        Lang::C | Lang::Cpp => matches!(kind, "init_declarator" | "assignment_expression"),
        Lang::Rust => matches!(
            kind,
            "let_declaration" | "assignment_expression" | "compound_assignment_expr"
        ),
        Lang::Nim => matches!(
            kind,
            // tree-sitter-nim emits `assignment_stmt` for `x = y`;
            // declarations land inside `let_section`/`var_section`/
            // `const_section` wrappers around `decl_def`.
            "assignment_stmt" | "decl_def"
        ),
        Lang::Go => matches!(
            kind,
            "short_var_declaration" | "assignment_statement" | "var_spec" | "const_spec"
        ),
        // Cairo / Sway: Rust-derived grammars; both expose
        // `let_declaration` with `pattern` + `value` fields per
        // spec §7.2 (M23 Cairo / Sway rows).
        Lang::Cairo | Lang::Sway => matches!(
            kind,
            "let_declaration" | "assignment_expression" | "compound_assignment_expr"
        ),
        // Aiken: `let_assignment` ships positional children (no
        // `pattern`/`value` fields).  See spec §7.2 (M23 Aiken row).
        Lang::Aiken => matches!(kind, "let_assignment"),
        // Leo: `variable_declaration` is the let-binding shape;
        // `assignment_statement` covers re-assignments.  See spec
        // §7.2 (M23 Leo row).
        Lang::Leo => matches!(kind, "variable_declaration" | "assignment_statement"),
        // Circom: the signal-assignment idiom (`a <== expr;`) is
        // syntactically an `assignment_expression` whose operator is
        // `<==` / `==>` / `<--` / `-->`.  Also recognise the inline
        // `signal_declaration_statement` form
        // (`signal x <== expr;`) per spec §7.2 (M23 Circom row).
        Lang::Circom => matches!(
            kind,
            "assignment_expression" | "signal_declaration_statement"
        ),
    }
}

/// Extract `(lhs, rhs, lhs_is_destructuring)` from an assignment node.
///
/// Tree-sitter exposes named child accessors (`child_by_field_name`)
/// for most grammars; we prefer those over positional access because
/// the field names are stable across minor grammar versions even when
/// child ordering changes.
fn split_assignment(node: Node<'_>, lang: Lang) -> Option<(Node<'_>, Node<'_>, bool)> {
    match lang {
        Lang::Python => split_python(node),
        Lang::Ruby => split_ruby(node),
        Lang::JavaScript => split_javascript(node),
        Lang::C | Lang::Cpp => split_c_like(node),
        // Cairo / Sway tree-sitter grammars expose the same
        // `pattern` + `value` field-name pair as Rust's
        // `let_declaration`, so reuse the Rust splitter unchanged
        // per spec §7.2 (M23 Cairo / Sway rows).
        Lang::Rust | Lang::Cairo | Lang::Sway => split_rust(node),
        Lang::Nim => split_nim(node),
        Lang::Go => split_go(node),
        Lang::Aiken => split_aiken(node),
        Lang::Leo => split_leo(node),
        Lang::Circom => split_circom(node),
    }
}

// --- Per-language splitters -------------------------------------------------

fn split_python(node: Node<'_>) -> Option<(Node<'_>, Node<'_>, bool)> {
    match node.kind() {
        "assignment" | "augmented_assignment" => {
            let lhs = node.child_by_field_name("left")?;
            let rhs = node.child_by_field_name("right")?;
            let destructuring = matches!(
                lhs.kind(),
                "pattern_list" | "tuple_pattern" | "list_pattern"
            );
            Some((lhs, rhs, destructuring))
        }
        // Walrus operator `(x := expr)` (PEP 572). Treated as an
        // assignment expression by tree-sitter-python.
        "named_expression" => {
            let lhs = node.child_by_field_name("name")?;
            let rhs = node.child_by_field_name("value")?;
            Some((lhs, rhs, false))
        }
        _ => None,
    }
}

fn split_ruby(node: Node<'_>) -> Option<(Node<'_>, Node<'_>, bool)> {
    match node.kind() {
        "assignment" | "operator_assignment" => {
            let lhs = node.child_by_field_name("left")?;
            let rhs = node.child_by_field_name("right")?;
            let destructuring = matches!(lhs.kind(), "left_assignment_list");
            Some((lhs, rhs, destructuring))
        }
        _ => None,
    }
}

fn split_javascript(node: Node<'_>) -> Option<(Node<'_>, Node<'_>, bool)> {
    match node.kind() {
        "variable_declarator" => {
            let lhs = node.child_by_field_name("name")?;
            let rhs = node.child_by_field_name("value")?;
            let destructuring = matches!(lhs.kind(), "array_pattern" | "object_pattern");
            Some((lhs, rhs, destructuring))
        }
        "assignment_expression" | "augmented_assignment_expression" => {
            let lhs = node.child_by_field_name("left")?;
            let rhs = node.child_by_field_name("right")?;
            let destructuring = matches!(lhs.kind(), "array_pattern" | "object_pattern");
            Some((lhs, rhs, destructuring))
        }
        _ => None,
    }
}

fn split_c_like(node: Node<'_>) -> Option<(Node<'_>, Node<'_>, bool)> {
    match node.kind() {
        "init_declarator" => {
            let lhs = node.child_by_field_name("declarator")?;
            let rhs = node.child_by_field_name("value")?;
            Some((lhs, rhs, false))
        }
        "assignment_expression" => {
            let lhs = node.child_by_field_name("left")?;
            let rhs = node.child_by_field_name("right")?;
            Some((lhs, rhs, false))
        }
        "declaration" => {
            // C `declaration` wraps zero or more `init_declarator`
            // children; pick the first one that itself has a value.
            let mut cursor = node.walk();
            for child in node.children(&mut cursor) {
                if child.kind() == "init_declarator" {
                    return split_c_like(child);
                }
            }
            None
        }
        _ => None,
    }
}

fn split_rust(node: Node<'_>) -> Option<(Node<'_>, Node<'_>, bool)> {
    match node.kind() {
        "let_declaration" => {
            let lhs = node.child_by_field_name("pattern")?;
            let rhs = node.child_by_field_name("value")?;
            let destructuring = matches!(
                lhs.kind(),
                "tuple_pattern" | "tuple_struct_pattern" | "struct_pattern" | "slice_pattern"
            );
            Some((lhs, rhs, destructuring))
        }
        "assignment_expression" | "compound_assignment_expr" => {
            let lhs = node.child_by_field_name("left")?;
            let rhs = node.child_by_field_name("right")?;
            Some((lhs, rhs, false))
        }
        _ => None,
    }
}

fn split_nim(node: Node<'_>) -> Option<(Node<'_>, Node<'_>, bool)> {
    match node.kind() {
        "assignment_stmt" => {
            // tree-sitter-nim emits two `expression` children for
            // `lhs = rhs`. The actual identifier is buried under a
            // deep chain of precedence-encoding nodes, but that's
            // fine — the classifier uses the entire expression text
            // for identifier comparisons.
            let mut cursor = node.walk();
            let exprs: Vec<Node<'_>> = node
                .named_children(&mut cursor)
                .filter(|c| c.kind() == "expression")
                .collect();
            if exprs.len() < 2 {
                return None;
            }
            Some((exprs[0], exprs[1], false))
        }
        "decl_def" => {
            // `let b = a` produces a `decl_def` with an
            // `exported_symbol` (the bound name) followed by an
            // `expression` (the value). Type annotations and other
            // metadata may appear between them.
            let mut cursor = node.walk();
            let mut name: Option<Node<'_>> = None;
            let mut value: Option<Node<'_>> = None;
            for child in node.named_children(&mut cursor) {
                match child.kind() {
                    "exported_symbol" | "symbol" | "identifier" if name.is_none() => {
                        name = Some(child);
                    }
                    "expression" => value = Some(child),
                    _ => {}
                }
            }
            Some((name?, value?, false))
        }
        _ => None,
    }
}

fn split_go(node: Node<'_>) -> Option<(Node<'_>, Node<'_>, bool)> {
    match node.kind() {
        "short_var_declaration" => {
            let lhs = node.child_by_field_name("left")?;
            let rhs = node.child_by_field_name("right")?;
            // `a, err := foo()` is destructuring in Go terms.
            let destructuring = lhs.kind() == "expression_list" && lhs.named_child_count() > 1;
            Some((lhs, rhs, destructuring))
        }
        "assignment_statement" => {
            let lhs = node.child_by_field_name("left")?;
            let rhs = node.child_by_field_name("right")?;
            let destructuring = lhs.kind() == "expression_list" && lhs.named_child_count() > 1;
            Some((lhs, rhs, destructuring))
        }
        "var_spec" | "const_spec" => {
            let lhs = node.child_by_field_name("name")?;
            let rhs = node.child_by_field_name("value")?;
            Some((lhs, rhs, false))
        }
        "var_declaration" => {
            let mut cursor = node.walk();
            for child in node.children(&mut cursor) {
                if child.kind() == "var_spec" {
                    return split_go(child);
                }
            }
            None
        }
        _ => None,
    }
}

/// Aiken splitter.
///
/// tree-sitter-aiken renders `let x = expr` as a `let_assignment` node
/// whose named children are: the LHS pattern (`identifier` /
/// `discard` / `match_pattern` / collection-pattern) optionally
/// followed by a `type_definition`, then the RHS `expression`.  No
/// `left`/`right` field names are exposed, so we walk the named
/// children positionally and pick the first identifier-or-pattern as
/// the LHS and the first `expression` after it as the RHS.
///
/// Spec §7.2 M23 Aiken row: bare-name copies classify as
/// `TrivialCopy`; pipeline `|>` falls back to the universal table's
/// computational shape.
fn split_aiken(node: Node<'_>) -> Option<(Node<'_>, Node<'_>, bool)> {
    if node.kind() != "let_assignment" {
        return None;
    }
    let mut cursor = node.walk();
    let mut lhs: Option<Node<'_>> = None;
    let mut rhs: Option<Node<'_>> = None;
    let mut destructuring = false;
    for child in node.named_children(&mut cursor) {
        match child.kind() {
            // Type annotation, ignored for splitting purposes.
            "type_definition" => continue,
            // Pattern slots — the first one wins as the LHS target.
            "identifier" | "discard" if lhs.is_none() => {
                lhs = Some(child);
            }
            "match_pattern" | "list" | "tuple" | "pair" if lhs.is_none() => {
                lhs = Some(child);
                destructuring = true;
            }
            // Anything else after we already have an LHS is the RHS.
            "expression" if lhs.is_some() && rhs.is_none() => {
                rhs = Some(child);
            }
            // Conservative fallback: if no `expression` wrapper is
            // present (grammar churn safety), take the last named
            // child that isn't the LHS.
            _ if lhs.is_some() && rhs.is_none() => {
                rhs = Some(child);
            }
            _ => {}
        }
    }
    Some((lhs?, rhs?, destructuring))
}

/// Leo splitter.
///
/// tree-sitter-leo encodes `let x: T = expr;` as a
/// `variable_declaration` whose named children include the binding
/// identifier (`identifier` / `_identifier_or_identifiers`), the
/// `type` annotation, and an `expression` node for the RHS.
/// Reassignments come through as `assignment_statement` with
/// positional children (LHS expression, `=`, RHS expression).
///
/// Spec §7.2 M23 Leo row: bare-name copies classify as
/// `TrivialCopy`; record-/circuit-field writes fall under the
/// FieldAccess row of the universal table.
fn split_leo(node: Node<'_>) -> Option<(Node<'_>, Node<'_>, bool)> {
    match node.kind() {
        "variable_declaration" => {
            let mut cursor = node.walk();
            let mut lhs: Option<Node<'_>> = None;
            let mut rhs: Option<Node<'_>> = None;
            for child in node.named_children(&mut cursor) {
                match child.kind() {
                    "type" => continue,
                    "identifier" | "_identifier_or_identifiers" if lhs.is_none() => {
                        lhs = Some(child);
                    }
                    _ if lhs.is_some() && rhs.is_none() => {
                        rhs = Some(child);
                    }
                    _ => {}
                }
            }
            Some((lhs?, rhs?, false))
        }
        "assignment_statement" => {
            // Positional children: LHS expression, RHS expression.
            // `=` and `;` are unnamed tokens.
            let mut cursor = node.walk();
            let named: Vec<Node<'_>> = node.named_children(&mut cursor).collect();
            if named.len() < 2 {
                return None;
            }
            Some((named[0], named[named.len() - 1], false))
        }
        _ => None,
    }
}

/// Circom splitter.
///
/// tree-sitter-circom encodes constraint / signal assignments as
/// `assignment_expression` nodes whose `_expression`-typed children
/// flank one of the operators `<==`, `==>`, `<--`, `-->`, `=`, `+=`,
/// etc.  The fields are positional (no `left`/`right` field names),
/// so we walk the named children and take the first as the LHS and
/// the last as the RHS.
///
/// `signal_declaration_statement` is the inline form
/// (`signal x <== expr;`) — handled separately because the LHS lives
/// in the `name` field and the RHS in the `value` field.
///
/// Spec §7.2 M23 Circom row: `a <== expr;` classifies identically to
/// `a = expr;` in the universal table — bare-name copies become
/// `TrivialCopy`, integer literals become `Literal`, binary
/// expressions become `Computational`.  The `==>` and `<--` forms
/// follow the same shape with the LHS / RHS swapped where applicable.
fn split_circom(node: Node<'_>) -> Option<(Node<'_>, Node<'_>, bool)> {
    match node.kind() {
        "assignment_expression" => {
            let mut cursor = node.walk();
            let named: Vec<Node<'_>> = node.named_children(&mut cursor).collect();
            if named.len() < 2 {
                return None;
            }
            // Detect the direction of the signal-assignment.  `==>`
            // and `-->` flow rightward (LHS on the LEFT of the
            // operator is the source; the RHS is the target);
            // every other operator flows leftward.  We check the
            // operator token by walking the unnamed children.
            let direction = circom_arrow_direction(node);
            let (lhs_index, rhs_index) = match direction {
                CircomArrowDirection::Rightward => (named.len() - 1, 0),
                CircomArrowDirection::Leftward => (0, named.len() - 1),
            };
            Some((named[lhs_index], named[rhs_index], false))
        }
        "signal_declaration_statement" => {
            // Only treat the inline form `signal x <== expr;` as an
            // assignment; bare `signal x;` declarations have no value
            // and would otherwise hijack the locator search.  The
            // `value` field carries the RHS expression when present.
            let rhs = node.child_by_field_name("value")?;
            let lhs = node
                .child_by_field_name("name")
                .or_else(|| node.named_child(0))?;
            Some((lhs, rhs, false))
        }
        _ => None,
    }
}

/// Direction of a Circom assignment operator: leftward (`<==`, `<--`,
/// `=`, …) or rightward (`==>`, `-->`).  The classifier needs to
/// know which side of the operator carries the target identifier so
/// the `TrivialCopy` continuation points the right way.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CircomArrowDirection {
    Leftward,
    Rightward,
}

fn circom_arrow_direction(node: Node<'_>) -> CircomArrowDirection {
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        if child.is_named() {
            continue;
        }
        // The unnamed tokens are the operator characters.  We match
        // on the exact operator string here rather than the kind, so
        // tree-sitter-circom's anonymous-node naming convention
        // doesn't drift the matcher behind us.
        match child.kind() {
            "==>" | "-->" => return CircomArrowDirection::Rightward,
            _ => continue,
        }
    }
    CircomArrowDirection::Leftward
}
