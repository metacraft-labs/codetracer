//! # origin-classifier
//!
//! Source-language assignment classifier for CodeTracer's Value Origin
//! Tracking feature. This crate is consumed at *replay time* by the
//! db-backend; recorders do NOT depend on it (per spec
//! `Planned-Features/Value-Origin-Tracking.milestones.org` M1 and GUI
//! spec §7).
//!
//! At a requirements level (spec §7) the crate provides three
//! operations:
//!
//! - [`parse_assignment`]: parse a single source-line into an
//!   [`AssignmentAst`].
//! - [`classify`]: match the AST against a prioritised list of
//!   patterns (built-ins plus user-defined overrides) and return an
//!   [`OriginKind`], a target locator, a continuation locator, a
//!   source-variable hint, and a confidence score.
//! - [`PatternSet::load_layered`]: load embedded library patterns,
//!   personal overrides, trace-local overrides, and built-ins per the
//!   override precedence rules in spec §7.4.
//!
//! The crate is purely functional — no global state, no I/O outside
//! the explicit pattern loader entry points — so it can be unit
//! tested standalone.

#![deny(missing_debug_implementations)]
#![forbid(unsafe_code)]

pub mod ast;
pub mod classify;
pub mod kinds;
pub mod patterns;

pub use ast::{parse_assignment, parse_call_arguments, AssignmentAst, NodeLocator};
pub use classify::{classify, Classification, ClassificationSource};
pub use kinds::{Lang, OriginKind};
pub use patterns::{
    LoadError, PatternFingerprint, PatternKind, PatternProvenance, PatternRule, PatternSet,
};
