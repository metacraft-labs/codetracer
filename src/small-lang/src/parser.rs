// extern crate pom;
// use pom::parser::*;
// use pom::Parser;

use std::error::Error;
use std::str::{self};

use crate::node::{Node, NodeItem};
use crate::position::Position;

#[derive(Debug, Clone)]
enum Token {
    LeftParen,
    RightParen,
    Name(String),
    String(String),
    Int(i64),
    Bool(bool),
    NoNewlineWhitespace,
    Newline,
    Unexpected(char),
    EndOfSource,
}

fn read_next_token(source: &str) -> (Token, usize) {
    // eprintln!("read_next_token");
    if source.is_empty() {
        (Token::EndOfSource, 0)
    } else {
        let bytes = source.as_bytes();
        let first = bytes[0];
        // eprintln!("{}", first as char);
        match first as char {
            '(' => (Token::LeftParen, 1),
            ')' => (Token::RightParen, 1),
            ' ' | '\t' => {
                let mut index = 1;
                while index < source.len() {
                    if bytes[index] as char == ' ' || bytes[index] as char == '\t' {
                        index += 1;
                    } else {
                        break;
                    }
                }
                (Token::NoNewlineWhitespace, index)
            }
            '\n' => (Token::Newline, 1),
            'a'..='z' | '#' | '+' | '-' | '*' | '/' => {
                let mut index = 1;
                while index < source.len() {
                    match bytes[index] as char {
                        'a'..='z' | '#' | '+' | '-' | '*' | '/' => {
                            index += 1;
                        }
                        _ => {
                            break;
                        }
                    };
                }
                let name = &source[..index];
                let token = match name {
                    "true" => Token::Bool(true),
                    "false" => Token::Bool(false),
                    _ => Token::Name(name.to_string()),
                };
                (token, index)
            }
            '0'..='9' | '_' => {
                let mut index = 1;
                let mut raw_int = "".to_string();
                raw_int.push(bytes[0] as char);
                while index < source.len() {
                    match bytes[index] as char {
                        '0'..='9' => {
                            raw_int.push(bytes[index] as char);
                            index += 1;
                        }
                        '_' => {
                            // don't push in raw_int, just support
                            // 1_000_000 for example
                            index += 1;
                        }
                        _ => {
                            break;
                        }
                    };
                }
                (Token::Int(raw_int.parse::<i64>().unwrap()), index)
            }
            '"' => {
                let mut index = 1;
                while index < source.len() {
                    if bytes[index] as char != '"' {
                        index += 1;
                    } else {
                        index += 1;
                        break;
                    }
                }
                (Token::String(source[1..index - 1].to_string()), index)
            }
            _ => (Token::Unexpected(first as char), 1),
        }
    }
}

fn parse_node(
    raw: &str,
    position: &Position,
    _depth: usize,
) -> Result<(Node, Position, usize, bool), Box<dyn Error>> {
    let mut source = raw;
    let mut result_position = *position;
    let mut result_node = Node {
        item: NodeItem::Block { items: vec![] },
        position: *position,
    };
    let mut result_finished = false;
    let mut result_read_count = 0;

    let mut items: Vec<Node> = vec![];
    let mut in_list = false;
    let mut _item_index = 0;
    loop {
        let (next_token, mut read_count) = read_next_token(source);
        // eprintln!("{}after source \"{}\" {:?}: {:?} {}",
        //     str::repeat("  ", depth),
        //     source, &result_position, &next_token, read_count);
        match next_token {
            Token::LeftParen => {
                if !in_list {
                    in_list = true;
                    result_position.column += read_count;
                } else {
                    let (node, new_position, parse_read_count, _finished) =
                        parse_node(source, &result_position, _depth + 1)?;
                    // assume _finished is false: we still expect it to end on a right paren
                    read_count = parse_read_count;
                    result_position = new_position;
                    items.push(node);
                    _item_index += 1;
                }
            }
            Token::RightParen => {
                if !in_list {
                    return Err(format!(
                        "error: unexpected ) at {}:{}",
                        result_position.line, result_position.column
                    )
                    .into());
                } else {
                    result_position.column += read_count;
                    result_read_count += read_count;
                    break;
                }
            }
            Token::NoNewlineWhitespace => {
                result_position.column += read_count;
            }
            Token::Newline => {
                result_position.line += 1;
                result_position.column = 1;
            }
            Token::Name(name) => {
                let node = Node {
                    item: NodeItem::Name { name },
                    position: result_position,
                };
                result_position.column += read_count;
                if !in_list {
                    result_node = node;
                    result_read_count += read_count;
                    break;
                } else {
                    items.push(node);
                    _item_index += 1;
                }
            }
            Token::String(text) => {
                let node = Node {
                    item: NodeItem::String { text },
                    position: result_position,
                };
                result_position.column += read_count;
                if !in_list {
                    result_node = node;
                    result_read_count += read_count;
                    break;
                } else {
                    items.push(node);
                    _item_index += 1;
                }
            }
            Token::Int(i) => {
                let node = Node {
                    item: NodeItem::Int { i },
                    position: result_position,
                };
                result_position.column += read_count;
                if !in_list {
                    result_node = node;
                    result_read_count += read_count;
                    break;
                } else {
                    items.push(node);
                    _item_index += 1;
                }
            }
            Token::Bool(b) => {
                let node = Node {
                    item: NodeItem::Bool { b },
                    position: result_position,
                };
                result_position.column += read_count;
                if !in_list {
                    result_node = node;
                    result_read_count += read_count;
                    break;
                } else {
                    items.push(node);
                    _item_index += 1;
                }
            }
            Token::Unexpected(c) => {
                return Err(format!(
                    "error: unexpected token: {} at {}:{}",
                    c, result_position.line, result_position.column
                )
                .into());
            }
            Token::EndOfSource => {
                result_finished = true;
                result_read_count += read_count;
                break;
            }
        };
        result_read_count += read_count;
        source = &source[read_count..];
    }

    if in_list {
        if !items.is_empty() {
            let first = items[0].clone();
            if let NodeItem::Name { name } = first.item {
                match name.as_str() {
                    "set" => {
                        result_node = Node {
                            item: NodeItem::Assignment {
                                target: Box::new(items[1].clone()),
                                value: Box::new(items[2].clone()),
                                dereferencing: false,
                            },
                            position: items[0].position,
                        };
                    }
                    "set-deref" => {
                        result_node = Node {
                            item: NodeItem::Assignment {
                                target: Box::new(items[1].clone()),
                                value: Box::new(items[2].clone()),
                                dereferencing: true,
                            },
                            position: items[0].position,
                        }
                    }
                    "loop" => {
                        if let NodeItem::Name { name: item_name } = items[1].item.clone() {
                            result_node = Node {
                                item: NodeItem::Loop {
                                    item_name,

                                    from_expr: Box::new(items[2].clone()),
                                    to_expr: Box::new(items[3].clone()),
                                    code: Box::new(items[4].clone()),
                                },
                                position: items[0].position,
                            };
                        } else {
                            return Err("error: expected name for loop iterator item"
                                .to_string()
                                .into());
                        }
                    }
                    "vector" => {
                        result_node = Node {
                            item: NodeItem::Vector {
                                items: items[1..].to_vec(),
                            },
                            position: items[0].position,
                        };
                    }
                    "#" => {
                        result_node = Node {
                            item: NodeItem::Index {
                                collection: Box::new(items[1].clone()),
                                index: Box::new(items[2].clone()),
                            },
                            position: *position,
                        }
                    }
                    "+" => {
                        result_node = Node {
                            item: NodeItem::BinaryOperation {
                                op: name.clone(),
                                left: Box::new(items[1].clone()),
                                right: Box::new(items[2].clone()),
                            },
                            position: *position,
                        }
                    }
                    "defun" => {
                        if let NodeItem::Name { name } = &items[1].item {
                            let name_position = &items[1].position;
                            // post-processing simpler for now
                            // very un-lispy, sorry
                            let mut params = vec![];
                            match items[2].item.clone() {
                                NodeItem::Call { function, args, .. } => {
                                    if let NodeItem::Name { name: first_name } = function.item {
                                        params.push(first_name);
                                    } else {
                                        return Err("error: expected name for defun params"
                                            .to_string()
                                            .into());
                                    }
                                    for arg in args {
                                        if let NodeItem::Name { name: arg_name } = arg.item {
                                            params.push(arg_name);
                                        } else {
                                            return Err("error: expected name for defun params"
                                                .to_string()
                                                .into());
                                        }
                                    }
                                }
                                NodeItem::Block { items } => {
                                    if items.is_empty() {
                                        // empty params: ok
                                    } else {
                                        return Err(
                                            "error: expected () or (param1 param2 ..) for defun"
                                                .to_string()
                                                .into(),
                                        );
                                    }
                                }
                                _ => {
                                    return Err(
                                        "error: expected () or (param1 param2 ..) for defun"
                                            .to_string()
                                            .into(),
                                    );
                                }
                            }
                            // eprintln!("{:?}", name_position);
                            result_node = Node {
                                item: NodeItem::Function {
                                    name: name.clone(),
                                    params,
                                    #[allow(clippy::iter_cloned_collect)] // TODO: The suggested fix by clippy doesn't work. Investigate more
                                    code: items[3..].iter().cloned().collect(),
                                },
                                position: *name_position,
                            }
                        } else {
                            return Err("error: expected function name for defun"
                                .to_string()
                                .into());
                        }
                    }
                    _ => {
                        result_node = Node {
                            item: NodeItem::Call {
                                function: Box::new(items[0].clone()),
                                args: items[1..].to_vec(),
                            },
                            position: items[0].position, // items.len() > 0
                        }
                    }
                }
            } else {
                // first is not Node::Name
                let first_position = items[0].position; // items.len() > 0
                result_node = Node {
                    item: NodeItem::Block { items },
                    position: first_position,
                };
            }
        } else {
            // 0 items
            result_node = Node {
                item: NodeItem::Block { items },
                position: *position,
            };
        }
    }
    // eprintln!("node {result_node:?} position {position:?} result position {result_position:?}");

    // eprintln!("{}return : {:?}",
    //     str::repeat("  ", depth),
    //     (&result_node, result_position, result_read_count, result_finished));
    Ok((
        result_node,
        result_position,
        result_read_count,
        result_finished,
    ))
}

//
// (set b (vector))
// (loop item 0 10 (
//   (set b)
pub fn parse_program(raw: &str) -> Result<Node, Box<dyn Error>> {
    let mut items = vec![];
    let mut item;
    let mut position = Position { line: 1, column: 1 };
    let mut finished;
    let mut source = raw;
    let mut read_count;
    loop {
        (item, position, read_count, finished) = parse_node(source, &position, 0)?;
        items.push(item);
        source = &source[read_count..];

        if finished {
            break;
        }
    }
    Ok(Node {
        item: NodeItem::Block { items },
        position: Position { line: 1, column: 1 },
    })
}

// // copied from and adapted from
// // pom lib's tutorial's json parser example:
// // https://github.com/J-F-Liu/pom?tab=readme-ov-file#example-json-parser
// fn space() -> Parser<u8, ()> {
//     one_of(b" \t\r\n").repeat(0..).discard()
// }

// fn int() -> Parser<u8, Node> {
//     let integer = one_of(b"123456789") - one_of(b"0123456789").repeat(0..) | sym(b'0');
//     integer.collect()
//         .convert(str::from_utf8).convert(|s| i64::from_str(&s))
//         .map(|i| Node::Int { i })
// }

// // fn raw_name() -> Parser<u8, String> {
//  //   let raw_name_parse

// fn name() -> Parser<u8, Node> {
//     raw_name().map(|t| Node::Name { name: t.to_string() })
// }

// fn raw_name() -> Parser<u8, String> {
//     let name_parser = one_of(b"abcdefghijklmnopqrstuvwxyz").repeat(1..);
//     name_parser.collect().convert(str::from_utf8).map(|t| t.to_string())
// }

// fn vector() -> Parser<u8, Node> {
//     let items = list(call(expr), sym(b',') * space());
//     let v = sym(b'[') * space() * items - sym(b']');
//     v.map(|items| Node::Vector { items })
// }

// fn call_parser() -> Parser<u8, Node> {
//     let c = name() + sym(b'(') * list(call(expr), sym(b',') * space()) - sym(b')');
//     c.map(|(function, args)| Node::Call { function: Box::new(function), args: args })
// }

// fn loop_parser() -> Parser<u8, Node> {
//     let l = seq(b"loop") * sym(b'(') * raw_name() - sym(b',') * space() + call(expr) - sym(b',') * space() +
//         call(expr) - sym(b')') * space() * sym(b'{') * space() + list(call(expr), sym(b'\n')) - space() * sym(b'}');
//     l.map(|(((item_name, from_expr), to_expr), code)| Node::Loop {
//         item_name: item_name,
//         from_expr: Box::new(from_expr),
//         to_expr: Box::new(to_expr),
//         code: code
//     })
// }

// fn assignment() -> Parser<u8, Node> {
//     (name() - space() * sym(b'=') * space() + call(expr))
//         .map(|(target, right)| Node::Assignment {
//             target: Box::new(target),
//             value: Box::new(right)
//         })
// }

// fn expr() -> Parser<u8, Node> {
//     loop_parser() |
//         call_parser() |
//         assignment() |
//         vector() |
//         name() |
//         int()
// }

// pub fn program() -> Parser<u8, Node> {
//     (space() * list(call(expr), space()) - space())
//         .map(|items| Node::Block { items })
// }
