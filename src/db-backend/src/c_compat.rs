extern crate alloc;

use alloc::alloc::{Layout, alloc as sys_alloc, dealloc as sys_dealloc, realloc as sys_realloc};
use core::ffi::{c_char, c_int, c_void};
use core::mem::{align_of, size_of};
use core::ptr::null_mut;

// Layout: [ usize: size ][ payload... ]
const HEADER_ALIGN: usize = align_of::<usize>();
const HEADER_SIZE: usize = size_of::<usize>();

#[unsafe(no_mangle)]
pub static mut errno: c_int = 0;

#[inline]
fn layout_for_total(total: usize) -> Option<Layout> {
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
    let header = unsafe { sys_alloc(layout) };
    if header.is_null() {
        return null_mut();
    }
    unsafe {
        (header as *mut usize).write(size);
        header.add(HEADER_SIZE)
    }
}

#[inline]
unsafe fn header_from_payload(p: *mut u8) -> *mut u8 {
    unsafe { p.sub(HEADER_SIZE) }
}

#[inline]
unsafe fn payload_size(p: *mut u8) -> usize {
    unsafe { (p as *mut usize).sub(1).read() }
}

#[unsafe(no_mangle)]
pub extern "C" fn malloc(size: usize) -> *mut c_void {
    unsafe { alloc_with_header(size) as *mut c_void }
}

#[unsafe(no_mangle)]
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

#[unsafe(no_mangle)]
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

#[unsafe(no_mangle)]
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

#[unsafe(no_mangle)]
pub extern "C" fn fprintf(_stream: *mut c_void, _fmt: *const c_char, _arg: *const c_void) -> c_int {
    unreachable!("Running in wasm mode. Should not be calling `fprintf`");
}

#[unsafe(no_mangle)]
pub extern "C" fn fclose(_stream: *mut c_void) -> c_int {
    unreachable!("Running in wasm mode. Should not be calling `fclose`");
}

#[unsafe(no_mangle)]
pub extern "C" fn ferror(_stream: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn clearerr(_stream: *mut c_void) {}

#[unsafe(no_mangle)]
pub extern "C" fn fflush(_stream: *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn fopen(_filename: *const c_char, _mode: *const c_char) -> *mut c_void {
    null_mut()
}

#[unsafe(no_mangle)]
pub extern "C" fn fread(_buffer: *mut c_void, _size: usize, _nmemb: usize, _stream: *mut c_void) -> usize {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn fwrite(_buffer: *const c_void, _size: usize, nmemb: usize, _stream: *mut c_void) -> usize {
    nmemb
}

#[unsafe(no_mangle)]
pub extern "C" fn fseeko(_stream: *mut c_void, _offset: i64, _whence: c_int) -> c_int {
    -1
}

#[unsafe(no_mangle)]
pub extern "C" fn ftello(_stream: *mut c_void) -> i64 {
    -1
}

#[unsafe(no_mangle)]
pub extern "C" fn setvbuf(_stream: *mut c_void, _buffer: *mut c_char, _mode: c_int, _size: usize) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn strerror(_errnum: c_int) -> *mut c_char {
    c"wasm libc error".as_ptr().cast_mut()
}

#[unsafe(no_mangle)]
pub extern "C" fn snprintf(_buf: *mut c_char, _n: usize, _fmt: *const c_char, _arg: usize) -> c_int {
    unreachable!("Running in wasm mode. Should not be calling `snprintf`");
}

// Dummy va_list type for signature compatibility
#[repr(C)]
pub struct va_list__dummy {
    _priv: [u8; 0],
}

#[unsafe(no_mangle)]
pub extern "C" fn vsnprintf(_buf: *mut c_char, _n: usize, _fmt: *const c_char, _ap: *mut va_list__dummy) -> c_int {
    unreachable!("Running in wasm mode. Should not be calling `vsprintf`");
}

#[unsafe(no_mangle)]
pub extern "C" fn abort() -> ! {
    wasm_bindgen::throw_str("abort");
}

#[unsafe(no_mangle)]
/// A real `strncmp`, because the emulator C legitimately calls one.
///
/// This was a trapping stub, and it is the bug the browser replay gate found:
/// every `ct/load-locals` after a step died here with
/// `entered unreachable code`, six traps for six steps, killing the request
/// each time. Nothing about `strncmp` needs a host — it is a bounded compare
/// over two byte strings — so trapping was never a statement about wasm, only
/// about which stubs had been filled in.
///
/// C semantics, exactly: compare at most `n` bytes, stop at the first NUL or
/// first difference, and return the difference of the bytes as UNSIGNED chars.
/// Returning a signed difference is the classic way to get this subtly wrong
/// for bytes above 0x7f.
///
/// # Safety
/// `s1` and `s2` must each be valid for reads up to the first NUL or `n`
/// bytes, whichever comes first — the same contract libc has.
pub extern "C" fn strncmp(s1: *const c_char, s2: *const c_char, n: usize) -> c_int {
    if n == 0 {
        return 0;
    }
    if s1.is_null() || s2.is_null() {
        // libc would fault; a trap here would be the same bug again, so answer
        // "equal only if both are absent" and let the caller carry on.
        return if s1.is_null() && s2.is_null() { 0 } else { 1 };
    }
    for offset in 0..n {
        // SAFETY: the caller's contract, above; we stop at the first NUL.
        let (a, b) = unsafe {
            (
                *s1.add(offset) as u8,
                *s2.add(offset) as u8,
            )
        };
        if a != b {
            return a as c_int - b as c_int;
        }
        if a == 0 {
            return 0;
        }
    }
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn clock() -> c_int {
    {
        // js_sys::Date::now() -> f64 milliseconds since epoch

        use web_sys::js_sys;
        let ms = js_sys::Date::now() as u64;
        return (ms & 0x7fff_ffff) as c_int;
    }
}

#[inline]
fn write_host(_s: &str, _stream: *mut c_void) {
    unreachable!("Running in wasm mode. Should not be calling `write_host`");
}

/// int fputc(int c, FILE *stream)
#[unsafe(no_mangle)]
pub extern "C" fn fputc(_c: c_int, _stream: *mut c_void) -> c_int {
    unreachable!("Running in wasm mode. Should not be calling `fputc`");
}

/// int fputs(const char *s, FILE *stream)
#[unsafe(no_mangle)]
pub extern "C" fn fputs(_s: *const c_char, _stream: *mut c_void) -> c_int {
    unreachable!("Running in wasm mode. Should not be calling `fputs`");
}

#[unsafe(no_mangle)]
pub extern "C" fn fdopen(_fd: c_int, _mode: *const c_char) -> *mut c_void {
    unreachable!("Running in wasm mode. Should not be calling `fdopen`");
}
