use crate::{
    lang::Lang,
    task::{
        Branch, BranchId, BranchState, CoreTrace, Location, LoopShape, LoopShapeId, Position, NO_BRANCH_ID, NO_POSITION,
    },
};
use log::{info, warn};
use once_cell::sync::Lazy;
use runtime_tracing::Line;
use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use tree_sitter::{Node, Parser, Tree}; // Language,
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

    let rust_node_names = NodeNames {
        if_conditions: vec!["if_expression".to_string()],
        else_conditions: vec!["else_clause".to_string()],
        loops: vec!["for_expression".to_string()],
        branches_body: vec!["block".to_string()],
        branches: vec!["block".to_string()],
        functions: vec!["function_item".to_string()],
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
            } else if extension == "rs" {
                Lang::RustWasm // TODO RustWasm?
            } else if extension == "py" {
                Lang::PythonDb
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

        let mut parser = Parser::new();
        if lang == Lang::Noir || lang == Lang::RustWasm {
            parser.set_language(&tree_sitter_rust::LANGUAGE.into())?;
        } else if lang == Lang::Ruby {
            parser.set_language(&tree_sitter_ruby::LANGUAGE.into())?;
        } else if lang == Lang::PythonDb {
            parser.set_language(&tree_sitter_python::LANGUAGE.into())?;
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
        self.processed_files[path].file_lines[row].clone()
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
        for child in node.children(&mut node.walk()) {
            if NODE_NAMES[&lang].values.contains(&child.kind().to_string()) {
                let start = child.start_position().column;
                let end = child.end_position().column;
                return Some(source_code[start..end].to_string());
            }
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

    fn process_node(&mut self, node: &Node, path: &PathBuf) -> Result<(), Box<dyn Error>> {
        let row = node.start_position().row + 1;
        let start = self.get_first_line(node);
        let end = self.get_last_line(node);
        let lang = self.get_current_language(path);
        // info!(
        //    "process_node {:?} {:?} {:?}",
        //    lang,
        //    NODE_NAMES[&lang].values,
        //    node.kind()
        //);
        // extract variable names
        if NODE_NAMES[&lang].values.contains(&node.kind().to_string()) {
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

    pub fn file_source_code(&self, path: &PathBuf) -> Result<String, Box<dyn Error>> {
        if !self.processed_files.contains_key(path) {
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
            // info!("node {:?}", node.to_sexp());
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
        updated_location
    }

    pub fn get_expr_list(&self, line: Position, location: &Location) -> Option<Vec<String>> {
        self.processed_files
            .get(&PathBuf::from(&location.path))
            .and_then(|file| file.variables.get(&line).cloned())
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
