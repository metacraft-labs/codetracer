fn read_and_evaluate(message: str<5>) -> u8 {
    let tokens = read(message);
    evaluate(tokens)
}

fn read(message: str<5>) -> [u8; 3] {
    let message_bytes = message.as_bytes();
    [message_bytes[0], message_bytes[2], message_bytes[4]]
}

fn evaluate(tokens: [u8; 3]) -> u8 {
    evaluate_binop(tokens[1], tokens[0], tokens[2])
}

fn evaluate_binop(op: u8, left: u8, right: u8) -> u8 {
    let l = evaluate_node(left);
    let r = evaluate_node(right);

    let mut result: u8 = 0;
    if op == "+".as_bytes()[0] {
        result = l + r;
    } else if op == "-".as_bytes()[0] {
        result = l - r;
    } else if op == "*".as_bytes()[0] {
        result = l * r;
    } else if op == "/".as_bytes()[0] {
        result = l / r;
    }
    result
}

fn evaluate_node(node: u8) -> u8 {
    if node == "0".as_bytes()[0] {
    0
  } else if node == "1".as_bytes()[0]  {
    1
  } else if node == "2".as_bytes()[0]  {
    2
  } else if node == "3".as_bytes()[0]  {
    3
  } else if node == "4".as_bytes()[0]  {
    4
  } else if node == "5".as_bytes()[0]  {
    5
  } else if node == "6".as_bytes()[0]  {
    6
  } else if node == "7".as_bytes()[0]  {
    7
  } else if node == "8".as_bytes()[0]  {
    8
  } else /* if node == "9" */ {
    9
  }
}

fn main(message: pub str<5>) {
    let result = read_and_evaluate(message);
    println(result);
}
