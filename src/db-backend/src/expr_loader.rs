use crate::{
    lang::Lang,
    task::{
        Branch, BranchId, BranchState, CoreTrace, Location, LoopShape, LoopShapeId, Position, NO_BRANCH_ID, NO_POSITION,
    },
};
use log::{debug, info, warn};
use once_cell::sync::Lazy;
use runtime_tracing::Line;
use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use tree_sitter::{Node, Parser, Tree}; // Language,
use tree_sitter_nim;
use tree_sitter_pascal;
use tree_sitter_traversal2::{traverse_tree, Order};

#[derive(Debug, Clone)]
pub struct NodeNames {
    if_conditions: Vec<String>,
    else_conditions: Vec<String>,
    loops: Vec<String>,
    branches_body: Vec<String>,
    functions: Vec<String>,
    branches: Vec<String>,
    values: Vec<String>,
    comments: Vec<String>,
}

static NODE_NAMES: Lazy<HashMap<Lang, NodeNames>> = Lazy::new(|| {
    let mut m = HashMap::new();
    m.insert(
        Lang::Ruby,
        NodeNames {
            if_conditions: vec!["if".to_string()],
            else_conditions: vec!["elsif".to_string(), "else".to_string()],
            loops: vec!["while".to_string(), "until".to_string()],
            branches_body: vec!["then".to_string(), "call".to_string()],
            branches: vec!["then".to_string(), "call".to_string()],
            functions: vec!["method".to_string()],
            values: vec!["identifier".to_string()],
            comments: vec!["comment".to_string()],
        },
    );

    let c_node_names = NodeNames {
        if_conditions: vec!["if_statement".to_string()],
        else_conditions: vec!["else_clause".to_string()],
        loops: vec!["for_statement".to_string()],
        branches_body: vec!["compound_statement".to_string()],
        branches: vec!["compound_statement".to_string()],
        functions: vec!["function_definition".to_string()],
        values: vec!["identifier".to_string()],
        comments: vec!["//".to_string()],
    };
    m.insert(Lang::C, c_node_names);

    let cpp_node_names = NodeNames {
        if_conditions: vec!["if_statement".to_string()],
        else_conditions: vec!["else_clause".to_string()],
        loops: vec!["for_statement".to_string()],
        branches_body: vec!["compound_statement".to_string()],
        branches: vec!["compound_statement".to_string()],
        functions: vec!["function_definition".to_string()],
        values: vec!["identifier".to_string()],
        comments: vec!["//".to_string()],
    };
    m.insert(Lang::Cpp, cpp_node_names);

    let pascal_node_names = NodeNames {
        if_conditions: vec!["ifElse".to_string()],
        else_conditions: vec!["else".to_string()],
        loops: vec!["for".to_string()],
        branches_body: vec!["block".to_string()],
        branches: vec!["block".to_string()],
        functions: vec!["defProc".to_string()],
        values: vec!["identifier".to_string()],
        comments: vec!["comment".to_string()],
    };
    m.insert(Lang::Pascal, pascal_node_names);

    let rust_node_names = NodeNames {
        if_conditions: vec!["if_expression".to_string()],
        else_conditions: vec!["else_clause".to_string()],
        loops: vec![
            "for_expression".to_string(),
            "loop_expression".to_string(),
            "while_expression".to_string(),
        ],
        branches_body: vec!["block".to_string()],
        branches: vec!["block".to_string()],
        functions: vec!["function_item".to_string()],
        // NOTE: `.values` is used for other languages inside `is_variable_node` now.
        // However there is custom logic for Rust there
        values: vec!["identifier".to_string()],
        comments: vec!["//".to_string()],
    };

    m.insert(Lang::Noir, rust_node_names.clone());
    m.insert(Lang::RustWasm, rust_node_names);

    m.insert(
        Lang::Small,
        NodeNames {
            if_conditions: vec!["if_expression".to_string()],
            else_conditions: vec!["else_clause".to_string()],
            loops: vec!["\"loop\"".to_string()],
            branches_body: vec!["block".to_string()],
            branches: vec!["block".to_string()],
            functions: vec!["defun".to_string()],
            values: vec!["symbol".to_string()],
            comments: vec!["".to_string()],
        },
    );

    m.insert(
        Lang::PythonDb,
        NodeNames {
            if_conditions: vec!["if_statement".to_string(), "match_statement".to_string()],
            else_conditions: vec!["else_clause".to_string()], // TODO: "case_clause".to_string(),?
            loops: vec!["for_statement".to_string(), "while_statement".to_string()],
            branches_body: vec!["block".to_string()],
            branches: vec!["block".to_string()],
            functions: vec!["function_definition".to_string()],
            values: vec!["identifier".to_string()],
            comments: vec!["comment".to_string()],
        },
    );

    // Nim language support
    m.insert(
        Lang::Nim,
        NodeNames {
            if_conditions: vec!["if_stmt".to_string(), "when_stmt".to_string(), "case_stmt".to_string()],
            else_conditions: vec!["else_branch".to_string()],
            loops: vec!["for_stmt".to_string(), "while_stmt".to_string()],
            branches_body: vec!["inline_stmt_list".to_string()],
            branches: vec!["inline_stmt_list".to_string()],
            functions: vec!["routine_definition".to_string()],
            values: vec!["identifier".to_string()],
            comments: vec!["comment".to_string()],
        },
    );

    m
});

#[derive(Debug, Clone)]
pub struct FileInfo {
    loop_shapes: Vec<LoopShape>,
    position_loops: HashMap<Position, LoopShapeId>,
    variables: HashMap<Position, Vec<String>>,
    functions: HashMap<Position, Vec<(String, Position, Position)>>,
    source_code: String,
    file_lines: Vec<String>,
    branch: Vec<Branch>,
    position_branches: HashMap<Position, Branch>,
    // active_loops: Vec<Position>,
    comment_lines: Vec<Position>,
}

impl FileInfo {
    pub fn new(source_code: &str) -> Self {
        FileInfo {
            loop_shapes: vec![LoopShape::default()],
            position_loops: HashMap::new(),
            variables: HashMap::new(),
            functions: HashMap::new(),
            file_lines: vec!["".to_string()],
            source_code: source_code.to_string(),
            branch: vec![],
            position_branches: HashMap::default(),
            // active_loops: vec![],
            comment_lines: vec![],
        }
    }
}

fn field_name_in_parent(node: &Node) -> Option<String> {
    let parent = node.parent()?;
    let mut cursor = parent.walk();
    if !cursor.goto_first_child() {
        return None;
    }

    loop {
        if cursor.node() == *node {
            return cursor.field_name().map(|name| name.to_string());
        }
        if !cursor.goto_next_sibling() {
            break;
        }
    }
    None
}

fn is_word_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

fn find_expr_column_in_line(line: &str, expression: &str) -> Option<usize> {
    let mut search_start = 0;
    while search_start <= line.len() {
        let relative = line[search_start..].find(expression)?;
        let abs = search_start + relative;
        let before = line[..abs].chars().last();
        let after = line[abs + expression.len()..].chars().next();
        let before_ok = before.map_or(true, |c| !is_word_char(c));
        let after_ok = after.map_or(true, |c| !is_word_char(c));
        if before_ok && after_ok {
            // Columns are 1-based to align with editor APIs.
            return Some(line[..abs].chars().count() + 1);
        }
        search_start = abs + expression.len();
    }
    None
}

#[derive(Debug, Clone)]
pub struct ExprLoader {
    // parser: Parser,
    processed_files: HashMap<PathBuf, FileInfo>,
    loop_index: i64,
    pub trace: CoreTrace,
}

// TODO: separate into
//  ExprLoader and FileExprLoader
//  ExprLoader should have new/and current pub methods
//  but process_file should initialize
//  unique FileExprLoader and do the processing there
//
//  FileExprLoader will have a `file_info` field
//    and we will cleanup all the processed_files mut usage
//    to just `file_info.field` changes

// ExprLoader process_file would be something like
// let file_expr_loader = FileExprLoader::new(..);
// let file_info = file_expr_loader.process_file(.., ..)?;

#[allow(clippy::unwrap_used)]
impl ExprLoader {
    pub fn new(trace: CoreTrace) -> Self {
        ExprLoader {
            processed_files: HashMap::new(),
            loop_index: 1,
            trace,
        }
    }

    pub fn get_current_language(&self, path: &Path) -> Lang {
        if let Some(extension) = path.extension() {
            if extension == "nr" {
                Lang::Noir
            } else if extension == "rb" {
                Lang::Ruby
            } else if extension == "small" {
                Lang::Small
            } else if extension == "c" {
                Lang::C
            } else if extension == "cpp" || extension == "cc" || extension == "cpp" {
                Lang::Cpp
            } else if extension == "pas" {
                Lang::Pascal
            } else if extension == "rs" {
                Lang::RustWasm // TODO RustWasm?
            } else if extension == "py" {
                Lang::PythonDb
            } else if extension == "nim" || extension == "nims" || extension == "nimble" {
                Lang::Nim
            } else {
                Lang::Unknown
            }
        } else {
            Lang::Unknown
        }
    }

    pub fn parse_file(&self, path: &PathBuf) -> Result<Tree, Box<dyn Error>> {
        let raw = &self.processed_files[path].source_code;
        let lang = self.get_current_language(path);
        info!(
            "parse_file: path={} lang={:?} bytes={}",
            path.display(),
            lang,
            raw.len()
        );

        let mut parser = Parser::new();
        if lang == Lang::Noir || lang == Lang::RustWasm {
            parser.set_language(&tree_sitter_rust::LANGUAGE.into())?;
        } else if lang == Lang::C {
            parser.set_language(&tree_sitter_c::LANGUAGE.into())?;
        } else if lang == Lang::Cpp {
            parser.set_language(&tree_sitter_cpp::LANGUAGE.into())?;
        } else if lang == Lang::Pascal {
            parser.set_language(&tree_sitter_pascal::LANGUAGE.into())?;
        } else if lang == Lang::Ruby {
            parser.set_language(&tree_sitter_ruby::LANGUAGE.into())?;
        } else if lang == Lang::PythonDb {
            parser.set_language(&tree_sitter_python::LANGUAGE.into())?;
        } else if lang == Lang::Nim {
            parser.set_language(&tree_sitter_nim::LANGUAGE.into())?;
        } else {
            // else if lang == Lang::Small {
            //     parser.set_language(&tree_sitter_elisp::LANGUAGE.into())?;
            // } else {
            parser.set_language(&tree_sitter_rust::LANGUAGE.into())?;
        }

        parser
            .parse(raw, None)
            .ok_or(format!("problem with parsing {:?}", path).into())
    }

    pub fn get_source_line(&self, path: &PathBuf, row: usize) -> String {
        if row < self.processed_files[path].file_lines.len() {
            self.processed_files[path].file_lines[row].clone()
        } else {
            warn!(
                "problem with source file {}; row: {}; lines count: {}; info: {:?}",
                path.display(),
                row,
                self.processed_files[path].file_lines.len(),
                self.processed_files[path]
            );
            "".to_string()
        }
    }

    fn extract_expr(&mut self, node: &Node, path: &PathBuf, row: usize) -> String {
        let source_line = self.get_source_line(path, row);
        let start_col = node.start_position().column;
        let end_col = node.end_position().column;
        source_line[start_col..end_col].to_string()
    }

    fn get_method_name(&self, node: &Node, path: &PathBuf, row: usize) -> Option<String> {
        let lang = self.get_current_language(path);
        let source_code = self.get_source_line(path, row);

        // Helper function to recursively search for the identifier and return its column range
        fn find_identifier_range(node: &Node, values: &[String], depth: usize) -> Option<(usize, usize)> {
            // Limit recursion depth
            if depth > 5 {
                return None;
            }

            for child in node.children(&mut node.walk()) {
                if values.contains(&child.kind().to_string()) {
                    return Some((child.start_position().column, child.end_position().column));
                }
                // For Nim, the identifier is inside exported_symbol/symbol
                if child.kind() == "exported_symbol" || child.kind() == "symbol" {
                    if let Some(range) = find_identifier_range(&child, values, depth + 1) {
                        return Some(range);
                    }
                }
            }
            None
        }

        if let Some((start, end)) = find_identifier_range(node, &NODE_NAMES[&lang].values, 0) {
            return Some(source_code[start..end].to_string());
        }

        None
    }

    fn get_first_line(&self, node: &Node) -> Position {
        Position((node.start_position().row + 1) as i64)
    }

    fn get_last_line(&self, node: &Node) -> Position {
        Position((node.end_position().row + 1) as i64)
    }

    fn extract_branches(&mut self, node: &Node, start: &Position, path: &PathBuf, opposite: &BranchId) {
        let lang = self.get_current_language(path);
        let mut branch = Branch::new();
        branch.header_line = *start;
        branch.code_first_line = self.get_first_line(node).inc();

        for (i, n) in node.children(&mut node.walk()).enumerate() {
            if NODE_NAMES[&lang].branches_body.contains(&n.kind().to_string()) {
                branch.code_last_line = self.get_last_line(&n);
                branch.is_none = false;
                if NODE_NAMES[&lang].branches.contains(&n.kind().to_string()) {
                    branch.branch_id = BranchId(self.processed_files[path].branch.len() as i64);
                    if opposite != &NO_BRANCH_ID {
                        branch.opposite.push(opposite.clone());
                        self.processed_files.get_mut(path).unwrap().branch[opposite.0 as usize]
                            .opposite
                            .push(branch.branch_id.clone());
                    }
                    self.processed_files.get_mut(path).unwrap().branch.push(branch.clone());
                }
            } else if (NODE_NAMES[&lang].if_conditions.contains(&n.kind().to_string())
                || NODE_NAMES[&lang].else_conditions.contains(&n.kind().to_string()))
                && i > 0
            {
                branch.is_none = false;
                branch.branch_id = BranchId(self.processed_files[path].branch.len() as i64);
                if opposite != &NO_BRANCH_ID {
                    branch.opposite.push(opposite.clone());
                    self.processed_files.get_mut(path).unwrap().branch[opposite.0 as usize]
                        .opposite
                        .push(branch.branch_id.clone());
                }
                self.processed_files.get_mut(path).unwrap().branch.push(branch.clone());
                self.extract_branches(&n, &self.get_first_line(&n), path, &branch.branch_id.clone());
                if !NODE_NAMES[&lang].if_conditions.contains(&n.kind().to_string()) {
                    break;
                }
            }
        }
    }

    fn count_leading_spaces(&mut self, line: &str) -> usize {
        line.chars().take_while(|c| c.is_whitespace()).count()
    }

    fn is_child_by_field_name(parent: &Node, node: &Node, field: &str) -> bool {
        parent.child_by_field_name(field).map_or(false, |n| n == *node)
    }

    fn is_variable_node(&self, lang: Lang, node: &Node) -> bool {
        match lang {
            Lang::Rust | Lang::RustWasm => {
                // NOTE: this is by no mean complete
                if node.kind() != "identifier" {
                    return false;
                }

                let Some(parent) = node.parent() else {
                    return true;
                };

                let parent_kind = parent.kind();

                match parent_kind {
                    "macro_definition"
                    | "macro_invocation"
                    | "mod_item"
                    | "enum_variant"
                    | "extern_crate_declaration"
                    | "static_item"
                    | "function_item"
                    | "function_signature_item"
                    | "generic_function" => return false,
                    _ => {}
                }

                let Some(node_name_in_parent) = field_name_in_parent(node) else {
                    return true;
                };

                if parent_kind == "scoped_identifier" && node_name_in_parent == "path" {
                    return false;
                }

                if parent_kind == "scoped_identifier" {
                    if let Some(grandparent) = parent.parent() {
                        if grandparent.kind() == "call_expression" {
                            return false;
                        }
                    }
                }

                true
            }
            Lang::Nim => {
                // Filter out non-variable identifiers in Nim
                if node.kind() != "identifier" {
                    return false;
                }

                let Some(parent) = node.parent() else {
                    return true;
                };

                let parent_kind = parent.kind();

                // Filter out routine definitions (proc, func, method, iterator, etc.)
                // The identifier is the "name" field of routine_definition
                if parent_kind == "routine_definition" {
                    if let Some(name_field) = field_name_in_parent(node) {
                        if name_field == "name" {
                            return false;
                        }
                    }
                }

                // Filter out exported_symbol (used in routine names, type names, etc.)
                if parent_kind == "exported_symbol" {
                    if let Some(grandparent) = parent.parent() {
                        let grandparent_kind = grandparent.kind();
                        // Routine definitions, type definitions, enum fields
                        if matches!(grandparent_kind, "routine_definition" | "type_def" | "enum_field_def") {
                            return false;
                        }
                    }
                }

                // Filter out function calls - identifier followed by call_suffix
                if parent_kind == "postfix_expr" || parent_kind == "command_expr" {
                    if let Some(field_name) = field_name_in_parent(node) {
                        if field_name == "function" {
                            return false;
                        }
                    }
                }

                // Filter out function calls
                // For function calls like run(), the AST structure is:
                //   postfix_expr
                //     postfixable_primary
                //       qualified_identifier
                //         symbol
                //           identifier "run"
                //     call_suffix
                //       (
                //       )
                // So the identifier has ancestors: symbol -> qualified_identifier -> postfixable_primary -> postfix_expr
                // We need to traverse up and check if any ancestor is postfix_expr with a call_suffix child

                // Handle the case where parent is "symbol" (common in Nim)
                let mut current = parent.clone();
                let mut check_parent = parent_kind.to_string();

                // Navigate up through symbol and qualified_identifier to reach postfixable_primary/postfix_expr
                while check_parent == "symbol" || check_parent == "qualified_identifier" {
                    if let Some(next) = current.parent() {
                        current = next;
                        check_parent = current.kind().to_string();
                    } else {
                        break;
                    }
                }

                // Now current should be postfixable_primary
                if check_parent == "postfixable_primary" {
                    if let Some(postfix_parent) = current.parent() {
                        if postfix_parent.kind() == "postfix_expr" {
                            // Check if there's a call_suffix sibling
                            let mut cursor = postfix_parent.walk();
                            if cursor.goto_first_child() {
                                loop {
                                    if cursor.node().kind() == "call_suffix" {
                                        return false; // This is a function call
                                    }
                                    if !cursor.goto_next_sibling() {
                                        break;
                                    }
                                }
                            }
                            // Also check if postfix_expr is inside command_expr (e.g., echo x)
                            if let Some(grandparent) = postfix_parent.parent() {
                                if grandparent.kind() == "command_expr" {
                                    return false;
                                }
                            }
                        }
                        // Direct command_expr as parent of postfixable_primary
                        if postfix_parent.kind() == "command_expr" {
                            return false;
                        }
                    }
                }

                // Direct check for postfix_expr or command_expr in the ancestor chain
                if parent_kind == "postfix_expr" || parent_kind == "command_expr" {
                    return false;
                }

                // Filter out type names in type expressions
                // With the symbol node, we need to check: identifier -> symbol -> qualified_identifier -> type_expr
                if parent_kind == "symbol" || parent_kind == "qualified_identifier" {
                    let mut ancestor = parent.parent();
                    // Navigate up past symbol and qualified_identifier
                    while let Some(anc) = ancestor {
                        let anc_kind = anc.kind();
                        if anc_kind == "symbol" || anc_kind == "qualified_identifier" {
                            ancestor = anc.parent();
                        } else if matches!(
                            anc_kind,
                            "type_expr"
                                | "ref_type"
                                | "ptr_type"
                                | "var_type"
                                | "generic_type"
                                | "param_decl"
                                | "object_field"
                        ) {
                            return false;
                        } else {
                            break;
                        }
                    }
                }

                // Filter out import/export identifiers
                if matches!(
                    parent_kind,
                    "import_stmt"
                        | "export_stmt"
                        | "import_expr"
                        | "import_path"
                        | "import_symbol"
                        | "from_import_stmt"
                        | "include_stmt"
                ) {
                    return false;
                }

                true
            }
            _ => NODE_NAMES[&lang].values.contains(&node.kind().to_string()),
        }
    }

    fn process_node(&mut self, node: &Node, path: &PathBuf) -> Result<(), Box<dyn Error>> {
        let row = node.start_position().row + 1;
        let start = self.get_first_line(node);
        let end = self.get_last_line(node);
        let lang = self.get_current_language(path);
        debug!(
            "process_node {:?} {:?} {:?} {:?} {:?}",
            lang,
            NODE_NAMES[&lang].loops,
            node.kind(),
            start,
            end,
        );
        // extract variable names
        if self.is_variable_node(lang, node) {
            let value = self.extract_expr(node, path, row);
            self.processed_files
                .get_mut(path)
                .unwrap()
                .variables
                .entry(start)
                .or_default()
                .push(value);
        // extract function names and positions
        } else if NODE_NAMES[&lang].functions.contains(&node.kind().to_string()) {
            if let Some(name) = self.get_method_name(node, path, row) {
                info!("register functions from {} to {}", start.0, end.0);
                for i in start.0..end.0 + 1 {
                    self.processed_files
                        .get_mut(path)
                        .unwrap()
                        .functions
                        .entry(Position(i))
                        .or_default()
                        .push((name.to_string(), start, end));
                }
                self.loop_index = 1;
            }
        } else if NODE_NAMES[&lang].loops.contains(&node.kind().to_string()) && start != end {
            self.register_loop(start, end, path)
        } else if lang == Lang::Ruby && node.kind() == "call" {
            if let Some(block_node) = node.child_by_field_name("block") {
                if let Some(method_node) = node.child_by_field_name("method") {
                    let row = method_node.start_position().row + 1;
                    let method_name = self.extract_expr(&method_node, path, row);
                    if method_name == "each" {
                        let start = self.get_first_line(&block_node);
                        let end = self.get_last_line(&block_node);
                        self.register_loop(start, end, path);
                    }
                }
            }
        } else if NODE_NAMES[&lang].if_conditions.contains(&node.kind().to_string()) {
            self.extract_branches(node, &start, path, &NO_BRANCH_ID);
        } else if NODE_NAMES[&lang].comments.contains(&node.kind().to_string()) {
            let source_line = self.get_source_line(path, row);
            if self.count_leading_spaces(&source_line) == node.start_position().column {
                self.processed_files.get_mut(path).unwrap().comment_lines.push(start);
            }
        }
        // } else if lang == Lang::Small {
        //     // info!("node kind {:?}", node.kind().to_string());
        //     if node.kind() == "list" {
        //         if let Some(name_node) = &node.child(1) {
        //             let name = self.extract_expr(name_node, path, self.get_first_line(name_node).0 as usize);
        //             // info!("name ::::::::::: {name}");
        //             if name == "loop" {
        //                 self.register_loop(start, end, path);
        //             }
        //         }
        //     }
        // }
        Ok(())
    }

    fn find_real_path(&self, path: &PathBuf) -> PathBuf {
        let read_path = if self.trace.imported {
            let trace_files_folder = PathBuf::from(&self.trace.trace_output_folder).join("files");
            // take only after root: /path -> path, so join will work,
            // because otherwise join /trace_output, /path returns just /path
            // but we want /trace_output/path
            let after_root_path = &(path.display().to_string())[1..];
            info!("after root path {after_root_path:?}");
            trace_files_folder.join(PathBuf::from(after_root_path))
        } else {
            path.clone()
        };

        read_path
    }

    pub fn file_source_code(&self, path: &PathBuf) -> Result<String, Box<dyn Error>> {
        if !self.processed_files.contains_key(path) {
            let read_path = self.find_real_path(path);
            info!("try to read {read_path:?}");
            let source_result = fs::read_to_string(read_path);
            match source_result {
                Ok(source_code) => Ok(source_code),
                Err(e) => {
                    if self.trace.imported {
                        // trying with original path
                        // instead of trace source one
                        // if we fail again, we return error with ?
                        // for the whole function
                        info!("now try to read {path:?}");
                        Ok(fs::read_to_string(path)?)
                    } else {
                        // we tried the original path if not imported
                        // directly return the error
                        Err(e.into())
                    }
                }
            }
        } else {
            Ok(self.processed_files[path].source_code.clone())
        }
    }

    pub fn load_file(&mut self, path: &PathBuf) -> Result<(), Box<dyn Error>> {
        if !self.processed_files.contains_key(path) {
            let source_code = self.file_source_code(path)?;
            let mut file_info = FileInfo::new(&source_code);
            file_info
                .file_lines
                .extend(source_code.split('\n').map(|s| s.to_string()).collect::<Vec<_>>());
            file_info.source_code = source_code.clone();
            self.processed_files.insert(path.clone(), file_info);
            match self.parse_file(path) {
                Ok(tree) => {
                    self.process_file(&tree, path)?;
                    info!("info for {:?} loaded", path);
                }
                Err(e) => {
                    self.processed_files.remove(path);
                    warn!("can't process file {:?}: error {}", path, e);
                }
            }
        }
        Ok(())
    }

    pub fn load_branch_for_position(&self, position: Position, path: &PathBuf) -> HashMap<usize, BranchState> {
        let mut results: HashMap<usize, BranchState> = HashMap::default();
        if self.processed_files.contains_key(path)
            && self.processed_files[path].position_branches.contains_key(&position)
        {
            info!("branches {:?}", self.processed_files[path].position_branches);

            let mut branch = self.processed_files[path].position_branches[&position].clone();
            branch.status = BranchState::Taken;
            results.insert(branch.header_line.0 as usize, branch.status);
            for op in branch.opposite {
                results.insert(
                    self.processed_files[path].branch[op.0 as usize].header_line.0 as usize,
                    BranchState::NotTaken,
                );
            }
        }
        results
    }

    pub fn final_branch_load(
        &self,
        path: &PathBuf,
        check_list: &HashMap<usize, BranchState>,
    ) -> HashMap<usize, BranchState> {
        let mut results: HashMap<usize, BranchState> = HashMap::default();
        if self.processed_files.contains_key(path) {
            for branch in &self.processed_files[path].branch {
                if !check_list.contains_key(&(branch.header_line.0 as usize)) && branch.status == BranchState::Unknown {
                    results.insert(branch.header_line.0 as usize, BranchState::NotTaken);
                }
            }
        }
        results
    }

    pub fn get_loop_shape(&self, line: Position, path: &PathBuf) -> Option<LoopShape> {
        info!("path {}", path.display());
        info!(
            "get_loop_shape {} {:?}",
            line.0,
            self.processed_files.get(path)?.position_loops
        );
        if let Some(loop_shape_id) = self.processed_files.get(path)?.position_loops.get(&line) {
            return Some(self.processed_files.get(path)?.loop_shapes[loop_shape_id.0 as usize].clone());
        }
        None
    }

    fn process_file(&mut self, tree: &Tree, path: &PathBuf) -> Result<(), Box<dyn Error>> {
        let lang = self.get_current_language(path);
        let postorder: Vec<Node<'_>> = traverse_tree(tree, Order::Post).collect::<Vec<_>>();
        for node in postorder {
            debug!("node {:?}", node.to_sexp());
            if NODE_NAMES.contains_key(&lang) && !NODE_NAMES[&lang].else_conditions.contains(&node.kind().to_string()) {
                self.process_node(&node, path)?;
            }
        }
        let mut position_branches: HashMap<Position, Branch> = HashMap::default();
        for branch in &self.processed_files[path].branch {
            position_branches.insert(branch.code_first_line, branch.clone());
        }
        self.processed_files.get_mut(path).unwrap().position_branches = position_branches;
        // TODO process loops, branches, exprs
        Ok(())
    }

    // #[allow(dead_code)]
    // fn is_new_loop(&self, start: &Position, file_info: &FileInfo) -> bool {
    //     file_info.position_loops.contains_key(start)
    //     // && !file_info.active_loops.contains(start)
    // }

    fn is_new_loop_shape(&self, start: &Position, file_info: &FileInfo) -> bool {
        !file_info.position_loops.contains_key(start)
        // && !file_info.active_loops.contains(start)
    }

    pub fn register_loop(&mut self, start: Position, end: Position, path: &PathBuf) {
        let lang = self.get_current_language(path);
        let offset = if lang == Lang::Ruby || lang == Lang::RustWasm {
            1
        } else {
            0
        };
        info!("current lang: {lang:?}");
        let start_with_offset = Position(start.0 + offset);
        if self.is_new_loop_shape(&start_with_offset, &self.processed_files[path]) {
            info!("new loop shape: {start_with_offset:?}");
            let loop_shape = LoopShape::new(
                LoopShapeId(self.processed_files[path].loop_shapes.len() as i64),
                LoopShapeId(self.loop_index),
                start_with_offset,
                end,
            );
            self.loop_index += 1;
            info!("register loop {start_with_offset:?} {end:?}");
            self.processed_files
                .get_mut(path)
                .unwrap()
                .loop_shapes
                .push(loop_shape.clone());
            self.processed_files
                .get_mut(path)
                .unwrap()
                .position_loops
                .insert(start_with_offset, loop_shape.base);
        }
    }

    // line: &Line
    pub fn get_first_last_fn_lines(&self, location: &Location) -> (i64, i64) {
        info!("get_first_last_fn_lines {:?}:{}", location.path, location.line);
        let (_, mut start, mut end): (String, Position, Position) =
            (String::default(), Position(NO_POSITION), Position(NO_POSITION));
        let path_buf = &PathBuf::from(&location.path);
        if self.processed_files.contains_key(path_buf) {
            let file_info = &self.processed_files[path_buf];
            let position = &Position(location.line);
            // info!("  check for position {:?} in {:?}", position, file_info.functions);
            if file_info.functions.contains_key(position) {
                (_, start, end) = file_info.functions[position][0].clone();
            }
        }
        info!("  result {} {}", start.0, end.0);
        (start.0, end.0)
    }

    pub fn find_function_location(&self, location: &Location, line: &Line) -> Location {
        let mut updated_location = location.clone();
        let path_buf = &PathBuf::from(&location.path);
        if self.processed_files.contains_key(path_buf) {
            let file_info = &self.processed_files[path_buf];
            let position = &Position(line.0);
            if file_info.functions.contains_key(position) {
                let (name, start, end) = &file_info.functions[position][0];
                updated_location.function_name = name.to_string();
                updated_location.high_level_function_name = name.to_string();
                updated_location.function_first = start.0;
                updated_location.high_level_line = start.0;
                updated_location.function_last = end.0;
            }
        }
        let real_path = self.find_real_path(path_buf);
        updated_location.missing_path = !real_path.exists();
        updated_location
    }

    pub fn get_expr_list(&self, line: Position, location: &Location) -> Option<Vec<String>> {
        self.processed_files
            .get(&PathBuf::from(&location.path))
            .and_then(|file| file.variables.get(&line).cloned())
    }

    // Returns a 1-based column index for the first whole-word occurrence of the expression on the line.
    pub fn get_expr_column(&self, line: Position, expression: &str, location: &Location) -> Option<usize> {
        if expression.is_empty() {
            return None;
        }
        let path = PathBuf::from(&location.path);
        let file_info = self.processed_files.get(&path)?;
        let line_index = line.0.checked_sub(1)? as usize;
        let source_line = file_info.file_lines.get(line_index)?;
        find_expr_column_in_line(source_line, expression)
    }
    // pub fn load_loops(&mut self, )

    pub fn get_comment_positions(&self, path: &PathBuf) -> Vec<Position> {
        self.processed_files
            .get(path)
            .unwrap_or(&FileInfo::new(""))
            .comment_lines
            .clone()
    }
}

//     iteration: Iteration
// base_iteration: Iteration
// step_counts: List[StepCount]
// rr_ticks_for_iterations: List[RRTicks]

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn detects_ruby_each_loop() -> Result<(), Box<dyn std::error::Error>> {
        let tmp_dir = std::env::temp_dir();
        let file_path = tmp_dir.join("each_loop_test.rb");
        fs::write(&file_path, "arr = [1]\narr.each do |x|\n  puts x\nend\n")?;

        let mut loader = ExprLoader::new(CoreTrace::default());
        loader.load_file(&file_path)?;

        let info = &loader.processed_files[&file_path];
        assert_eq!(info.loop_shapes.len(), 2);
        let shape = &info.loop_shapes[1];
        assert_eq!(shape.first, Position(3));
        assert_eq!(shape.last, Position(4));

        fs::remove_file(&file_path)?;
        Ok(())
    }
}

#[cfg(test)]
mod nim_tests {
    use super::*;

    /// Test that Nim function calls are correctly filtered out of the variable list
    /// while actual variables are preserved.
    #[test]
    fn test_nim_excludes_function_calls_from_variables() {
        use std::fs;

        // Nim code with function calls that should NOT be extracted as variables
        let code = r#"
when isMainModule:
  run()
  let x = 10
  exampleFlow1()
  echo x
"#;

        let tmp_dir = std::env::temp_dir();
        let file_path = tmp_dir.join("nim_func_test.nim");
        fs::write(&file_path, code).unwrap();

        let mut loader = ExprLoader::new(CoreTrace::default());
        loader.load_file(&file_path).unwrap();

        let info = &loader.processed_files[&file_path];

        // Collect all extracted variables
        let all_vars: Vec<String> = info.variables.values().flatten().cloned().collect();

        // Function calls should NOT be in the variables list
        assert!(!all_vars.contains(&"run".to_string()), "run() should not be a variable");
        assert!(
            !all_vars.contains(&"exampleFlow1".to_string()),
            "exampleFlow1() should not be a variable"
        );
        assert!(!all_vars.contains(&"echo".to_string()), "echo should not be a variable");

        // But x should be in the variables list
        assert!(all_vars.contains(&"x".to_string()), "x should be a variable");

        fs::remove_file(&file_path).unwrap();
    }

    /// Test that variables inside Nim procs are correctly extracted
    #[test]
    fn test_nim_variables_inside_proc() {
        use std::fs;

        let code = r#"proc main() =
  let intValue = 42
  let stringValue = "hello"
  let doubled = intValue * 2
  echo intValue
  echo doubled

main()
"#;

        let tmp_dir = std::env::temp_dir();
        let file_path = tmp_dir.join("nim_proc_vars.nim");
        fs::write(&file_path, code).unwrap();

        let mut loader = ExprLoader::new(CoreTrace::default());
        loader.load_file(&file_path).unwrap();

        let info = &loader.processed_files[&file_path];

        // Print all extracted variables by line
        println!("Variables by line:");
        for (pos, vars) in &info.variables {
            println!("  Line {}: {:?}", pos.0, vars);
        }

        // Line 5 (echo intValue) should have intValue as a variable
        let line5_vars = info.variables.get(&Position(5));
        println!("Line 5 (echo intValue): {:?}", line5_vars);
        assert!(
            line5_vars.is_some() && line5_vars.unwrap().contains(&"intValue".to_string()),
            "intValue should be extracted from echo line"
        );

        // Line 2 (let intValue = 42) should have intValue
        let line2_vars = info.variables.get(&Position(2));
        println!("Line 2 (let intValue): {:?}", line2_vars);
        assert!(
            line2_vars.is_some() && line2_vars.unwrap().contains(&"intValue".to_string()),
            "intValue should be extracted from let line"
        );

        fs::remove_file(&file_path).unwrap();
    }

    /// Test that Nim proc definitions are correctly identified
    #[test]
    fn test_nim_proc_function_registration() {
        use std::fs;
        use tree_sitter::Parser;

        let code = r#"proc main() =
  let x = 42
  echo x

main()
"#;

        // First, let's see what tree-sitter-nim produces
        let mut parser = Parser::new();
        parser.set_language(&tree_sitter_nim::LANGUAGE.into()).unwrap();
        let tree = parser.parse(code, None).unwrap();

        fn print_tree(node: tree_sitter::Node, depth: usize) {
            let indent = "  ".repeat(depth);
            let start = node.start_position();
            let end = node.end_position();
            println!("{}{}: lines {}-{}", indent, node.kind(), start.row + 1, end.row + 1);

            let mut cursor = node.walk();
            if cursor.goto_first_child() {
                loop {
                    print_tree(cursor.node(), depth + 1);
                    if !cursor.goto_next_sibling() {
                        break;
                    }
                }
            }
        }

        println!("\n=== Nim AST ===");
        print_tree(tree.root_node(), 0);

        let tmp_dir = std::env::temp_dir();
        let file_path = tmp_dir.join("nim_proc_test.nim");
        fs::write(&file_path, code).unwrap();

        let mut loader = ExprLoader::new(CoreTrace::default());
        loader.load_file(&file_path).unwrap();

        let info = &loader.processed_files[&file_path];

        // Print debug info about functions
        println!("\nFunctions registered:");
        for (pos, funcs) in &info.functions {
            for (name, start, end) in funcs {
                println!("  Line {}: {} (lines {}-{})", pos.0, name, start.0, end.0);
            }
        }

        // Lines 1-4 should be registered as part of the main() function
        assert!(
            info.functions.contains_key(&Position(1)),
            "Line 1 (proc main) should be registered"
        );
        assert!(
            info.functions.contains_key(&Position(2)),
            "Line 2 (let x) should be registered as part of main"
        );
        assert!(
            info.functions.contains_key(&Position(3)),
            "Line 3 (echo x) should be registered as part of main"
        );

        fs::remove_file(&file_path).unwrap();
    }
}
