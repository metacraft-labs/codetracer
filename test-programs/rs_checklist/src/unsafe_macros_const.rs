use crate::ChecklistResult;
use crate::macros_support::AutoHello;
use rs_checklist_macros::AutoHello as DeriveAutoHello;
use std::any::{Any, TypeId, type_name};
use std::mem::{self, MaybeUninit, align_of, size_of};
use std::ptr::NonNull;

pub fn run() -> ChecklistResult {
    unsafe_primitives();
    ffi_and_repr();
    macros_and_attrs();
    const_eval_and_layout();
    modules_and_visibility();
    runtime_type_info();
    Ok(())
}

fn unsafe_primitives() {
    let mut data = [MaybeUninit::<u32>::uninit(); 3];
    for (idx, slot) in data.iter_mut().enumerate() {
        slot.write((idx as u32) + 1);
    }
    let init: [u32; 3] = unsafe { std::mem::transmute(data) };
    println!("[um-01] MaybeUninit array initialized {:?}", init);

    let source: [u8; 4] = [0, 1, 2, 3];
    let raw_ptr = source.as_ptr();
    unsafe {
        let slice = std::slice::from_raw_parts(raw_ptr.add(1), 2);
        println!("[um-02] raw slice {:?}", slice);
    }

    #[repr(C)]
    struct Wrapper(u32);
    let wrapped = Wrapper(42);
    let plain: u32 = unsafe { mem::transmute(wrapped) };
    println!("[um-03] transmute wrapper -> {plain}");

    union IntOrFloat {
        int: u32,
        float: f32,
    }
    let mixed = IntOrFloat { int: 0x40400000 };
    unsafe {
        println!("[um-04] union int={} float={}", mixed.int, mixed.float);
    }
}

#[repr(C)]
pub struct CPoint {
    pub x: i32,
    pub y: i32,
}

#[unsafe(no_mangle)]
pub extern "C" fn add_point(point: CPoint) -> i32 {
    point.x + point.y
}

unsafe extern "C" {
    fn abs(input: i32) -> i32;
}

#[unsafe(no_mangle)]
pub extern "C" fn foreign_add_one(input: i32) -> i32 {
    input + 1
}

fn ffi_and_repr() {
    let point = CPoint { x: 3, y: 4 };
    let sum = foreign_add_one(add_point(point));
    let libc_abs = unsafe { abs(-sum) };
    println!("[um-05] extern calls result {sum} libc_abs={libc_abs}");

    #[repr(u8)]
    enum Small {
        A = 1,
        B = 2,
    }
    println!(
        "[um-06] repr(u8) enum size {} align {}",
        size_of::<Small>(),
        align_of::<Small>()
    );

    let small = Small::A;
    let other = Small::B;
    println!(
        "[um-06b] repr(u8) variant discriminant {} other={}",
        small as u8, other as u8
    );
}

macro_rules! scoped_log {
    ($name:expr, $body:block) => {{
        println!("[um-07] entering {}", $name);
        let result = { $body };
        println!("[um-07] leaving {}", $name);
        result
    }};
}

#[derive(Debug, DeriveAutoHello)]
struct MacroDriven {
    id: u32,
}

fn macros_and_attrs() {
    let m = MacroDriven { id: 10 };
    println!("[um-08] derive macro -> {} (id={})", m.hello(), m.id);

    let cfg_enabled = cfg!(target_pointer_width = "64");
    println!("[um-09] cfg!(feature) -> {cfg_enabled}");

    scoped_log!("macro_rules block", {
        let sum: i32 = (1..=3).sum();
        println!("[um-10] sum computed inside macro {sum}");
    });
}

const fn const_fib(n: u32) -> u32 {
    match n {
        0 => 0,
        1 => 1,
        _ => const_fib(n - 1) + const_fib(n - 2),
    }
}

const CONST_BLOCK: u32 = const { 1 + 2 + const_fib(5) };

fn const_eval_and_layout() {
    const TABLE: [u32; 3] = [CONST_BLOCK, const_fib(3), 99];
    println!("[um-11] const block/table {:?}", TABLE);

    println!(
        "[um-12] size_of Option<NonNull<u8>>={} align_of CPoint={}",
        size_of::<Option<NonNull<u8>>>(),
        align_of::<CPoint>()
    );
}

fn modules_and_visibility() {
    println!(
        "[um-16] visibility public call {}",
        visibility::call_inner()
    );
    println!("[um-17] visibility restricted {}", visibility::outer_only());
}

mod visibility {
    pub(crate) mod inner {
        pub(super) fn expose() -> &'static str {
            "pub(super) from inner"
        }

        pub(in crate::unsafe_macros_const::visibility) fn hidden() -> &'static str {
            "pub(in path) value"
        }
    }

    pub fn call_inner() -> &'static str {
        inner::expose()
    }

    pub(crate) fn outer_only() -> &'static str {
        inner::hidden()
    }
}

fn runtime_type_info() {
    let values: Vec<Box<dyn Any>> = vec![Box::new(5i32), Box::new(String::from("hello"))];
    for value in values.iter() {
        if let Some(int) = value.downcast_ref::<i32>() {
            println!("[um-13] downcast int {}", int);
        } else if let Some(text) = value.downcast_ref::<String>() {
            println!("[um-14] downcast string {}", text);
        }
    }

    println!(
        "[um-15] type ids i32 == i64? {} type_name MacroDriven={}",
        TypeId::of::<i32>() == TypeId::of::<i64>(),
        type_name::<MacroDriven>()
    );
}
