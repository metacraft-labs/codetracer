// Simple Rust program for flow/omniscience integration testing
// This program tests that local variables inside functions can be loaded.

// ---------------------------------------------------------------------------
// Pillar B: cooperative fixed-base deterministic global allocator (macOS).
//
// Validates MCR-macOS-Replay-Symmetry-Options.md §5.3 ("Pillar B — cooperative
// allocator pinning").  codetracer controls this test program, so it is
// legitimate to give it a global allocator whose heap layout is *identical* at
// record and replay regardless of recorder perturbation.
//
// The default macOS allocator (libmalloc) chooses its arena base in a feedback
// loop with the recorder's M-RLP-4 fixed-VA mmap reservation, so the program's
// heap drifts ~0x4000 between record and replay and the layout-sensitive Rust
// runtime forks its control flow.  This allocator removes that loop: on first
// use it mmaps a single arena at a *fixed* high VA (MAP_FIXED) and bump-
// allocates from it.  Same sequence of (size, align) requests -> same addresses,
// every run, in any process-memory weather.
//
// Gated behind `--cfg mcr_pinned_alloc`, which the db-backend MCR flow-test
// harness passes only on the MCR `ct-native-replay build` path.  The RR-based
// tests (rust_flow_integration, real_recording_integration) build the same
// source without the cfg and keep the system allocator.
#[cfg(mcr_pinned_alloc)]
mod pinned_alloc {
    use std::alloc::{GlobalAlloc, Layout};
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    // Fixed arena base.  On macOS arm64 the kernel rejects `mmap(MAP_FIXED)`
    // (EACCES) below the dyld shared cache and SIGKILLs the process for FIXED
    // mappings in the reserved commpage/kernel band [~0x300000000,0x700000000).
    // Host-probed: FIXED mmap is honored cleanly from 0x7_0000_0000 (28 GiB)
    // upward.  We pick 0x7_0000_0000 — above:
    //   * __PAGEZERO and the program image / stack (all < ~6 GiB),
    //   * the dyld shared cache region [0x180000000, 0x300000000),
    //   * the kernel-reserved band that SIGKILLs FIXED mappings (< 0x700000000),
    // and clear of the recorder's M-RLP fixed-VA reservations (TiB band, e.g.
    // buffers @ 96/104 TiB) and the 0x6000_*/0x8000_*/0x9000_* recorder bands.
    // MAP_FIXED guarantees the arena lands at EXACTLY this VA every run, so the
    // program's heap layout is identical at record and replay.
    const ARENA_BASE: usize = 0xa_0000_0000;
    // 256 MiB arena — far more than this tiny program needs; bump-only/leaking
    // is fine for a short-lived test program.
    const ARENA_SIZE: usize = 256 * 1024 * 1024;

    const PROT_READ: i32 = 0x1;
    const PROT_WRITE: i32 = 0x2;
    const MAP_PRIVATE: i32 = 0x0002;
    const MAP_ANON: i32 = 0x1000;
    const MAP_FIXED: i32 = 0x0010;

    extern "C" {
        fn mmap(
            addr: *mut std::ffi::c_void,
            len: usize,
            prot: i32,
            flags: i32,
            fd: i32,
            offset: i64,
        ) -> *mut std::ffi::c_void;
        fn abort() -> !;
    }

    pub struct PinnedBumpAlloc {
        // Next free offset within the arena (relative to ARENA_BASE).
        offset: AtomicUsize,
        // Whether the arena has been mapped yet.
        ready: AtomicBool,
        // Spin guard for the one-time mmap.
        mapping: AtomicBool,
    }

    impl PinnedBumpAlloc {
        pub const fn new() -> Self {
            PinnedBumpAlloc {
                offset: AtomicUsize::new(0),
                ready: AtomicBool::new(false),
                mapping: AtomicBool::new(false),
            }
        }

        #[inline]
        fn ensure_arena(&self) {
            if self.ready.load(Ordering::Acquire) {
                return;
            }
            // First thread to flip `mapping` performs the mmap; others spin
            // until `ready`.  Deterministic: the arena always lands at exactly
            // ARENA_BASE (MAP_FIXED), so its base is independent of recorder
            // state, prior mmaps, ASLR (disabled anyway), etc.
            if self
                .mapping
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                let p = unsafe {
                    mmap(
                        ARENA_BASE as *mut std::ffi::c_void,
                        ARENA_SIZE,
                        PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANON | MAP_FIXED,
                        -1,
                        0,
                    )
                };
                if p as usize != ARENA_BASE {
                    // MAP_FIXED landed elsewhere / failed — the determinism
                    // contract is broken, so fail loudly rather than silently
                    // corrupt the layout.
                    unsafe { abort() };
                }
                self.ready.store(true, Ordering::Release);
            } else {
                while !self.ready.load(Ordering::Acquire) {
                    std::hint::spin_loop();
                }
            }
        }
    }

    unsafe impl GlobalAlloc for PinnedBumpAlloc {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            self.ensure_arena();
            let align = layout.align().max(1);
            let size = layout.size();
            // CAS-loop bump with alignment.  Same request sequence -> same
            // returned addresses on every run (no per-run/per-recorder state).
            loop {
                let cur = self.offset.load(Ordering::Relaxed);
                let base = ARENA_BASE + cur;
                let aligned = (base + (align - 1)) & !(align - 1);
                let new_off = (aligned - ARENA_BASE) + size;
                if new_off > ARENA_SIZE {
                    return std::ptr::null_mut();
                }
                if self
                    .offset
                    .compare_exchange_weak(cur, new_off, Ordering::Relaxed, Ordering::Relaxed)
                    .is_ok()
                {
                    return aligned as *mut u8;
                }
            }
        }

        unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {
            // Leaking bump allocator: never reclaim.  Deterministic and fine
            // for a short-lived test program.
        }
    }
}

#[cfg(mcr_pinned_alloc)]
#[global_allocator]
static PINNED_ALLOC: pinned_alloc::PinnedBumpAlloc = pinned_alloc::PinnedBumpAlloc::new();

// ---------------------------------------------------------------------------
// Pillar A early-intervention: cooperatively pin the kernel-seeded stack-
// protector entropy (macOS).
//
// Validates MCR-macOS-Replay-Symmetry-Options.md early-intervention idea: with
// the heap pinned by the allocator above, the residual replay divergence was
// isolated to a single non-deterministic STACK page at VA 0x16fe00000 — the
// stack-protector canary `___stack_chk_guard`.  macOS seeds that guard per-exec
// from the kernel-supplied `apple[]` `stack_guard=` entropy, which survives
// `_POSIX_SPAWN_DISABLE_ASLR`.  So every protected function pushes a different
// canary word onto the stack at record vs replay, and that stack page's hash
// varies every run -> control-flow / page-hash divergence at geid 2173.
//
// Fix (cooperative, in-process, language-agnostic analogue of "start suspended
// + intervene at first steps"): overwrite `___stack_chk_guard` to a FIXED
// value as EARLY as possible — in a `__mod_init_func` constructor that runs
// after libSystem init (which seeds the guard) but before `main` and before
// any of this program's protected functions run.  Once fixed, every canary
// word pushed/checked is deterministic, so the divergent stack page matches at
// record and replay.  The fixed value mirrors libc convention (a leading zero
// byte so a string-overflow read stops at the guard).
//
// Also pin `___pointer_chk_guard` (the ptr_munge / pointer-mangling cookie),
// which is seeded from the same per-exec entropy and could surface as the next
// residual.
#[cfg(all(mcr_pinned_alloc, target_os = "macos"))]
mod stack_guard_pin {
    // libc convention: high bytes random, low byte zero.  We pin a fixed
    // constant with a zero LSB.  (little-endian: the zero byte lands lowest.)
    const FIXED_STACK_GUARD: usize = 0x0102_0304_0506_0700;
    const FIXED_POINTER_GUARD: usize = 0x0a0b_0c0d_0e0f_1011;

    extern "C" {
        // macOS C symbol `__stack_chk_guard`.  Rust source needs `__` here;
        // the codegen prepends one underscore, yielding the `___stack_chk_guard`
        // that the C runtime exports.
        #[link_name = "__stack_chk_guard"]
        static mut STACK_CHK_GUARD: usize;
    }

    // `__pointer_chk_guard` (ptr_munge cookie) is NOT exported as a linkable
    // dylib symbol on macOS arm64, so resolve it dynamically and skip if absent.
    extern "C" {
        fn dlsym(handle: *mut std::ffi::c_void, symbol: *const u8) -> *mut std::ffi::c_void;
    }
    // RTLD_DEFAULT on Darwin.
    const RTLD_DEFAULT: *mut std::ffi::c_void = -2isize as *mut std::ffi::c_void;

    extern "C" fn pin_guards() {
        unsafe {
            STACK_CHK_GUARD = FIXED_STACK_GUARD;
            // Try both the 2- and 3-underscore spellings for the pointer guard;
            // whichever the dynamic linker knows.  Non-fatal if neither exists.
            for name in [b"__pointer_chk_guard\0".as_ptr(), b"___pointer_chk_guard\0".as_ptr()] {
                let p = dlsym(RTLD_DEFAULT, name) as *mut usize;
                if !p.is_null() {
                    *p = FIXED_POINTER_GUARD;
                    break;
                }
            }
        }
    }

    // Run `pin_guards` as a Mach-O module initializer (before `main`).
    #[used]
    #[link_section = "__DATA,__mod_init_func"]
    static PIN_GUARDS_CTOR: extern "C" fn() = pin_guards;
}

fn calculate_sum(a: i32, b: i32) -> i32 {
    // Local variables inside a function
    let sum = a + b;
    let doubled = sum * 2;
    let final_result = doubled + 10;
    println!("Sum: {}", sum);
    println!("Doubled: {}", doubled);
    println!("Final: {}", final_result);
    final_result
}

fn main() {
    // Local variables in main
    let x = 10;
    let y = 32;
    let result = calculate_sum(x, y);
    println!("Result: {}", result);
    with_loops(x);
}

fn with_loops(a: i32) {
    let mut sum = 0;
    for i in 0..a {
        sum += i;
    }
    println!("sum with for {sum}");

    sum = 0;
    let mut i_2 = 0;
    loop {
        sum += i_2;
        if i_2 >= a - 1 {
            break;
        }
        i_2 += 1;
    }
    println!("sum with loop {sum}");

    sum = 0;
    let mut i_3 = 0;
    while i_3 < a {
        sum += i_3;
        i_3 += 1;
    }
    println!("sum with while {sum}");
}
