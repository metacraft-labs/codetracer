use std::error::Error;
use std::path::PathBuf;

use log::warn;
use runtime_tracing::{CallKey, StepId, TypeId, ValueRecord};

use crate::db::Db;
use crate::expr_loader::ExprLoader;
use crate::task::{CodeSnippet, CommandPanelResult, Location};

pub struct ProgramSearchTool<'a> {
    db: &'a Db,
}

#[derive(Copy, Clone, Debug)]
pub enum Operator {
    Equal,
}

#[derive(Clone, Debug)]
pub enum ProgramQueryNode {
    Compare(Operator, Box<ProgramQueryNode>, Box<ProgramQueryNode>),
    Variable(String),
    Int(i64),
}

impl<'a> ProgramSearchTool<'a> {
    pub fn new(db: &'a Db) -> Self {
        ProgramSearchTool { db }
    }

    pub fn search(&self, query: &str, expr_loader: &mut ExprLoader) -> Result<Vec<CommandPanelResult>, Box<dyn Error>> {
        let node = self.parse(query)?;
        let results = self.run(node, expr_loader)?;
        // let _no_results_message = CommandPanelResult::success("no results");
        Ok(results)
    }

    pub fn parse(&self, query: &str) -> Result<ProgramQueryNode, Box<dyn Error>> {
        // tree-sitter?
        // or manual?
        // or other framework?
        //   pom is usable and we maybe want simpler queries, but on other hand
        //   even one line important syntax error
        // -> l4 op l5
        // nodes
        let tokens: Vec<&str> = query.split("==").collect();
        if tokens.len() != 2 {
            return Err("expected <left> == <right>".into());
        }
        let left = ProgramQueryNode::Variable(tokens[0].to_string());
        let right = ProgramQueryNode::Int(tokens[1].parse()?);
        let op = Operator::Equal;
        Ok(ProgramQueryNode::Compare(op, Box::new(left), Box::new(right)))
    }

    pub fn run(
        &self,
        node: ProgramQueryNode,
        expr_loader: &mut ExprLoader,
    ) -> Result<Vec<CommandPanelResult>, Box<dyn Error>> {
        match node {
            ProgramQueryNode::Compare(op, left, right) => Ok(self.search_compare(op, *left, *right, expr_loader)),
            ProgramQueryNode::Variable(_name) => {
                // maybe return all location/function where it's valid? with types?
                Ok(vec![CommandPanelResult::error("just a variable: not a valid query")])
            }
            ProgramQueryNode::Int(i) => Ok(vec![CommandPanelResult::success(&format!("{i}"))]),
        }
    }

    fn search_compare(
        &self,
        op: Operator,
        left: ProgramQueryNode,
        right: ProgramQueryNode,
        expr_loader: &mut ExprLoader,
    ) -> Vec<CommandPanelResult> {
        let mut results = vec![];
        for step_id_int in 0..self.db.steps.len() {
            match self.match_compare(StepId(step_id_int as i64), op, &left, &right, expr_loader) {
                Ok(new_result) => {
                    results.push(new_result);
                }
                Err(e) => {
                    warn!("{e:?}");
                }
            }
        }
        results
    }

    fn match_compare(
        &self,
        step_id: StepId,
        op: Operator,
        left: &ProgramQueryNode,
        right: &ProgramQueryNode,
        expr_loader: &mut ExprLoader,
    ) -> Result<CommandPanelResult, Box<dyn Error>> {
        // maybe compile to simpler check?
        // e.g. match_compare_expr etc

        let left_value = self.evaluate(step_id, left)?;
        let right_value = self.evaluate(step_id, right)?;
        match op {
            Operator::Equal => {
                if left_value == right_value {
                    let value = "".to_string(); // TODO "TODO value = <>".to_string();
                    let location = &self.db.load_location(step_id, CallKey(-1), expr_loader);
                    Ok(self.program_search_result(&value, location, expr_loader))
                } else {
                    Err("no match".into())
                }
            }
        }
    }

    fn program_search_result(
        &self,
        value: &str,
        location: &Location,
        expr_loader: &mut ExprLoader,
    ) -> CommandPanelResult {
        let source_res = expr_loader
            .file_source_code(&PathBuf::from(&location.path))
            .unwrap_or("<not readable>".to_string());
        let lines: Vec<&str> = source_res.split('\n').collect();

        // TODO
        assert!(location.line > 0);
        let location_line_0_based_index = (location.line - 1) as usize;

        let source_line = if lines.len() <= location_line_0_based_index {
            "<line/file not readable>"
        } else {
            lines[location_line_0_based_index]
        };
        let code_snippet = CodeSnippet {
            line: location.line as usize,
            source: source_line.to_string(),
        };
        CommandPanelResult::program_search_result(value, code_snippet, location.clone())
    }

    fn evaluate(&self, step_id: StepId, node: &ProgramQueryNode) -> Result<ValueRecord, Box<dyn Error>> {
        match node.clone() {
            ProgramQueryNode::Compare(_, _, _) => Err("evaluate compare not implemented".into()),
            ProgramQueryNode::Variable(name) => {
                for full_value_record in &self.db.variables[step_id] {
                    if self.db.variable_names[full_value_record.variable_id] == name {
                        return Ok(full_value_record.value.clone());
                    }
                }
                Err("variable not found".into())
            }
            // for now ignoring type id-s for Int nodes in program search
            // so passing just 0 for now
            ProgramQueryNode::Int(i) => Ok(ValueRecord::Int { i, type_id: TypeId(0) }),
        }
    }
}
