//! Shared test helpers usable by any `tests/*.rs` integration target.
//!
//! Each integration test in Cargo is a separate crate. To share code,
//! consumers add `mod common;` at the top of their `.rs` and access
//! these helpers via `use common::fixture_ids::*;`.
//!
//! Currently exposes:
//!
//! - [`fixture_ids`]: canonical UUIDv7 `recording_id` constants for every
//!   committed example recording (M-REC-12 of the Recording-Identifier
//!   Migration).

pub mod fixture_ids;
