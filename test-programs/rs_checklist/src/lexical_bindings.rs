use crate::ChecklistResult;
use std::cell::Cell;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicUsize, Ordering};

pub const GRID_SIZE: usize = 4;
pub static GLOBAL_CACHE: OnceLock<Vec<&'static str>> = OnceLock::new();
pub static GLOBAL_COUNTER: AtomicUsize = AtomicUsize::new(0);
pub static mut UNSAFE_OFFSET: i32 = 0;

thread_local! {
    static TLS_TAG: Cell<u32> = Cell::new(10);
}

pub fn run() -> ChecklistResult {
    shadowing_and_mutation();
    consts_and_statics();
    raw_identifiers();
    name_resolution();
    Ok(())
}

fn shadowing_and_mutation() {
    let binding = 1;
    let binding = binding + 1; // shadow to a new immutable binding
    let mut accumulator = 3;
    accumulator += 2;

    {
        let binding = "inner";
        println!("[lex-01] inner binding = {binding}");
    }

    let (x, y, _) = (1, 2, 3);
    let [first, .., last] = [10, 11, 12, 13];
    println!(
        "[lex-02] binding={binding}, accumulator={accumulator}, tuple=({x},{y}), array endpoints={first}->{last}"
    );
}

fn consts_and_statics() {
    println!("[lex-03] const GRID_SIZE = {GRID_SIZE}");

    let cached = GLOBAL_CACHE.get_or_init(|| vec!["alpha", "beta"]);
    println!("[lex-04] OnceLock cache length {}", cached.len());

    let prev = GLOBAL_COUNTER.fetch_add(1, Ordering::SeqCst);
    println!(
        "[lex-05] GLOBAL_COUNTER went from {prev} to {}",
        GLOBAL_COUNTER.load(Ordering::SeqCst)
    );

    TLS_TAG.with(|cell| {
        let before = cell.get();
        cell.set(before + 1);
        println!("[lex-06] thread-local TLS_TAG {before} -> {}", cell.get());
    });

    unsafe {
        UNSAFE_OFFSET += 1;
        let current = UNSAFE_OFFSET;
        println!("[lex-07] static mut UNSAFE_OFFSET = {current}");
    }
}

fn raw_identifiers() {
    let r#match = 7;
    let r#struct = 3;
    let keyword_sum = r#match + r#struct;
    let try_kw = keyword_sum as i32; // reserved keyword used via raw identifier
    println!(
        "[lex-08] raw identifiers sum r#match + r#struct = {keyword_sum}, stored in r#try={try_kw}"
    );
    let r#abstract = 1;
    let override_kw = r#abstract + 2;
    println!("[lex-09] raw future keywords abstract/override => {override_kw}");
}

fn name_resolution() {
    use names::Widget;
    use names::widget as widget_fn;

    let widget = Widget { value: 9 };
    let local_widget = "local binding";
    println!(
        "[lex-10] struct field {}, module fn {}, free fn {}, local {local_widget}",
        widget.value(),
        names::widget_module::call(),
        widget_fn()
    );
}

mod names {
    pub fn widget() -> &'static str {
        "shadowed by local binding"
    }

    pub mod widget_module {
        pub fn call() -> &'static str {
            "names::widget_module::call"
        }
    }

    pub struct Widget {
        pub value: u8,
    }

    impl Widget {
        pub fn value(&self) -> u8 {
            self.value
        }
    }
}
