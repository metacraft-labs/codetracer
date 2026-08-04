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

    // Preferred arena base.  Above __PAGEZERO / the program image / the stack
    // (all < ~6 GiB), above the dyld shared cache region [0x180000000,
    // 0x300000000), and clear of the recorder's M-RLP fixed-VA reservations
    // (TiB band, e.g. buffers @ 96/104 TiB) and the 0x6000_*/0x8000_*/0x9000_*
    // recorder bands.
    //
    // This is a PREFERENCE, not a guarantee, and `ensure_arena` verifies it
    // before use.  The previous comment here claimed the address was
    // "host-probed: FIXED mmap is honored cleanly from 0x7_0000_0000 upward".
    // Measured on macOS 26.5.1 arm64: that is true 99.1% of launches and fatal
    // the rest.  `mmap(MAP_FIXED)` asks the kernel to DELETE whatever occupies
    // the target range first, and on macOS 26 the user address space above
    // 0x300000000 is carved into a ~24 GiB kernel reservation block (two ~12 GiB
    // `prot=0 max=0 SM_EMPTY` entries either side of the malloc small/large
    // zones) whose base is randomised per launch.  A FIXED request that is
    // wholly INSIDE one of those entries is honoured; one that straddles an
    // entry's edge — or lands in unmapped space — makes the implicit delete
    // span a hole, and the kernel kills the process outright with
    // EXC_GUARD / GUARD_TYPE_VIRT_MEMORY / DEALLOC_GAP: no signal handler, no
    // output, only an .ips report.
    //
    // 0xa_0000_0000 is the worst constant available: the reservation block's
    // minimum possible END is exactly 0xa00000000, so the arena sits precisely
    // at the bottom of the distribution of "reservation ends inside my range".
    // Measured with a 30-line standalone C program, no recorder attached:
    // 26 of 3000 launches (0.87%) SIGKILLed; `gaps>0` in the VM map predicted
    // the kill 26/26 and `gaps==0` gave 0 kills in 2974.  There is no constant
    // that is always safe — the reservation block slides across ~22 GiB, so
    // every fixed VA in the mappable region is straddled sometimes, and
    // everything outside it is either permanently EACCES-locked
    // ([0xfc0000000, 0x7000000000)) or unmapped (fatal).  Hence the runtime
    // check in `ensure_arena` rather than a better constant.
    const ARENA_BASE: usize = 0xa_0000_0000;
    // 256 MiB arena — far more than this tiny program needs; bump-only/leaking
    // is fine for a short-lived test program.
    const ARENA_SIZE: usize = 256 * 1024 * 1024;

    const PROT_READ: i32 = 0x1;
    const PROT_WRITE: i32 = 0x2;
    const MAP_PRIVATE: i32 = 0x0002;
    const MAP_ANON: i32 = 0x1000;
    const MAP_FIXED: i32 = 0x0010;

    const MAP_FAILED: usize = usize::MAX;

    // Mach VM query used to verify the target range before overwriting it.
    // 19 = VM_REGION_SUBMAP_INFO_COUNT_64 (76-byte info struct / 4-byte natural_t).
    const VM_REGION_SUBMAP_INFO_COUNT_64: u32 = 19;
    const KERN_SUCCESS: i32 = 0;

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
        fn write(fd: i32, buf: *const u8, n: usize) -> isize;
        fn mach_task_self() -> u32;
        fn mach_vm_region_recurse(
            target_task: u32,
            address: *mut u64,
            size: *mut u64,
            nesting_depth: *mut u32,
            info: *mut i32,
            info_cnt: *mut u32,
        ) -> i32;
    }

    /// Is `mmap(MAP_FIXED)` over `[lo, lo+sz)` safe to issue?
    ///
    /// Safe means: the range is WHOLLY COVERED by existing VM map entries, so
    /// `MAP_FIXED`'s implicit delete cannot span a hole.  Any hole — a gap
    /// between entries, an entry that ends inside the range, or a range that is
    /// entirely unmapped — is fatal (EXC_GUARD/DEALLOC_GAP, SIGKILL, no output).
    ///
    /// This runs inside the global allocator, so it must not allocate:
    /// `mach_vm_region_recurse` is a fixed-size MIG call over the thread's Mach
    /// reply port and the info buffer lives on the stack.
    ///
    /// NOTE for anyone tempted to use something cheaper: `mincore()` does NOT
    /// work.  Measured over 3000 launches, it returned 0 ("all mapped") for all
    /// 2974 gap-free ranges AND for all 26 gapped ones — it cannot distinguish
    /// the fatal case at all.
    fn fixed_map_is_safe(lo: usize, sz: usize) -> bool {
        let hi = (lo + sz) as u64;
        let mut cursor = lo as u64;
        let mut expect = lo as u64;
        let mut entries = 0u32;
        while cursor < hi && entries < 64 {
            let mut region_size: u64 = 0;
            let mut depth: u32 = 0;
            let mut info = [0i32; VM_REGION_SUBMAP_INFO_COUNT_64 as usize];
            let mut count: u32 = VM_REGION_SUBMAP_INFO_COUNT_64;
            let kr = unsafe {
                mach_vm_region_recurse(
                    mach_task_self(),
                    &mut cursor,
                    &mut region_size,
                    &mut depth,
                    info.as_mut_ptr(),
                    &mut count,
                )
            };
            // No region at or above the cursor: the rest of the range is a hole.
            if kr != KERN_SUCCESS || region_size == 0 {
                return false;
            }
            // The next region starts past our range: everything from `expect`
            // to `hi` is unmapped.
            if cursor >= hi {
                break;
            }
            // A region that starts above where we expected leaves a hole.
            if cursor > expect {
                return false;
            }
            entries += 1;
            expect = cursor + region_size;
            cursor = expect;
        }
        entries > 0 && expect >= hi
    }

    /// Allocation-free stderr line: `msg` then `val` in hex then newline.
    /// The buffer is sized so the longest caller message below fits whole — a
    /// truncated warning is a half-silent warning.
    fn warn_hex(msg: &[u8], val: usize) {
        let mut buf = [0u8; 512];
        let mut n = 0usize;
        for &b in msg {
            if n < buf.len() {
                buf[n] = b;
                n += 1;
            }
        }
        if n + 2 < buf.len() {
            buf[n] = b'0';
            buf[n + 1] = b'x';
            n += 2;
        }
        let mut started = false;
        let mut shift = 60i32;
        while shift >= 0 {
            let nib = ((val >> shift) & 0xf) as u8;
            if nib != 0 || started || shift == 0 {
                started = true;
                if n < buf.len() {
                    buf[n] = if nib < 10 { b'0' + nib } else { b'a' + nib - 10 };
                    n += 1;
                }
            }
            shift -= 4;
        }
        if n < buf.len() {
            buf[n] = b'\n';
            n += 1;
        }
        unsafe {
            let _ = write(2, buf.as_ptr(), n);
        }
    }

    pub struct PinnedBumpAlloc {
        // Base the arena actually landed at.  ARENA_BASE in the common case;
        // see `ensure_arena` for when and why it can differ.
        base: AtomicUsize,
        // Next free offset within the arena (relative to `base`).
        offset: AtomicUsize,
        // Whether the arena has been mapped yet.
        ready: AtomicBool,
        // Spin guard for the one-time mmap.
        mapping: AtomicBool,
    }

    impl PinnedBumpAlloc {
        pub const fn new() -> Self {
            PinnedBumpAlloc {
                base: AtomicUsize::new(0),
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
            // until `ready`.
            if self
                .mapping
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                // VERIFY BEFORE OVERWRITING.  `mmap(MAP_FIXED)` over a range
                // that is not wholly mapped is not an error the program can
                // observe — it is an immediate SIGKILL with no output at all
                // (see the ARENA_BASE comment).  So we never issue one without
                // first checking, and when the check fails we take the kernel's
                // placement instead of dying.
                let (p, fixed) = if fixed_map_is_safe(ARENA_BASE, ARENA_SIZE) {
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
                    (p as usize, true)
                } else {
                    // Not a silent fallback: say so, on stderr, every time.
                    // Losing the pinned VA costs record/replay layout symmetry
                    // for this run — the recorder still records and replays the
                    // returned address, so the run is correct, just no longer
                    // independent of process-memory weather.  Measured
                    // frequency of this branch on the shipped binary: 22 of
                    // 3000 launches (0.73%), 0 kills; the unpatched program
                    // SIGKILLed on 26 of 3000 (0.87%).
                    //
                    // KNOWN ASYMMETRY, stated rather than hidden: the branch is
                    // chosen from the LIVE VM layout, which is not the same at
                    // record and replay, so a recording made on the fixed path
                    // could be replayed on this one (or vice versa) — and this
                    // path issues an extra `write(2, ...)`, which the recorder
                    // hooks, so a strict cooperative replay would see one more
                    // event than it consumed.  That is a diagnosable divergence
                    // with a printed reason, in exactly the ~0.8% of launches
                    // that previously died by SIGKILL with no output at all, so
                    // it is strictly better than what it replaces — but it is
                    // not free, and the real fix is for the recorder to pin
                    // this range at replay from the recorded event.
                    warn_hex(
                        b"[rust_flow_test] pinned arena: MAP_FIXED unsafe at the \
                          preferred base (range not wholly mapped; a FIXED map \
                          here would SIGKILL) - taking kernel placement instead \
                          of the pinned VA base=",
                        ARENA_BASE,
                    );
                    let p = unsafe {
                        mmap(
                            ARENA_BASE as *mut std::ffi::c_void,
                            ARENA_SIZE,
                            PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANON,
                            -1,
                            0,
                        )
                    };
                    (p as usize, false)
                };
                if p == MAP_FAILED || p == 0 || (fixed && p != ARENA_BASE) {
                    // Either the mmap failed outright, or MAP_FIXED was honoured
                    // somewhere other than where we asked (which the flag
                    // forbids).  Either way the allocator has no arena; fail
                    // loudly rather than hand out null or corrupt the layout.
                    warn_hex(b"[rust_flow_test] pinned arena: mmap FAILED, got=", p);
                    unsafe { abort() };
                }
                self.base.store(p, Ordering::Release);
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
            let arena = self.base.load(Ordering::Acquire);
            let align = layout.align().max(1);
            let size = layout.size();
            // CAS-loop bump with alignment.  Same request sequence -> same
            // returned addresses on every run (no per-run/per-recorder state).
            loop {
                let cur = self.offset.load(Ordering::Relaxed);
                let base = arena + cur;
                let aligned = (base + (align - 1)) & !(align - 1);
                let new_off = (aligned - arena) + size;
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
