//     TracepointInterpreter {..}
//       parse(&str) -> TsNode using tree_sitter
//       (store those nodes)
//
//       evaluate(node, &db) -> Vec<NamedValueRecord>
//
//    }
//    some form of tests
//
//    maybe parse_and_evaluate(code: &str) -> Vec<..>
//    and test etc

use std::collections::HashMap;
use std::error::Error;

use codetracer_trace_types::{StepId, TypeKind};
use log::info;
use tree_sitter::{Node, Parser};
use tree_sitter_traversal2::{traverse, Order};

use crate::lang::Lang;
use crate::replay::Replay;
use crate::task::StringAndValueTuple;
use crate::tracepoint_interpreter::executor::execute_bytecode;
use crate::value::{Type, Value};

use super::compiler::compile_expression;
use super::operator_functions::{
    operator_and, operator_div, operator_equal, operator_greater, operator_greater_equal, operator_less,
    operator_less_equal, operator_minus, operator_mult, operator_negation, operator_not, operator_not_equal,
    operator_or, operator_plus, operator_rem,
};
use super::{BinaryOperatorFunctions, Bytecode, UnaryOperatorFunctions};

// options
//   * pass correct lifetimes: not sure if i can do it(alexander)
//   or
//   * for now just parse for every evaluation: slow but maybe ok for first version
//   or
//   * convert to our owned Node api: a bit more work and a bit slower in register but
//     conceptually simpler, maybe easier for interpreter..
//   * if we are converting, we can convert directly to some kind of bytecode instead?

// log(a); ->
// stack-based;
//
// 0: a;
// PUSH_VAR 0
// LOG

// log(a.b) ->
// 0: a; 1: b
// PUSH_VAR 0
// FIELD 1
// LOG

// log(a[0]) ->
// 0: a;
// PUSH_VAR 0
// PUSH_INT 0
// INDEX
// LOG

// if a[0] < 2 {
//   log(a)
// }

// 0: a;
// 0    PUSH_VAR 0
// 1    PUSH_INT 0
// 2    INDEX
// 3    PUSH_INT 2
// 4    BINARY_OPERATIOIN "<"
// 5    JUMP_IF_FALSE 3 # relative: easier to generate
// 6    PUSH_VAR 0
// 7    LOG
// 8    END

// if we decide, we want a distinct/newtype:
// #[derive(Debug, Clone, Copy, Default)]
// struct Arg(i64);

// original position for the original node/source
// #[derive(Debug, Clone, Default)]
// pub struct Position {
//     pub line: usize,
//     pub column: usize,
// }

// log(a.b);
// log(a[index])
// if a { log(c) }

// as in nim we'll call ^1 the last(top) element in the stack,
// ^2 second last etc

#[derive(Debug)]
pub struct TracepointInterpreter {
    // TODO caching ts-node?
    sources: Vec<String>,
    bytecodes: Vec<Bytecode>,
    compile_errors: Vec<Vec<String>>, // TODO: maybe there is a better way to represent compile errors?
    unary_op_functions: UnaryOperatorFunctions,
    binary_op_functions: BinaryOperatorFunctions,
}

impl TracepointInterpreter {
    pub fn new(tracepoint_count: usize) -> Self {
        let mut res = Self {
            sources: vec![String::default(); tracepoint_count],
            bytecodes: vec![Bytecode::default(); tracepoint_count],
            compile_errors: vec![Vec::default(); tracepoint_count],
            unary_op_functions: HashMap::new(),
            binary_op_functions: HashMap::new(),
        };

        res.unary_op_functions.insert("!".to_string(), operator_not);
        res.unary_op_functions.insert("not".to_string(), operator_not);
        res.unary_op_functions.insert("не".to_string(), operator_not);
        res.unary_op_functions.insert("-".to_string(), operator_negation);

        res.binary_op_functions.insert("&&".to_string(), operator_and);
        res.binary_op_functions.insert("and".to_string(), operator_and);
        res.binary_op_functions.insert("и".to_string(), operator_and);
        res.binary_op_functions.insert("||".to_string(), operator_or);
        res.binary_op_functions.insert("or".to_string(), operator_or);
        res.binary_op_functions.insert("или".to_string(), operator_or);

        res.binary_op_functions.insert("+".to_string(), operator_plus);
        res.binary_op_functions.insert("-".to_string(), operator_minus);
        res.binary_op_functions.insert("*".to_string(), operator_mult);
        res.binary_op_functions.insert("/".to_string(), operator_div);
        res.binary_op_functions.insert("%".to_string(), operator_rem);

        res.binary_op_functions.insert("==".to_string(), operator_equal);
        res.binary_op_functions.insert("!=".to_string(), operator_not_equal);
        res.binary_op_functions.insert("<".to_string(), operator_less);
        res.binary_op_functions.insert("<=".to_string(), operator_less_equal);
        res.binary_op_functions.insert(">".to_string(), operator_greater);
        res.binary_op_functions.insert(">=".to_string(), operator_greater_equal);

        res
    }

    fn compile(&mut self, root_node: Node, tracepoint_index: usize) -> Result<(), Box<dyn Error>> {
        if root_node.has_error() {
            for node in traverse(root_node.walk(), Order::Pre) {
                if node.is_error() {
                    let error_message = format!(
                        "invalid syntax at line {} column {}",
                        node.start_position().row + 1,
                        node.start_position().column + 1
                    );
                    self.compile_errors[tracepoint_index].push(error_message.clone());
                    // for now directly return the first error
                    return Err(error_message.into());
                }
            }
            return Err("Tracepoint syntax error".into());
        }

        let opcodes = compile_expression(root_node, &self.sources[tracepoint_index])?;
        let bytecode = Bytecode { opcodes };
        info!("bytecode for {tracepoint_index}: {bytecode:?}");

        self.bytecodes[tracepoint_index] = bytecode;

        Ok(())
    }

    // tree-sitter: ok : build/etc
    // interpreter/tests: he can do it, me only as coop/if less time
    #[allow(clippy::expect_used)]
    #[allow(clippy::unwrap_used)]
    pub fn register_tracepoint(&mut self, tracepoint_index: usize, source: &str) -> Result<(), Box<dyn Error>> {
        self.sources[tracepoint_index] = source.to_string();

        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_tracepoint::LANGUAGE.into())
            .expect("Error loading tracepoint grammar");
        let tree = parser.parse(source, None).unwrap();
        let root_node = tree.root_node();
        // if self.nodes.len() <= tracepoint_index {
        //     self.nodes.resize(tracepoint_index, root_node.clone());
        // }
        info!("tree for \"{}\": {}", source, root_node.to_sexp());

        self.compile(root_node, tracepoint_index)?;

        Ok(())
    }

    pub fn evaluate(
        &self,
        tracepoint_index: usize,
        step_id: StepId,
        replay: &mut dyn Replay,
        lang: Lang,
    ) -> Vec<StringAndValueTuple> {
        if !self.compile_errors[tracepoint_index].is_empty() {
            let mut errors = vec![];

            let compile_error_type = Type::new(TypeKind::Error, "TracepointCompileError");

            for err in &self.compile_errors[tracepoint_index] {
                let mut err_value = Value::new(TypeKind::Error, compile_error_type.clone());
                err_value.msg = err.clone();
                errors.push(StringAndValueTuple {
                    field0: "ERROR".to_string(),
                    field1: err_value,
                });
            }

            return errors;
        }

        info!("evaluate tracepoint {tracepoint_index} on #{step_id:?}");

        let bytecode = &self.bytecodes[tracepoint_index];
        let source = &self.sources[tracepoint_index];

        execute_bytecode(
            bytecode,
            source,
            replay,
            &self.unary_op_functions,
            &self.binary_op_functions,
            lang,
        )
        // %log(i)2
        // -> notification : syntax error; we won't try to evaluate tracepoint

        // log(a, a + b); // a is string; b int8;
        // -> [(name: a, value: "a"), (name: a+b, value: Error(..))]
    }
}
