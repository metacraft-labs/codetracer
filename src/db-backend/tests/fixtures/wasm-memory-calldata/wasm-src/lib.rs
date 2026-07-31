// Host-supplied-state demo — WebAssembly settlement tier.
//
// This module exists to exercise the two boundary records that
// `account-balance-with-wasm`'s `balance_calc` cannot:
//
//   * **spec §3.3, host-supplied initial state.** The module's linear
//     memory is *imported*, and its inputs are read out of that memory
//     rather than taken as arguments. The `.wasm` therefore does not
//     contain them; a replay that is not told what the host put in
//     memory replays a different program.
//
//   * **spec §3.4, host mutation during a call.** `fetch_fee_bps` is an
//     imported function that returns only a *status code* and delivers
//     its real answer by writing into linear memory — the shape every
//     Stylus host hook has (`read_args`, `storage_load_bytes32`,
//     `account_balance`, …) and the shape a `wasm-bindgen`-style glue
//     layer has. Feeding the recorded return value back is not enough;
//     the write has to be replayed too, at the same point.
//
// `balance_calc` is a pure function of its two scalar arguments, which
// is exactly why the gap went unnoticed: it is the one shape that needs
// neither record. Nothing here is contrived to *produce* boundary
// records — the arrangement is the ordinary one for a contract or an
// FFI glue layer, where calldata arrives in a buffer and a host lookup
// answers out of band.
//
// # Why the module carries state across calls
//
// `RUNNING_TOTAL` accumulates, and each call returns it. That is
// deliberate. A test built on a module that carries no state cannot
// distinguish a working implementation from none: delete the state
// restore and a pure module still replays to the same answers. Here the
// third call's return value depends on the first two having really
// happened, in memory, in order.
//
// # Layout contract with the host
//
// The page finds the block through the module's own exported global
// `LEDGER`, which `rust-lld` emits carrying the symbol's address. That
// matters for more than convenience: asking the module for the address
// through an *exported function* would put a host write **between two
// top-level exported calls**, and neither §3.3 (before the first call)
// nor §3.4 (during an imported call) can express such a write. Reading
// a global crosses no recorded boundary at all, so the host can learn
// the address and fill the block before the first call, which is
// precisely what §3.3 describes.
//
// The `.wasm` is built with `-C link-arg=--import-memory`, which is what
// makes `env.memory` an import instead of a definition.

/// Records the host stages before the first exported call.
pub const RECORDS: usize = 3;

/// Status `fetch_fee_bps` returns when it has written a rate.
const FEE_OK: u32 = 1;

/// Basis-point denominator: a fee of 150 bps is 1.5 %.
const BPS_DENOMINATOR: u32 = 10_000;

/// One settlement request.
///
/// `#[repr(C)]` because the host writes it byte by byte from JavaScript
/// and both sides have to agree on the offsets. `LEDGER_RECORD_STRIDE`
/// in `page/app.js` is this struct's size.
#[repr(C)]
pub struct Record {
    /// Written by the host before the first exported call (spec §3.3).
    pub account_id: u32,
    /// Written by the host before the first exported call (spec §3.3).
    pub principal: u32,
    /// Written by the **host**, while servicing `fetch_fee_bps`
    /// (spec §3.4). Zero until then.
    pub fee_bps: u32,
    /// Written by this module.
    pub settled: u32,
}

impl Record {
    const ZERO: Record = Record {
        account_id: 0,
        principal: 0,
        fee_bps: 0,
        settled: 0,
    };
}

/// The calldata block, and the state that accumulates across calls.
#[repr(C)]
pub struct Ledger {
    pub records: [Record; RECORDS],
    pub running_total: u32,
}

/// The block itself.
///
/// `#[no_mangle] pub static mut` makes `rust-lld` export a WebAssembly
/// global of the same name holding this symbol's address, which is how
/// the page locates the block without calling into the module.
#[no_mangle]
pub static mut LEDGER: Ledger = Ledger {
    records: [Record::ZERO, Record::ZERO, Record::ZERO],
    running_total: 0,
};

/// Compile-time proof of the layout the page hard-codes.
const _: () = {
    assert!(core::mem::size_of::<Record>() == 16);
    assert!(core::mem::size_of::<Ledger>() == 16 * RECORDS + 4);
};

#[link(wasm_import_module = "env")]
extern "C" {
    /// Ask the host for an account's fee rate.
    ///
    /// Returns a **status code**, not the rate: the rate is delivered by
    /// writing it into `LEDGER.records[..].fee_bps`. That indirection is
    /// the whole point — a replay that feeds back only the status code
    /// and not the write reaches this function with the fee still zero.
    fn fetch_fee_bps(account_id: u32) -> u32;
}

/// Address of the ledger block, as a raw pointer.
///
/// Everything goes through raw pointers and volatile accesses rather
/// than through `&mut LEDGER`: the memory is shared with the host, which
/// writes into it while this module is suspended inside `fetch_fee_bps`,
/// so a compiler that cached `fee_bps` across the call would be entitled
/// to — and the recording would then be describing a program nobody ran.
#[inline]
fn ledger() -> *mut Ledger {
    core::ptr::addr_of_mut!(LEDGER)
}

/// Fee owed on `principal` at `rate_bps` basis points.
///
/// A private helper, so the materialised trace has an interior frame the
/// browser recording never mentions — the step-level detail the offline
/// re-execution is what recovers (spec §6).
fn fee_for(principal: u32, rate_bps: u32) -> u32 {
    principal / BPS_DENOMINATOR * rate_bps + principal % BPS_DENOMINATOR * rate_bps / BPS_DENOMINATOR
}

/// Settle one staged record and return the running total.
///
/// The only export. Its argument selects a record; every value it
/// computes with comes out of linear memory.
#[no_mangle]
pub extern "C" fn settle(index: u32) -> u32 {
    if index as usize >= RECORDS {
        return 0;
    }
    let record = unsafe { core::ptr::addr_of_mut!((*ledger()).records[index as usize]) };

    // Host-supplied before the first exported call (spec §3.3).
    let account_id = unsafe { core::ptr::read_volatile(core::ptr::addr_of!((*record).account_id)) };
    let principal = unsafe { core::ptr::read_volatile(core::ptr::addr_of!((*record).principal)) };

    // The host answers by writing into memory (spec §3.4) and returning
    // only whether it did.
    let status = unsafe { fetch_fee_bps(account_id) };
    if status != FEE_OK {
        return 0;
    }
    let fee_bps = unsafe { core::ptr::read_volatile(core::ptr::addr_of!((*record).fee_bps)) };

    let fee = fee_for(principal, fee_bps);
    let settled = principal - fee;
    unsafe { core::ptr::write_volatile(core::ptr::addr_of_mut!((*record).settled), settled) };

    let total = unsafe { core::ptr::read_volatile(core::ptr::addr_of!((*ledger()).running_total)) }
        + settled;
    unsafe {
        core::ptr::write_volatile(core::ptr::addr_of_mut!((*ledger()).running_total), total)
    };
    total
}
