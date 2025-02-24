// use std;
use std::rc::Rc;
use std::sync::Arc;
use std::path::{Path, PathBuf};

struct A {
    int_field: i64,
    string_field: String,
    bool_field: bool,
//    object_field: Option<Box<A>>
}

struct Point<T> {
    x: T,
    y: T,
}

struct Nested {
    int_field: i64,
    string_field: String,
    bool_field: bool,
    object_field: Option<Box<A>>
}

#[derive(Clone)]
enum Node {
  Nil,
  Int(i64),
  Name(String),
  List(Vec<Node>),
  Click { x: i64, y: i64 }
}

#[derive(Debug)]
enum Fruit {
    Apple,
    Banana,
    Orange,
}

struct Program {
    name: String,
    path: String,
    optimize: bool,
    node: Node
}

struct IntContainer {
    i: i64
}

fn function_value(a: i64, b: i64) -> i64 {
    a+b
}

fn internal2(a: u64, b: u64) -> u64 {
    a + b
}

fn internal1(i: u64) {
    println!("{}", internal2(i + 1, 1));
}

fn internal0() {
    let _unused = 0;
    internal1(1);
    let _unused2 = 1;
}

fn run() {
    let i = 0i64;
    let float_value = 2.3;
    let string_value = "a rust string".to_string();
    let boolean = true;
    let tuple_value = (i, float_value, boolean);
    let box_value = Box::new(i);
    let rc_value = Rc::new(i);
    let rc_weak = Rc::downgrade(&rc_value);
    let arc_value = Arc::new(i);
    let arc_weak = Arc::downgrade(&arc_value);
    let object_value = A {
        int_field: 1,
        string_field: "next string".to_string(),
        bool_field: false
    };

    let nested_object = Nested {
        int_field: 5,
        string_field: "string value".to_string(),
        bool_field: true,
        object_field: Some(Box::new(object_value))
    };

    let array_of_ints = [0i64, 1i64, 2i64];
    let vector_of_ints = vec![0i64, 1i64, 2i64];
    let slice_value = &string_value[0..5];
    let vector_slice_value = &vector_of_ints[0..2];
    let path_buf = PathBuf::from("/path/file");
    let path: &Path = &path_buf;
    let int_node = Node::Int(0i64);
    let nil_node = Node::Nil;
    let name_node = Node::Name("list".to_string());
    let list_node = Node::List(vec![name_node, int_node.clone()]);
    let obj_node = Node::Click {x: 5, y: 6};
    let banana = Fruit::Banana;
    let program = Program {
        name: "program".to_string(),
        path: "program.ext".to_string(),
        optimize: false,
        node: int_node
    };

    let fv = function_value(1i64, 2i64);
    let generic_object_with_integer = Point { x: 5, y: 10 };
    let generic_object_with_float = Point { x: 1.0, y: 4.0 };
    let closure_value = |num: i64| -> i64 {
        num + i
    };

    println!("{}\n", i); // marker: AFTER_SIMPLE_VALUES_LINE

    let mut local3 = 0;

    for k in 0..5 {
        let local = k;
        let local2 = k + 1;
        local3 = local2; // marker: END_LOOP_LINE
    }

    println!("{}\n", local3);
}

fn example_flow_1() { // marker: FUNCTION_FLOW_EXAMPLE_1_LINE
    let mut int_value = 0i64;
    let container = IntContainer { i: 1i64 };
    int_value += container.i;
    // for now probably we don't detect `int_value` in `format!("{int_value}")`

    let text_value = format!("{}", int_value);
    println!("{text_value}");
}

fn example_flow_2() { // marker: FUNCTION_FLOW_EXAMPLE_2_LINE
    let mut int_value = 2usize;
    let values = vec![1i64, 2i64];
    for i in 0 .. int_value {
        let b = values[i];
        println!("{b}");
    }

    internal0();
}

fn condition(x: i32) {
    if x > 5 {
        println!("x is greater than 5");
        if x > 7 {
            println!("x is greater than 7");
        } else {
            println!("x is not greater than 7");
        }
    }

    if x < 5 {
        println!("x is less than 5");
    } else {
        println!("x is not less than 5");
    }

    if x < 5 {
        println!("x is less than 5");
    } else if x == 5 {
        println!("x is equal to 5");
    } else {
        println!("x is greater than 5"); // marker: CONDITION_LINE
    }

    let fruits = vec![Fruit::Apple, Fruit::Banana, Fruit::Orange];

    let banana = Fruit::Banana;
    println!("{:?}", banana);

    for fruit in fruits {
        match fruit {
            Fruit::Apple => {
                println!("You have chosen an apple.");
            },
            Fruit::Banana => {
                println!("You have chosen a banana.");
            },
            Fruit::Orange => {
                println!("You have chosen an orange.");
            },
        }
    }
}

fn main() {
    run();
    example_flow_1();
    example_flow_2();
    condition(10);
}
