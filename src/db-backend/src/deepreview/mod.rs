//! DeepReview collection for materialized (CTFS) recordings — RV-4.
//!
//! `codetracer-specs/DeepReview/DeepReview-GUI.md` §1.1 names two collectors
//! and says which recordings each reads:
//!
//! | Trace kind | Collector |
//! |---|---|
//! | Native / rr | `ct-native-replay review-data collect` |
//! | Materialized (CTFS) | **this module**, over the same trace database the debugger reads |
//!
//! `ct review collect` chooses between them by inspecting the recordings
//! (`src/ct/review_cli.nim`, RV-3); the user never names a backend.
//!
//! The three submodules are the three jobs: [`unified_diff`] reads the patch,
//! [`collector`] assembles the dataset out of the db-backend's existing
//! ingredients, and [`json`] is the shape the GUI reads.  [`cli`] is the
//! subprocess entry point `ct` invokes.

pub mod cli;
pub mod collector;
pub mod json;
pub mod unified_diff;
