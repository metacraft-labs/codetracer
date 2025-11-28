use std::path::PathBuf;

use log::info;
use runtime_tracing::{TypeKind, ValueRecord, NONE_TYPE_ID};

use crate::{
    db::{Db, DbReplay},
    lang::Lang,
    replay::Replay,
    task::StringAndValueTuple,
    tracepoint_interpreter::Instruction,
    value::{Type, Value},
};

use super::{BinaryOperatorFunctions, Bytecode, UnaryOperatorFunctions};

pub fn execute_bytecode(
    bytecode: &Bytecode,
    source: &str,
    replay: &mut dyn Replay,
    unary_op_functions: &UnaryOperatorFunctions,
    binary_op_functions: &BinaryOperatorFunctions,
    lang: Lang,
) -> Vec<StringAndValueTuple> {
    let opcodes = &bytecode.opcodes;

    let mut locals: Vec<StringAndValueTuple> = Default::default();

    let mut stack: Vec<ValueRecord> = vec![];

    let eval_error_type = Type::new(TypeKind::Error, "TracepointEvaluationError");

    let mut program_counter: i64 = 0;
    while program_counter < opcodes.len() as i64 {
        if program_counter < 0 {
            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
            err_value.msg = "TracepointVM program counter became negative! Please report this!".to_string();
            locals.push(StringAndValueTuple {
                field0: "Execution error".to_string(),
                field1: err_value,
            });
            return locals;
        }

        let opcode = &opcodes[program_counter as usize];

        info!("Current opcode: {:?}", opcode);
        info!("Current stack: {:?}", stack);

        match &opcode.instruction {
            Instruction::Log => {
                if let Some(x) = stack.pop() {
                    locals.push(StringAndValueTuple {
                        field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                        field1: Db::new(&PathBuf::from("")).to_ct_value(&x),
                    });
                } else {
                    let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                    err_value.msg = "Empty stack during evaluation! Please report this!".to_string();
                    locals.push(StringAndValueTuple {
                        field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                        field1: err_value,
                    });
                    return locals;
                }
            }

            Instruction::PushInt(i) => {
                // TODO: what type_id
                stack.push(ValueRecord::Int {
                    i: *i,
                    type_id: NONE_TYPE_ID,
                });
            }

            Instruction::PushFloat(f) => {
                // TODO: what type_id
                stack.push(ValueRecord::Float {
                    f: *f,
                    type_id: NONE_TYPE_ID,
                });
            }

            Instruction::PushBool(b) => {
                // TODO: what type_id
                stack.push(ValueRecord::Bool {
                    b: *b,
                    type_id: NONE_TYPE_ID,
                });
            }

            Instruction::PushString(s) => {
                // TODO: what type_id
                stack.push(ValueRecord::String {
                    text: s.clone(),
                    type_id: NONE_TYPE_ID,
                });
            }

            Instruction::UnaryOperation(op) => {
                if let Some(operand) = stack.pop() {
                    if let Some(op_func) = unary_op_functions.get(op) {
                        match op_func(operand, &eval_error_type) {
                            Ok(val_rec) => stack.push(val_rec),

                            Err(val) => {
                                locals.push(StringAndValueTuple {
                                    field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                                    field1: val,
                                });
                                return locals;
                            }
                        }
                    } else {
                        let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                        err_value.msg = "Unimplemented!".to_string();
                        locals.push(StringAndValueTuple {
                            field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                            field1: err_value,
                        });
                        return locals;
                    }
                } else {
                    let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                    err_value.msg = "Empty stack during evaluation! Please report this!".to_string();
                    locals.push(StringAndValueTuple {
                        field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                        field1: err_value,
                    });
                    return locals;
                }
            }

            Instruction::BinaryOperation(op) => {
                if let Some(op_func) = binary_op_functions.get(op) {
                    if stack.len() < 2 {
                        stack.clear();
                        let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                        err_value.msg = "Empty stack during evaluation! Please report this!".to_string();
                        locals.push(StringAndValueTuple {
                            field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                            field1: err_value,
                        });
                        return locals;
                    } else {
                        // This unwrap is safe because we check the length of the stack
                        #[allow(clippy::unwrap_used)]
                        let op2 = stack.pop().unwrap();

                        // This unwrap is safe because we check the length of the stack
                        #[allow(clippy::unwrap_used)]
                        let op1 = stack.pop().unwrap();

                        match op_func(op1, op2, &eval_error_type) {
                            Ok(val_rec) => stack.push(val_rec),

                            Err(val) => {
                                locals.push(StringAndValueTuple {
                                    field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                                    field1: val,
                                });
                                return locals;
                            }
                        }
                    }
                } else {
                    let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                    err_value.msg = "Unimplemented!".to_string();
                    locals.push(StringAndValueTuple {
                        field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                        field1: err_value,
                    });
                    return locals;
                }
            }

            Instruction::Index => {
                if stack.len() < 2 {
                    let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                    err_value.msg = "Empty stack during evaluation! Please report this!".to_string();
                    locals.push(StringAndValueTuple {
                        field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                        field1: err_value,
                    });
                    return locals;
                } else {
                    // This unwrap is safe because we check the length of the stack
                    #[allow(clippy::unwrap_used)]
                    let index = stack.pop().unwrap();

                    // This unwrap is safe because we check the length of the stack
                    #[allow(clippy::unwrap_used)]
                    let array = stack.pop().unwrap();

                    if let ValueRecord::Sequence {
                        elements,
                        type_id: _,
                        is_slice,
                    } = array
                    {
                        if is_slice {
                            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                            err_value.msg = "Slices not supported currently".to_string();
                            locals.push(StringAndValueTuple {
                                field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                                field1: err_value,
                            });
                            return locals;
                        }

                        if let ValueRecord::Int { i, type_id: _ } = index {
                            if i < 0 || i >= elements.len() as i64 {
                                let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                                err_value.msg = format!("Index {i} out of range 0..{}.", elements.len());

                                locals.push(StringAndValueTuple {
                                    field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                                    field1: err_value,
                                });
                                return locals;
                            } else {
                                stack.push(elements[i as usize].clone());
                            }
                        } else {
                            let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                            err_value.msg = "Trying to index with non-integer value".to_string();

                            locals.push(StringAndValueTuple {
                                field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                                field1: err_value,
                            });
                            return locals;
                        }
                    } else {
                        let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                        err_value.msg = "Trying to index non-sequence value".to_string();

                        locals.push(StringAndValueTuple {
                            field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                            field1: err_value,
                        });
                        return locals;
                    }
                }
            }

            // TODO: what kind of depth limit to put here for RR:
            //   for now we pass `None`
            Instruction::PushVariable(var_name) => match replay.load_value(var_name, None, lang) {
                Ok(x) => stack.push(
                    DbReplay::new(Box::new(Db::new(&PathBuf::from(""))))
                        .to_value_record(x)
                        .clone(),
                ),

                Err(e) => {
                    let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                    err_value.msg = format!("No such symbol in the current context: {:?}", e);

                    locals.push(StringAndValueTuple {
                        field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                        field1: err_value,
                    });
                    return locals;
                }
            },

            Instruction::JumpIfFalse(pc_add) => {
                if let Some(x) = stack.pop() {
                    if let ValueRecord::Bool { b, type_id: _ } = x {
                        if !b {
                            program_counter += pc_add;
                            continue;
                        }
                    } else {
                        let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                        err_value.msg = "Non-boolean value on conditional jump (probably the condition doesn't evaluate to a boolean value)!".to_string();
                        locals.push(StringAndValueTuple {
                            field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                            field1: err_value,
                        });
                        return locals;
                    }
                } else {
                    let mut err_value = Value::new(TypeKind::Error, eval_error_type.clone());
                    err_value.msg = "Empty stack during evaluation! Please report this!".to_string();
                    locals.push(StringAndValueTuple {
                        field0: source[opcode.position.start_byte..opcode.position.end_byte].to_string(),
                        field1: err_value,
                    });
                    return locals;
                }
            }
        }

        info!("After evaluation stack: {:?}", stack);

        program_counter += 1;
    }

    info!("End stack: {:?}", stack);

    locals
}
