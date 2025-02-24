use crate::position::Position;

#[derive(Debug, Clone, PartialEq)]
pub struct Node {
    pub item: NodeItem,
    pub position: Position,
}

#[derive(Debug, Clone, PartialEq)]
pub enum NodeItem {
    Function {
        name: String,
        params: Vec<String>,
        code: Vec<Node>,
    },
    Call {
        function: Box<Node>,
        args: Vec<Node>,
    },
    Assignment {
        target: Box<Node>,
        value: Box<Node>,
        dereferencing: bool,
    },
    Block {
        items: Vec<Node>,
    },
    Name {
        name: String,
    },
    String {
        text: String,
    },
    Vector {
        items: Vec<Node>,
    },
    Index {
        collection: Box<Node>,
        index: Box<Node>,
    },
    BinaryOperation {
        op: String,
        left: Box<Node>,
        right: Box<Node>,
    },
    Loop {
        item_name: String,
        from_expr: Box<Node>,
        to_expr: Box<Node>,
        code: Box<Node>,
    },
    Int {
        i: i64,
    },
    Bool {
        b: bool,
    },
}
