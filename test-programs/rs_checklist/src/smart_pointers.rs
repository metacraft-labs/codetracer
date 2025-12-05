use crate::ChecklistResult;
use std::borrow::Cow;
use std::cell::{Cell, RefCell};
use std::num::{NonZeroU8, NonZeroUsize};
use std::panic::AssertUnwindSafe;
use std::pin::Pin;
use std::ptr::NonNull;
use std::rc::{Rc, Weak};
use std::sync::{Arc, Mutex};

pub fn run() -> ChecklistResult {
    box_and_raw();
    rc_cycle();
    interior_mutability();
    cow_demo();
    pinning_demo();
    non_zero_and_non_null();
    Ok(())
}

fn box_and_raw() {
    let boxed = Box::new(5);
    let leaked: &'static i32 = Box::leak(boxed);
    println!("[sp-01] leaked box value {leaked}");

    let raw = Box::into_raw(Box::new(String::from("raw ptr")));
    unsafe {
        let boxed_again = Box::from_raw(raw);
        println!("[sp-02] round-trip raw pointer {}", boxed_again);
    }
}

fn rc_cycle() {
    #[derive(Debug)]
    struct Node {
        value: i32,
        next: RefCell<Option<Rc<Node>>>,
    }

    let first = Rc::new(Node {
        value: 1,
        next: RefCell::new(None),
    });
    let second = Rc::new(Node {
        value: 2,
        next: RefCell::new(None),
    });
    *first.next.borrow_mut() = Some(Rc::clone(&second));
    *second.next.borrow_mut() = Some(Rc::clone(&first)); // cycle

    println!(
        "[sp-03b] node values first={} second={}",
        first.value, second.value
    );
    println!(
        "[sp-03] rc counts first strong={} weak={} second strong={} weak={}",
        Rc::strong_count(&first),
        Rc::weak_count(&first),
        Rc::strong_count(&second),
        Rc::weak_count(&second)
    );

    let weak: Weak<Node> = Rc::downgrade(&first);
    println!("[sp-04] weak upgrade is_some={}", weak.upgrade().is_some());
}

fn interior_mutability() {
    let cell = Cell::new(1);
    cell.set(cell.get() + 1);
    println!("[sp-05] Cell value {}", cell.get());

    let refcell = RefCell::new(vec![1, 2, 3]);
    {
        let mut borrow = refcell.borrow_mut();
        borrow.push(4);
    }

    let bad_borrow = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let _first = refcell.borrow();
        let _second = refcell.borrow_mut(); // will panic
    }));
    println!(
        "[sp-06] RefCell borrow_mut panic caught? {}",
        bad_borrow.is_err()
    );

    let shared_vec = Arc::new(Mutex::new(vec![1, 2]));
    let cloned = Arc::clone(&shared_vec);
    let handle = std::thread::spawn(move || {
        cloned.lock().unwrap().push(3);
    });
    handle.join().unwrap();
    println!("[sp-07] Arc<Mutex> {:?}", shared_vec.lock().unwrap());
}

fn cow_demo() {
    let borrowed: Cow<'static, str> = Cow::Borrowed("static str");
    let mut owned: Cow<'static, str> = Cow::Owned(String::from("owned"));
    owned.to_mut().push_str(" updated");
    println!("[sp-08] Cow borrowed={borrowed} owned={owned}");
}

#[derive(Debug)]
struct SelfReferential {
    name: String,
    self_ptr: NonNull<String>,
    _pin: std::marker::PhantomPinned,
}

impl SelfReferential {
    fn new(name: &str) -> Pin<Box<Self>> {
        let mut boxed = Box::pin(Self {
            name: name.into(),
            self_ptr: NonNull::dangling(),
            _pin: std::marker::PhantomPinned,
        });

        let ptr = NonNull::from(&boxed.name);
        // SAFETY: we never move `boxed` after pinning, so the pointer stays valid.
        unsafe {
            let mut_ref = Pin::as_mut(&mut boxed);
            Pin::get_unchecked_mut(mut_ref).self_ptr = ptr;
        }
        boxed
    }

    fn name_ptr_equals(&self) -> bool {
        NonNull::from(&self.name) == self.self_ptr
    }
}

fn pinning_demo() {
    let pinned = SelfReferential::new("pinned");
    println!(
        "[sp-09] self-referential pointer stable? {}",
        pinned.name_ptr_equals()
    );
}

fn non_zero_and_non_null() {
    let non_zero = NonZeroU8::new(5);
    let mut value = 10;
    let non_null = NonNull::new(&mut value as *mut i32);
    let option_nz: Option<NonZeroUsize> = Some(NonZeroUsize::new(1).unwrap());
    println!(
        "[sp-10] NonZero {:?} Option<NonZero> {:?}",
        non_zero, option_nz
    );
    if let Some(ptr) = non_null {
        unsafe {
            *ptr.as_ptr() += 1;
            println!("[sp-11] NonNull pointer points to {}", *ptr.as_ptr());
        }
    }
}
