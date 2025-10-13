mod compiler;
mod executor;
mod interpreter;
mod operator_functions;

#[cfg(test)]
mod tests;

use std::collections::HashMap;

pub use interpreter::TracepointInterpreter;
use runtime_tracing::ValueRecord;

use crate::value::{Type, Value};

#[derive(Debug, Clone)]
enum Instruction {
    Log,                     // pops and logs stack[^1]
    PushVariable(String),    // adds its arg to top of stack
    PushInt(i64),            // adds its arg to top of stack
    PushFloat(f64),          // adds its arg to top of stack
    PushBool(bool),          // adds its arg to top of stack
    PushString(String),      // adds its arg to top of stack
    Index,                   // pops ^2, ^1 before pushing ^2[^1]
    UnaryOperation(String),  // pops ^1 before pushing <op> ^1
    BinaryOperation(String), // pops ^2, ^1 before pushing ^2 <op> ^1
    JumpIfFalse(i64),        // pops ^1 and if ^1 is false, adds its arg to the program counter
}

#[derive(Debug, Clone)]
struct Opcode {
    instruction: Instruction,
    position: tree_sitter::Range,
}

impl Opcode {
    fn new(instruction: Instruction, position: tree_sitter::Range) -> Opcode {
        Opcode { instruction, position }
    }
}

#[derive(Debug, Clone, Default)]
struct Bytecode {
    opcodes: Vec<Opcode>,
}

// op(operand, error_value_type)
type UnaryOperatorFunction = fn(ValueRecord, &Type) -> Result<ValueRecord, Value>;
type UnaryOperatorFunctions = HashMap<String, UnaryOperatorFunction>;

// op(left_operand, right_operand, error_value_type)
type BinaryOperatorFunction = fn(ValueRecord, ValueRecord, &Type) -> Result<ValueRecord, Value>;
type BinaryOperatorFunctions = HashMap<String, BinaryOperatorFunction>;
