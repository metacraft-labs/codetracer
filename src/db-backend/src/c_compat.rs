#[cfg(feature = "browser-transport")]
extern crate alloc;

use alloc::alloc::{alloc as sys_alloc, dealloc as sys_dealloc, realloc as sys_realloc, Layout};
use core::ffi::{c_char, c_int, c_void};
use core::mem::{align_of, size_of};
use core::ptr::null_mut;
use std::ffi::CStr;

#[cfg(feature = "browser-transport")]
#[global_allocator]
static ALLOC: wee_alloc::WeeAlloc = wee_alloc::WeeAlloc::INIT;

// Layout: [ usize: size ][ payload... ]
const HEADER_ALIGN: usize = align_of::<usize>();
const HEADER_SIZE: usize = size_of::<usize>();

#[inline]
unsafe fn layout_for_total(total: usize) -> Option<Layout> {
    Layout::from_size_align(total, HEADER_ALIGN).ok()
}

#[inline]
unsafe fn alloc_with_header(size: usize) -> *mut u8 {
    if size == 0 {
        return null_mut();
    }
    let total = match size.checked_add(HEADER_SIZE) {
        Some(t) => t,
        None => return null_mut(),
    };
    let layout = match layout_for_total(total) {
        Some(l) => l,
        None => return null_mut(),
    };
    let header = sys_alloc(layout);
    if header.is_null() {
        return null_mut();
    }
    // write payload size
    (header as *mut usize).write(size);
    header.add(HEADER_SIZE)
}

#[inline]
unsafe fn header_from_payload(p: *mut u8) -> *mut u8 {
    p.sub(HEADER_SIZE)
}

#[inline]
unsafe fn payload_size(p: *mut u8) -> usize {
    (p as *mut usize).sub(1).read()
}

#[no_mangle]
pub extern "C" fn malloc(size: usize) -> *mut c_void {
    unsafe { alloc_with_header(size) as *mut c_void }
}

#[no_mangle]
pub extern "C" fn free(ptr: *mut c_void) {
    unsafe {
        if ptr.is_null() {
            return;
        }
        let p = ptr as *mut u8;
        let old_size = payload_size(p);
        let total = match old_size.checked_add(HEADER_SIZE) {
            Some(t) => t,
            None => return,
        };
        if let Some(layout) = layout_for_total(total) {
            let header = header_from_payload(p);
            sys_dealloc(header, layout);
        }
    }
}

#[no_mangle]
pub extern "C" fn realloc(ptr: *mut c_void, new_size: usize) -> *mut c_void {
    unsafe {
        if ptr.is_null() {
            return malloc(new_size);
        }
        if new_size == 0 {
            free(ptr);
            return null_mut();
        }

        let p = ptr as *mut u8;
        let old_size = payload_size(p);

        // Old layout (includes header)
        let old_total = match old_size.checked_add(HEADER_SIZE) {
            Some(t) => t,
            None => return null_mut(),
        };
        let old_layout = match layout_for_total(old_total) {
            Some(l) => l,
            None => return null_mut(),
        };

        // New total size (includes header)
        let new_total = match new_size.checked_add(HEADER_SIZE) {
            Some(t) => t,
            None => return null_mut(),
        };

        let old_header = header_from_payload(p);
        let new_header = sys_realloc(old_header, old_layout, new_total);
        if new_header.is_null() {
            return null_mut();
        }

        // Update stored size and return payload pointer
        (new_header as *mut usize).write(new_size);
        new_header.add(HEADER_SIZE) as *mut c_void
    }
}

#[no_mangle]
pub extern "C" fn calloc(nmemb: usize, size: usize) -> *mut c_void {
    match nmemb.checked_mul(size) {
        Some(len) => unsafe {
            let p = alloc_with_header(len);
            if !p.is_null() {
                core::ptr::write_bytes(p, 0, len);
            }
            p as *mut c_void
        },
        None => null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn fprintf(_stream: *mut c_void, _fmt: *const c_char, _arg: *const c_void) -> c_int {
    // Pretend 0 chars written.
    0
}

#[no_mangle]
pub extern "C" fn fclose(_stream: *mut c_void) -> c_int {
    0
}

#[no_mangle]
pub extern "C" fn snprintf(buf: *mut c_char, n: usize, _fmt: *const c_char, _arg: usize) -> c_int {
    unsafe {
        if !buf.is_null() && n > 0 {
            *buf = 0;
        }
    }
    0
}

// Dummy va_list type for signature compatibility
#[repr(C)]
pub struct va_list__dummy {
    _priv: [u8; 0],
}

#[no_mangle]
pub extern "C" fn vsnprintf(buf: *mut c_char, n: usize, _fmt: *const c_char, _ap: *mut va_list__dummy) -> c_int {
    unsafe {
        if !buf.is_null() && n > 0 {
            *buf = 0;
        }
    }
    0
}

#[no_mangle]
pub extern "C" fn abort() -> ! {
    #[cfg(feature = "browser-transport")]
    wasm_bindgen::throw_str("abort");
}

#[inline]
unsafe fn cstr_prefix_len(mut p: *const u8, limit: usize) -> usize {
    // Count up to first NUL or `limit` bytes.
    let mut i = 0usize;
    while i < limit {
        let b = *p;
        if b == 0 {
            break;
        }
        i += 1;
        p = p.add(1);
    }
    i
}

#[no_mangle]
pub extern "C" fn strncmp(s1: *const c_char, s2: *const c_char, n: usize) -> c_int {
    if n == 0 {
        return 0;
    }
    if s1.is_null() || s2.is_null() {
        return 0;
    } // benign stub behavior

    // SAFETY: caller promises valid C strings; we only touch up to `n` bytes or NUL.
    let a = s1 as *const u8;
    let b = s2 as *const u8;
    let len = unsafe {
        let l1 = cstr_prefix_len(a, n);
        let l2 = cstr_prefix_len(b, n);
        core::cmp::min(core::cmp::min(l1, l2), n)
    };

    // Compare common prefix (unsigned char semantics)
    for i in 0..len {
        let av = unsafe { *a.add(i) } as u8;
        let bv = unsafe { *b.add(i) } as u8;
        if av != bv {
            return (av as c_int) - (bv as c_int);
        }
    }

    // If we stopped early (before n), one string may have ended (NUL) earlier.
    if len < n {
        let av = unsafe { *a.add(len) } as u8; // 0 if NUL, else next byte
        let bv = unsafe { *b.add(len) } as u8;
        return (av as c_int) - (bv as c_int);
    }
    0
}

#[no_mangle]
pub extern "C" fn clock() -> c_int {
    #[cfg(feature = "browser-transport")]
    {
        // js_sys::Date::now() -> f64 milliseconds since epoch

        use web_sys::js_sys;
        let ms = js_sys::Date::now() as u64;
        return (ms & 0x7fff_ffff) as c_int;
    }
}

#[inline]
fn write_host(_s: &str, _stream: *mut c_void) {
    // no-op
}

/// int fputc(int c, FILE *stream)
#[no_mangle]
pub extern "C" fn fputc(c: c_int, stream: *mut c_void) -> c_int {
    let ch = (c as u8) as char;
    let mut buf = [0u8; 4];
    let s = ch.encode_utf8(&mut buf);
    write_host(s, stream);
    // C fputc returns the written character cast to unsigned char as int
    (c as u8) as c_int
}

/// int fputs(const char *s, FILE *stream)
#[no_mangle]
pub extern "C" fn fputs(s: *const c_char, stream: *mut c_void) -> c_int {
    if s.is_null() {
        return -1;
    }
    // SAFETY: caller promises valid NUL-terminated string
    let bytes = unsafe { CStr::from_ptr(s) }.to_bytes();
    let text = core::str::from_utf8(bytes).unwrap_or("<invalid utf-8>");
    write_host(text, stream);
    // C fputs returns a nonnegative value on success (commonly a non-portable value, so we return len)
    bytes.len() as c_int
}

#[no_mangle]
pub extern "C" fn fdopen(fd: c_int, _mode: *const c_char) -> *mut c_void {
    // Provide distinct, non-null sentinel handles for stdin/stdout/stderr (0/1/2).
    // We never dereference these; other stubs ignore `stream` and treat any non-null as valid.
    if (0..=2).contains(&fd) {
        (fd as usize + 1) as *mut c_void
    } else {
        null_mut()
    }
}
