//! NaN-payload demo — the WebAssembly tier (M52).
//!
//! A module that computes with the three float values a JavaScript host
//! could not carry before M52:
//!
//!   * an `f32` **signalling** NaN, `0x7F80_0001` — the quiet bit is
//!     clear, so any quieting, or an `f32 -> f64 -> f32` round trip,
//!     changes it;
//!   * an `f64` quiet NaN carrying a **payload**,
//!     `0x7FF8_0000_DEAD_BEEF`;
//!   * `-0.0`, whose sign is a bit no arithmetic comparison can see.
//!
//! Each crosses the module/host boundary twice: outbound as an argument
//! to the imported `observe_*` functions (spec §3.2's "WASM → host"
//! edge), and outbound again as the exported function's own result
//! (§3.1's "host → WASM" edge, whose result the recording carries so
//! replay can be checked against it).
//!
//! # Why the values are built from arguments
//!
//! The bit patterns arrive as `i32` / `i64` *parameters* rather than
//! appearing as literals, so the module genuinely computes them from a
//! host-supplied input. A literal would be folded into an `f32.const`
//! by the compiler and the recording would then only show that a
//! constant survived being copied — which proves nothing about a value
//! that was produced.
//!
//! # Why the arithmetic is what it is
//!
//! WebAssembly deliberately does **not** pin the NaN a floating-point
//! operation returns: `f32.add` on a NaN input may produce any NaN, so
//! an arithmetic step would destroy the very payload this fixture is
//! about, in the engine, before the recorder could see it. The
//! operations here are the bit-preserving ones — `reinterpret`
//! (`from_bits` / `to_bits`), `copysign`, and negation — which the core
//! spec defines exactly. `-0.0` additionally goes through `* 1.0`,
//! which IEEE-754 *does* pin: it preserves the sign of zero, so it is a
//! real multiplication whose result a sign-blind recording would get
//! wrong.

#[link(wasm_import_module = "env")]
extern "C" {
    /// Reports one `f32` to the host. The recorded argument is the
    /// module's own bit pattern (M52), not a JavaScript `Number`.
    fn observe_f32(value: f32);
    /// Reports one `f64` to the host.
    fn observe_f64(value: f64);
}

/// Build an `f32` from a host-supplied bit pattern, report it across
/// the boundary, and return it.
///
/// `copysign` is applied with the value's own sign, which is the
/// identity on the bits and is therefore a real operation the engine
/// must not be allowed to canonicalise away.
#[no_mangle]
pub extern "C" fn probe_f32(bits: i32) -> f32 {
    let value = f32::from_bits(bits as u32);
    let carried = value.copysign(value);
    unsafe { observe_f32(carried) };
    carried
}

/// Build an `f64` from a host-supplied bit pattern, report it across
/// the boundary, and return it.
#[no_mangle]
pub extern "C" fn probe_f64(bits: i64) -> f64 {
    let value = f64::from_bits(bits as u64);
    let carried = value.copysign(value);
    unsafe { observe_f64(carried) };
    carried
}

/// Negate a host-supplied `f64` and multiply it by one.
///
/// Called with `0.0`, this is how the fixture *computes* a negative
/// zero rather than declaring one: `-0.0 * 1.0` is `-0.0` under
/// IEEE-754, and the two are indistinguishable under `==`. A recording
/// that loses the sign replays `+0.0` and the divergence check has to
/// catch it.
#[no_mangle]
pub extern "C" fn probe_negated_f64(bits: i64) -> f64 {
    let value = f64::from_bits(bits as u64);
    let negated = -value * 1.0;
    unsafe { observe_f64(negated) };
    negated
}

/// Round-trip a float back to its bits inside the module.
///
/// Exists so the module has a boundary edge carrying an `i32` beside
/// the float ones: it keeps the recording's integer path exercised by
/// the same fixture, so a regression that damaged *every* value rather
/// than only floats could not pass as a float-specific fix.
#[no_mangle]
pub extern "C" fn f32_bits_roundtrip(bits: i32) -> i32 {
    f32::from_bits(bits as u32).to_bits() as i32
}
