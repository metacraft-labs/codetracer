#[cfg(feature = "browser-transport")]
extern crate alloc;

use alloc::alloc::{alloc as sys_alloc, dealloc as sys_dealloc, realloc as sys_realloc, Layout};
use core::cmp::min;
use core::ffi::{c_char, c_int, c_void};
use core::mem::{align_of, size_of};
use core::ptr::null_mut;

#[cfg(feature = "browser-transport")]
#[global_allocator]
static ALLOC: wee_alloc::WeeAlloc = wee_alloc::WeeAlloc::INIT;

// We store the requested payload size in a word just before the user pointer.
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

// ------- Minimal I/O stubs (no real stdio on wasm32-unknown-unknown) -------

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

    #[cfg(feature = "io-transport")]
    std::process::abort()
}
