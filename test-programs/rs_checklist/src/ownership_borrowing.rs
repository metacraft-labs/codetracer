use crate::ChecklistResult;
use std::cell::RefCell;

#[derive(Clone, Copy, Debug)]
struct Coordinates {
    x: i32,
    y: i32,
}

#[derive(Debug)]
struct Labelled(String);

impl Clone for Labelled {
    fn clone(&self) -> Self {
        Self(self.0.clone())
    }
}

#[derive(Debug)]
struct DropLogger {
    name: &'static str,
}

impl DropLogger {
    fn new(name: &'static str) -> Self {
        println!("[ob-drop] constructing {name}");
        Self { name }
    }
}

impl Drop for DropLogger {
    fn drop(&mut self) {
        println!("[ob-drop] dropping {}", self.name);
    }
}

pub fn run() -> ChecklistResult {
    move_and_copy();
    partial_move_and_borrowing();
    drop_order();
    lifetime_examples();
    raw_references();
    Ok(())
}

fn move_and_copy() {
    let a: i32 = 5;
    let b = a; // Copy
    println!("[ob-01] Copy type move keeps both values a={a} b={b}");

    let greeting = String::from("hello");
    let moved = greeting;
    println!("[ob-02] moved String now lives in moved='{moved}'");

    let labelled = Labelled("clone me".into());
    let cloned = labelled.clone();
    println!("[ob-03] cloned struct original={labelled:?} clone={cloned:?}");

    let coords = Coordinates { x: 1, y: 2 };
    let coords_copy = coords;
    println!(
        "[ob-04] Copy derives coords={coords:?} coords_copy={coords_copy:?} sum={}",
        coords.x + coords.y
    );

    let capture = String::from("captured");
    let consume_once = move || capture.len(); // FnOnce, takes ownership
    println!("[ob-05] closure consumed length={}", consume_once());

    let mut value = 0;
    {
        let mut borrow = |delta: i32| {
            value += delta;
            value
        };
        println!("[ob-06] FnMut borrow {}", borrow(3));
    }
    println!("[ob-07] value after FnMut borrow {value}");
}

fn partial_move_and_borrowing() {
    #[derive(Debug)]
    struct Partial {
        head: String,
        tail: String,
    }

    let partial = Partial {
        head: "first".into(),
        tail: "second".into(),
    };
    let Partial {
        head,
        tail: remaining_tail,
    } = partial;
    println!("[ob-08] moved head='{head}', kept tail='{remaining_tail}'");

    let numbers = vec![1, 2, 3];
    let first = &numbers[0];
    let second = &numbers[1];
    println!("[ob-09] shared borrows first={first} second={second}");

    let mut shared = String::from("mutable");
    {
        let r1 = &mut shared;
        r1.push_str(" borrow");
    } // r1 ends here
    {
        let r2 = &mut shared;
        r2.push_str(" again");
    }
    println!("[ob-10] non-lexical lifetimes allow sequential mut borrows -> {shared}");

    let mut value = 10;
    let mut_ref: &mut i32 = &mut value;
    *mut_ref += 1;
    let reborrow: &i32 = &*mut_ref;
    println!("[ob-11] reborrowed shared view {}", reborrow);

    let mut vec = vec![10, 20, 30, 40];
    let slice: &mut [i32] = &mut vec[1..3];
    slice[0] = 25;
    println!("[ob-12] slice mutation vec={vec:?}");

    let owned = String::from("borrowed");
    let as_str: &str = owned.as_str();
    let to_owned = as_str.to_string();
    println!("[ob-13] String/&str conversions as_str='{as_str}' new='{to_owned}'");
}

fn drop_order() {
    let _a = DropLogger::new("local-a");
    {
        let _b = DropLogger::new("inner-b");
        let _c = DropLogger::new("inner-c");
        println!("[ob-14] leaving inner scope triggers c then b");
    }

    let _tail_expr = tail_expression_drop();

    println!("[ob-15] end of function will now drop tail_expr then local-a (2024 drop order)");
}

fn tail_expression_drop() -> DropLogger {
    let _guard = DropLogger::new("guard");
    DropLogger::new("tail-expression")
}

fn lifetime_examples() {
    fn pick_first<'a, 'b>(a: &'a str, b: &'b str) -> &'a str {
        let _ = b;
        a
    }

    fn longest<'a>(a: &'a str, b: &'a str) -> &'a str {
        if a.len() >= b.len() { a } else { b }
    }

    fn higher_ranked<F>(f: F)
    where
        F: for<'a> Fn(&'a str) -> usize,
    {
        let len = f("higher-ranked");
        println!("[ob-16] higher-ranked len {len}");
    }

    let one = String::from("short");
    let two = String::from("a much longer string");
    let winner = longest(one.as_str(), two.as_str());
    println!("[ob-17] longest result '{winner}'");
    println!("[ob-18] pick_first {}", pick_first("a", "b"));

    higher_ranked(|s| s.len());

    let static_ref: &'static str = "I live forever";
    println!("[ob-19] 'static literal -> {static_ref}");

    let borrowed = RefCell::new(String::from("runtime borrow"));
    {
        let mut borrow = borrowed.borrow_mut();
        borrow.push_str(" ok");
    }
    println!("[ob-20] RefCell after borrow {:?}", borrowed.borrow());
}

fn raw_references() {
    let num = 41;
    let const_ptr = &raw const num;
    let mut mutable = 10;
    let mut_ptr = &raw mut mutable;

    unsafe {
        println!("[ob-21] raw const *const i32 -> {}", *const_ptr);
        *mut_ptr += 1;
        println!("[ob-22] raw mut *mut i32 -> {}", *mut_ptr);
    }
}
