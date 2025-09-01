use std::error::Error;

use log::info;
use tree_sitter::Node;

use crate::tracepoint_interpreter::{Instruction, Opcode};

pub fn compile_expression(node: Node, source: &str) -> Result<Vec<Opcode>, Box<dyn Error>> {
    info!("compile_expression {}. Node kind \"{}\".", node.to_sexp(), node.kind());
    match node.kind() {
        "source_file" => {
            let mut opcodes = vec![];
            let mut i = 0;
            // TODO len
            while let Some(child) = node.child(i) {
                let mut expr_opcodes = compile_expression(child, source)?;
                opcodes.append(&mut expr_opcodes);
                i += 1;
            }
            Ok(opcodes)
        }

        "integer" => {
            // for now assume the same line
            let start = node.start_byte();
            let end = node.end_byte();

            let raw_value = &source[start..end];
            let value = raw_value.parse()?;

            let opcodes = vec![Opcode::new(Instruction::PushInt(value), node.range())];
            Ok(opcodes)
        }

        "float" => {
            // for now assume the same line
            let start = node.start_byte();
            let end = node.end_byte();

            let raw_value = &source[start..end];
            let value = raw_value.parse()?;

            let opcodes = vec![Opcode::new(Instruction::PushFloat(value), node.range())];
            Ok(opcodes)
        }

        "booleanLiteral" => {
            let start = node.start_byte();
            let end = node.end_byte();

            let raw_value = &source[start..end];
            let value = raw_value.parse()?;

            let opcodes = vec![Opcode::new(Instruction::PushBool(value), node.range())];

            Ok(opcodes)
        }

        "string" => {
            let start = node.start_byte();
            let end = node.end_byte();

            let value = source[(start + 1)..(end - 1)].to_string();

            let opcodes = vec![Opcode::new(Instruction::PushString(value), node.range())];

            Ok(opcodes)
        }

        "interpolatedString" => {
            // TODO: handle codeInString nodes.
            // For now assume, that this is just string.

            let start = node.start_byte();
            let end = node.end_byte();

            let value = source[(start + 1)..(end - 1)].to_string();

            let opcodes = vec![Opcode::new(Instruction::PushString(value), node.range())];

            Ok(opcodes)
        }

        "name" => {
            let start = node.start_byte();
            let end = node.end_byte();

            let name = source[start..end].to_string();

            let opcodes = vec![Opcode::new(Instruction::PushVariable(name), node.range())];
            Ok(opcodes)
        }

        "logExpression" => {
            let child_count = node.named_child_count();

            if child_count == 0 {
                return Err("expected arg to `log`".to_string().into());
            }

            let mut opcodes = vec![];

            for i in 0..child_count {
                if let Some(arg_node) = node.named_child(i) {
                    let mut expr_opcodes = compile_expression(arg_node, source)?;
                    opcodes.append(&mut expr_opcodes);
                    // (alexander: not exact, but using `arg_node` range to make it easy to
                    //   get the actual arg expression for logs in the evaluation:
                    //   `arg`, instead of the whole `log(arg)`)
                    opcodes.push(Opcode::new(Instruction::Log, arg_node.range()));
                } else {
                    return Err(format!("No child with id {i}").into());
                }
            }

            Ok(opcodes)
        }

        "indexExpression" => {
            let mut opcodes = vec![];
            if let Some(collection_node) = node.named_child(0) {
                let mut collection_opcodes = compile_expression(collection_node, source)?;
                opcodes.append(&mut collection_opcodes);
            } else {
                return Err("expected collection expression for index".to_string().into());
            }

            if let Some(index_node) = node.named_child(1) {
                let mut index_opcodes = compile_expression(index_node, source)?;
                opcodes.append(&mut index_opcodes);
            } else {
                return Err("expected index expression".to_string().into());
            }

            opcodes.push(Opcode::new(Instruction::Index, node.range()));

            Ok(opcodes)
        }

        "binaryOperationExpression" => {
            let mut opcodes = vec![];
            let raw_op: String;

            if let Some(left_node) = node.named_child(0) {
                let mut left_opcodes = compile_expression(left_node, source)?;
                opcodes.append(&mut left_opcodes);
            } else {
                return Err("expected left expression for binary op".to_string().into());
            }

            if let Some(right_node) = node.named_child(1) {
                let mut right_opcodes = compile_expression(right_node, source)?;
                opcodes.append(&mut right_opcodes);
            } else {
                return Err("expected right expression for binary op".to_string().into());
            }

            if let Some(op_node) = node.child_by_field_name("op") {
                let start = op_node.start_byte();
                let end = op_node.end_byte();

                raw_op = source[start..end].to_string();
            } else {
                return Err("expected operator expression for binary op".to_string().into());
            }
            opcodes.push(Opcode::new(Instruction::BinaryOperation(raw_op), node.range()));

            Ok(opcodes)
        }

        "unaryOperationExpression" => {
            let mut opcodes = vec![];
            let raw_op: String;

            if let Some(operand_node) = node.named_child(0) {
                let mut operand_opcodes = compile_expression(operand_node, source)?;
                opcodes.append(&mut operand_opcodes);
            } else {
                return Err("expected operand expression for unary op".to_string().into());
            }

            if let Some(op_node) = node.child_by_field_name("op") {
                let start = op_node.start_byte();
                let end = op_node.end_byte();

                raw_op = source[start..end].to_string();
            } else {
                return Err("expected operator expression for unary op".to_string().into());
            }
            opcodes.push(Opcode::new(Instruction::UnaryOperation(raw_op), node.range()));

            Ok(opcodes)
        }

        "ifExpression" => {
            let mut opcodes = vec![];
            if let Some(condition_node) = node.child_by_field_name("condition") {
                let mut cond_opcodes = compile_expression(condition_node, source)?;
                opcodes.append(&mut cond_opcodes);
            } else {
                return Err("expected condition expression for if".to_string().into());
            }

            let mut body_opcodes = vec![];
            let mut else_opcodes = vec![];

            if let Some(body_node) = node.child_by_field_name("body") {
                let mut curr_opcodes = compile_expression(body_node, source)?;
                body_opcodes.append(&mut curr_opcodes);
            }

            if let Some(else_node) = node.child_by_field_name("else") {
                let mut curr_opcodes = compile_expression(else_node, source)?;
                else_opcodes.append(&mut curr_opcodes);
            }

            if !else_opcodes.is_empty() {
                // Unconditional jump is:
                // PUSH_BOOL false
                // JUMP_IF_FALSE

                body_opcodes.push(Opcode::new(Instruction::PushBool(false), node.range()));

                body_opcodes.push(Opcode::new(
                    Instruction::JumpIfFalse(else_opcodes.len() as i64 + 1),
                    node.range(),
                ));
            }

            opcodes.push(Opcode::new(
                Instruction::JumpIfFalse(body_opcodes.len() as i64 + 1),
                node.range(),
            ));

            opcodes.append(&mut body_opcodes);
            opcodes.append(&mut else_opcodes);

            Ok(opcodes)
        }

        "codeBlock" => {
            let mut opcodes = vec![];

            for body_node in node.named_children(&mut node.walk()) {
                let mut curr_opcodes = compile_expression(body_node, source)?;
                opcodes.append(&mut curr_opcodes);
            }

            Ok(opcodes)
        }

        "\n" => Ok(vec![]),

        // if -> the block for if and then counting how many opcodes are there and using this
        // as offset for JUMP_IF_FALSE
        // generate an END after all opcodes to have a good target?
        // (but if jumping after all, we should just break anyway?)
        _ => Err(format!("unsupported node kind: {}", node.kind()).into()),
    }
}
