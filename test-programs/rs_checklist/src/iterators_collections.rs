use crate::ChecklistResult;
use std::collections::{BTreeMap, BTreeSet, BinaryHeap, HashMap, HashSet, LinkedList, VecDeque};
use std::fmt;

pub fn run() -> ChecklistResult {
    literals_and_structs();
    operators_and_conversions();
    closures_and_iterators();
    collections_demo();
    strings_and_formatting();
    Ok(())
}

#[derive(Debug, Clone, Copy)]
struct Point {
    x: i32,
    y: i32,
}

#[derive(Debug)]
struct TupleStruct(u8, bool);

#[derive(Debug, Copy, Clone)]
struct UnitStruct;

#[derive(Debug, Clone)]
struct NewType(String);

#[derive(Debug, Clone, Copy)]
struct Vec2 {
    x: i32,
    y: i32,
}

impl std::ops::Add for Vec2 {
    type Output = Self;

    fn add(self, rhs: Self) -> Self::Output {
        Self {
            x: self.x + rhs.x,
            y: self.y + rhs.y,
        }
    }
}

impl std::ops::AddAssign for Vec2 {
    fn add_assign(&mut self, rhs: Self) {
        self.x += rhs.x;
        self.y += rhs.y;
    }
}

impl fmt::Display for Vec2 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "({}, {})", self.x, self.y)
    }
}

fn literals_and_structs() {
    let dec = 98_222;
    let hex = 0xff;
    let oct = 0o77;
    let bin = 0b1111_0000;
    let byte = b'A';
    let suffixed: i64 = 42i64;
    let float = 1.5f32;
    let wrapped = u8::MAX.wrapping_add(1);
    let checked = u8::MAX.checked_add(1);
    println!(
        "[ic-01] literals dec={dec} hex={hex} oct={oct} bin={bin} byte={byte} suffixed={suffixed} float={float} wrap={wrapped} checked={checked:?}"
    );

    let crab = '\u{1F980}';
    let escaped = b"\x52\x75\x73\x74";
    let raw = r"C:\programs\rust";
    let raw_bytes = br"\xFF literal";
    println!(
        "[ic-02] chars and strings crab={crab} escaped_bytes={escaped:?} raw={raw} raw_bytes={raw_bytes:?}"
    );

    let arr = [1, 2, 3, 4];
    let slice = &arr[1..3];
    let tuple = ("tuple", 9u8, true);
    let updated_point = Point {
        x: 8,
        ..Point { x: 1, y: 2 }
    };
    let newtype = NewType("wrapped".to_string());
    let unit = UnitStruct;
    let tuple_struct = TupleStruct(5, false);
    let inferred = 0; // used as usize below
    let zs = [UnitStruct; 3];
    let open_range = inferred..;
    let inclusive = 1..=3;
    let tail = ..5;

    println!(
        "[ic-03] slices {:?}, tuple={:?}, struct update={:?} (x={} y={}), newtype_inner={}, unit={:?}, tuple_struct=({}, {})",
        slice,
        tuple,
        updated_point,
        updated_point.x,
        updated_point.y,
        newtype.0,
        unit,
        tuple_struct.0,
        tuple_struct.1
    );
    println!(
        "[ic-04] ranges open={:?} inclusive={:?} tail={:?} zero-sized count={}",
        open_range,
        inclusive,
        tail,
        zs.len()
    );
}

fn operators_and_conversions() {
    let mut v1 = Vec2 { x: 1, y: 2 };
    let v2 = Vec2 { x: 3, y: 4 };
    let sum = v1 + v2;
    v1 += Vec2 { x: -1, y: 1 };
    println!("[ic-05] Vec2 sum={sum} after add_assign v1={v1}");

    let s = String::from("coercion");
    let str_ref: &str = &s; // &String -> &str
    let array = [10u8, 11, 12];
    let slice: &[u8] = &array; // &[T; N] -> &[T]

    let as_cast = 255u8 as i16;
    let try_from_ok = u8::try_from(120i16);
    let try_from_err = u8::try_from(300i16);

    println!(
        "[ic-06] coercions str_ref={} slice={:?} cast={} try_from_ok={:?} err={:?}",
        str_ref, slice, as_cast, try_from_ok, try_from_err
    );
}

fn closures_and_iterators() {
    let add = |a: i32, b: i32| a + b; // non-capturing -> fn pointer coercion
    let add_fn: fn(i32, i32) -> i32 = add;
    let mut capture = 0;
    let mut add_mut = |delta: i32| {
        capture += delta;
        capture
    };
    let consume = move |v: Vec<i32>| -> usize { v.len() }; // FnOnce

    println!(
        "[ic-07] add_fn(2,3)={} add_mut(2)->{}",
        add_fn(2, 3),
        add_mut(2)
    );
    println!("[ic-08] consume(Vec) length {}", consume(vec![1, 2, 3]));

    let data = vec![1, 2, 3, 4, 5, 6];
    let evens: Vec<_> = data
        .iter()
        .enumerate()
        .filter(|(idx, _)| idx % 2 == 0)
        .map(|(_, v)| v * 2)
        .collect();
    println!("[ic-09] iterator pipeline => {:?}", evens);

    let mut countdown = Countdown::new(3);
    while let Some(n) = countdown.next() {
        println!("[ic-10] countdown tick {n}");
    }

    let custom_into = Bag {
        inner: vec!["a", "b"],
    };
    for item in custom_into {
        println!("[ic-11] into_iter Bag item={item}");
    }

    let try_fold_sum: Result<i32, &'static str> =
        data.iter().try_fold(
            0,
            |acc, v| if *v < 6 { Ok(acc + v) } else { Err("too big") },
        );
    println!("[ic-12] try_fold result={try_fold_sum:?}");
}

fn collections_demo() {
    let mut nums = vec![1, 2, 3];
    nums.push(4);
    let popped = nums.pop();
    nums.insert(1, 99);
    let removed = nums.remove(2);
    let drained: Vec<_> = nums.drain(0..1).collect();
    nums.splice(0..0, [7, 8]);
    let split = nums.split_off(1);
    println!(
        "[ic-13] vec ops popped={popped:?} removed={removed} drained={drained:?} nums={nums:?} split={split:?}"
    );

    let mut deque: VecDeque<i32> = VecDeque::from([1, 2, 3]);
    deque.push_front(0);
    deque.push_back(4);
    let front = deque.pop_front();
    let back = deque.pop_back();
    println!("[ic-14] deque {:?} front={front:?} back={back:?}", deque);

    let mut list: LinkedList<&str> = LinkedList::new();
    list.push_back("first");
    list.push_back("second");
    println!("[ic-15] linked list {:?}", list);

    let mut map: HashMap<String, Vec<i32>> = HashMap::new();
    map.entry("primes".into()).or_default().extend([2, 3, 5]);
    let mut ordered = BTreeMap::new();
    ordered.insert("b", 2);
    ordered.insert("a", 1);
    println!(
        "[ic-16] hashmap {:?} ordered keys {:?}",
        map,
        ordered.keys().collect::<Vec<_>>()
    );

    let set: HashSet<_> = map.keys().cloned().collect();
    let bset: BTreeSet<_> = ordered.keys().copied().collect();
    println!("[ic-17] hashset={set:?} btreeset={bset:?}");

    let mut heap = BinaryHeap::from([5, 1, 9]);
    heap.push(7);
    let top = heap.peek().copied();
    let popped = heap.pop();
    println!("[ic-18] binary heap peek={top:?} pop={popped:?}");
}

fn strings_and_formatting() {
    #[derive(Debug)]
    struct Printable<'a> {
        name: &'a str,
        value: i32,
    }

    impl fmt::Display for Printable<'_> {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(f, "{} => {}", self.name, self.value)
        }
    }

    let text = String::from("na\u{00EF}ve caf\u{00E9}"); // utf-8 with accents
    let prefix = &text[..4]; // valid boundary
    let chars: Vec<_> = text.chars().collect();
    let bytes: Vec<_> = text.bytes().collect();

    let p = Printable {
        name: "demo",
        value: 42,
    };
    println!("[ic-19] display={p} debug={p:?}");
    println!("[ic-20] formatting hex={:#x} padded={:>8.2}", 255, 3.14159);
    println!("[ic-21] utf8 prefix='{prefix}' chars={chars:?} bytes={bytes:?}");
}

struct Countdown {
    n: u8,
}

impl Countdown {
    fn new(n: u8) -> Self {
        Self { n }
    }
}

impl Iterator for Countdown {
    type Item = u8;

    fn next(&mut self) -> Option<Self::Item> {
        if self.n == 0 {
            None
        } else {
            self.n -= 1;
            Some(self.n + 1)
        }
    }
}

struct Bag<T> {
    inner: Vec<T>,
}

impl<T> IntoIterator for Bag<T> {
    type Item = T;
    type IntoIter = std::vec::IntoIter<T>;

    fn into_iter(self) -> Self::IntoIter {
        self.inner.into_iter()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn countdown_decrements() {
        let mut c = Countdown::new(2);
        assert_eq!(c.next(), Some(2));
        assert_eq!(c.next(), Some(1));
        assert_eq!(c.next(), None);
    }
}
