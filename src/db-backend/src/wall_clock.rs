//! Platform-conditional clock for code that also runs in the browser.
//!
//! `std::time::SystemTime::now()` and `std::time::Instant::now()` are
//! unimplemented on `wasm32-unknown-unknown`. They are not stubs that return
//! an error — `library/std/src/sys/time/unsupported.rs` panics, and on wasm32
//! that panic compiles to an `unreachable` instruction which **kills the
//! whole worker**. Nothing unwinds, no DAP response is ever written, and the
//! renderer's future hangs forever. `src/db-backend/src/vfs.rs` documents the
//! same hazard for the `vfs` crate and works around it the same way: replace
//! the trapping call with something the target can actually run.
//!
//! Three replay paths were observed dying this way in the browser
//! (`ct/load-locals` via `WallClockDeadline`, `ct/originChain`, and any step
//! that reaches a trace boundary via `Notification::new`), so **every**
//! clock read in this crate goes through one of the two functions below
//! rather than through `std::time` directly. `wall_clock_sweep_test`
//! (`src/db-backend/tests/wall_clock_sweep_test.rs`) fails the build if a
//! raw `SystemTime::now()` / `Instant::now()` reappears in a module that is
//! compiled into the wasm build.
//!
//! Two distinct needs, two functions:
//!
//! * [`monotonic_ms`] — for measuring a *duration* (budgets, deadlines,
//!   `elapsed_ms` telemetry). Only differences between two readings are
//!   meaningful.
//! * [`unix_seconds`] — for an informational timestamp that is serialised to
//!   the client (`Notification.time`, `Stop.time`, `HistoryResult.time`,
//!   `OriginContinuationToken.issued_at`). No consumer in this repo reads
//!   these back; they exist to fill a protocol field.
//!
//! Prefer neither where a clock is not actually needed: an id or an ordering
//! key should come from the trace (`step_id`, `rr_ticks`), never from the
//! host's clock.

/// Milliseconds since an unspecified, target-defined epoch.
///
/// Only *differences* between two readings are meaningful. On native this is
/// the wall clock (matching the previous `SystemTime`-based behaviour of
/// `WallClockDeadline`); in the browser it is `Date.now()`, which is the
/// same shape and the same guarantee.
///
/// On a wasm target built *without* `browser-transport` there is no clock at
/// all, so this returns `0` — every duration measures as zero, which makes
/// wall-clock budgets non-binding rather than fatal. That is the correct
/// trade: a budget that never fires degrades a query's latency, while a trap
/// takes down the process.
pub fn monotonic_ms() -> u64 {
    #[cfg(not(target_arch = "wasm32"))]
    {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }
    #[cfg(all(target_arch = "wasm32", feature = "browser-transport"))]
    {
        // `Date.now()` is milliseconds since the UNIX epoch. It is available
        // in a DedicatedWorkerGlobalScope, unlike `performance.now()`, whose
        // binding depends on which `web-sys` features are enabled.
        let ms = js_sys::Date::now();
        if ms.is_finite() && ms > 0.0 { ms as u64 } else { 0 }
    }
    #[cfg(all(target_arch = "wasm32", not(feature = "browser-transport")))]
    {
        0
    }
}

/// Seconds since the UNIX epoch, for informational protocol timestamps.
///
/// Returns `0` when the target has no clock, which is already the
/// established convention for such fields in this crate — see the
/// `issued_at: 0` placeholders in `origin_query.rs`.
pub fn unix_seconds() -> u64 {
    #[cfg(not(target_arch = "wasm32"))]
    {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }
    #[cfg(target_arch = "wasm32")]
    {
        monotonic_ms() / 1000
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// On a host target both readings must be real, so the shim is not
    /// silently degrading native behaviour into the wasm fallback.
    #[test]
    fn native_readings_are_real() {
        assert!(
            unix_seconds() > 1_600_000_000,
            "unix_seconds must be a real wall-clock stamp on a native target",
        );
        assert!(monotonic_ms() > 1_600_000_000_000);
    }

    /// `monotonic_ms` must never go backwards across two reads, or a
    /// deadline built from it can never expire.
    #[test]
    fn monotonic_ms_does_not_go_backwards() {
        let first = monotonic_ms();
        std::thread::sleep(std::time::Duration::from_millis(5));
        let second = monotonic_ms();
        assert!(second >= first, "{second} < {first}");
    }

    /// The two functions must agree about which epoch they are on, so a
    /// `unix_seconds` stamp and a `monotonic_ms` reading cannot disagree by
    /// a factor of 1000 depending on target.
    #[test]
    fn the_two_sources_share_an_epoch() {
        let seconds = unix_seconds();
        let millis = monotonic_ms();
        assert!(
            millis / 1000 >= seconds.saturating_sub(1) && millis / 1000 <= seconds + 1,
            "unix_seconds()={seconds} and monotonic_ms()={millis} disagree about the epoch",
        );
    }
}
