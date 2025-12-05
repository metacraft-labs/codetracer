use crate::ChecklistResult;

pub fn run() -> ChecklistResult {
    pattern_matching();
    let_else_demo();
    if_while_let_control();
    loop_control();
    diverging_match();
    Ok(())
}

#[derive(Debug)]
struct Point {
    x: i32,
    y: i32,
}

#[non_exhaustive]
#[derive(Debug)]
enum External {
    Alpha,
    Beta,
}

fn pattern_matching() {
    let p = Point { x: 3, y: -1 };
    match p {
        Point { x: 0, y } => println!("[pc-01] on y-axis y={y}"),
        Point { x, y: 0 } => println!("[pc-02] on x-axis x={x}"),
        Point { x, y } if x == y => println!("[pc-03] diagonal x=y={x}"),
        Point { x, y } => println!("[pc-04] general point {x},{y}"),
    }

    let mut tuple = (1, 2, 3);
    let (ref a, ref mut b, _) = tuple;
    println!("[pc-05] ref binding a={a} ref mut b={b}");

    let data = [10, 20, 30, 40, 50];
    match data.as_slice() {
        [first, middle @ .., last] => {
            println!("[pc-06] slice first={first} last={last} middle={middle:?}");
        }
        _ => println!("[pc-06b] slice fallback branch"),
    }

    let opt = Some(0);
    match opt {
        Some(0 | 1) => println!("[pc-07] matched or-pattern Some(0|1)"),
        Some(v @ 2..=5) => println!("[pc-08] range pattern with @ binding {v}"),
        Some(other) if other > 5 => println!("[pc-09] guard matched {other}"),
        _ => println!("[pc-10] wildcard fallback"),
    }

    let ext = External::Alpha;
    match ext {
        External::Alpha => println!("[pc-11] matched non-exhaustive Alpha"),
        _ => println!("[pc-11b] wildcard branch for future variants"),
    }

    let beta = External::Beta;
    match beta {
        External::Alpha => println!("[pc-11c] unexpected Alpha"),
        _ => println!("[pc-11c] matched Beta via wildcard"),
    }
}

fn let_else_demo() {
    fn parse_pair(input: &str) -> Result<(i32, i32), String> {
        let Some((left, right)) = input.split_once(',') else {
            return Err("missing comma".into());
        };

        let Ok(a) = left.trim().parse::<i32>() else {
            return Err("bad left number".into());
        };
        let Ok(b) = right.trim().parse::<i32>() else {
            return Err("bad right number".into());
        };
        Ok((a, b))
    }

    match parse_pair("3, 4") {
        Ok((a, b)) => println!("[pc-12] let-else parsed {a}+{b}={}", a + b),
        Err(e) => println!("[pc-13] parse error {e}"),
    }
}

fn if_while_let_control() {
    let left = Some(2);
    let right = Some(4);

    if let Some(a) = left
        && let Some(b) = right
        && a + b > 0
    {
        println!("[pc-14] if-let chain matched a={a} b={b}");
    }

    let mut iter = [Some(1), None, Some(3)].into_iter();
    let mut seen = Vec::new();
    while let Some(Some(v)) = iter.next() {
        seen.push(v);
    }
    println!("[pc-15] while-let collected {:?}", seen);
}

fn loop_control() {
    let val = loop {
        break 42;
    };
    println!("[pc-16] loop break with value {val}");

    'outer: for i in 0..3 {
        for j in 0..3 {
            if i == 1 && j == 1 {
                continue 'outer;
            }
            if i == 2 {
                println!("[pc-17] breaking outer at i={i} j={j}");
                break 'outer;
            }
        }
    }
}

fn diverging_match() {
    let input = 2;
    fn never() -> ! {
        panic!("diverging branch");
    }

    let doubled = match input {
        0 => never(),
        1 => {
            println!("[pc-18] early return branch");
            return;
        }
        _ => input * 2,
    };

    println!("[pc-19] diverging match result {doubled}");
}
