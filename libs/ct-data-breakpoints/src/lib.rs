//! Admission rules for DAP data breakpoints (watchpoints) over a
//! CodeTracer recording.
//!
//! # Why this is a crate and not a function in `db-backend`
//!
//! `setDataBreakpoints` had exactly one implementation in this tree for
//! the whole life of the feature, and it was a *mock*: the daemon's
//! `run_mock_dap_backend` answered `verified: true` for every entry it
//! was handed.  The real replay backend had no `setDataBreakpoints` arm
//! in its DAP dispatch at all, so it answered `command
//! setDataBreakpoints not supported here` — a free-text fallthrough
//! meant for commands nobody had thought about.
//!
//! A test double that can do something the real component cannot is not
//! a convenience, it is a blindfold: every test of the watchpoint path
//! passed, against a component that could not do the thing being
//! tested.  Watchpoints never worked, and nothing could see it.
//!
//! So the rules live here, in a leaf crate that both the real backend
//! and the mock link against.  The mock cannot claim a capability the
//! backend refuses, because it is not the mock that decides.
//!
//! # What a data breakpoint means in a replay recording
//!
//! A live debugger implements a data breakpoint with a hardware watch
//! register: the CPU traps on an access to an address.  A replay
//! recording has no CPU and no registers.  What it has is a table of
//! *variable values sampled at each recorded step*.
//!
//! So the watchpoint CodeTracer can honestly offer is a **value-change
//! watchpoint**: during `continue`, stop at the first later step at
//! which the named variable's recorded value differs from the value it
//! held at the step before.  That is a real, useful data breakpoint,
//! and it is genuinely all the recording can support.
//!
//! Everything the recording *cannot* support refuses through
//! [`DataBreakpointRefusal`] — a closed set.  The point of the closed
//! set is that a caller can branch on the reason without parsing
//! English, and that adding a new way to fail requires adding a
//! variant, which is visible in review.

use serde::{Deserialize, Serialize};
use std::fmt;

/// The closed set of reasons a data breakpoint is refused.
///
/// Numbered in the 62xx block, continuing the convention
/// `db-backend`'s `OriginErrorCode` established in the 61xx block: the
/// code travels in the DAP response body so a client branches on the
/// integer, never on the message text.
///
/// This set is closed on purpose.  The defect that made this crate
/// necessary was a refusal that came from a free-text `format!` in a
/// fallthrough arm — it could not be matched on, counted, or
/// distinguished from "command name typo", so the daemon above it
/// could not tell "this backend will never do this" from "this backend
/// did not understand you".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DataBreakpointRefusal {
    /// 6201 — the `dataId` was empty or whitespace.  A watchpoint has
    /// to name something.
    EmptyDataId = 6201,

    /// 6202 — the `dataId` is not a plain variable name.
    ///
    /// The recording indexes values by *variable*, not by address or
    /// by expression: `variables_at(step)` yields `(variable_id,
    /// value)` pairs and the id resolves through a name interning
    /// table.  There is no evaluator standing behind that table that
    /// could compute `a.b[i]`, `*p`, or `x + 1` at every step of a
    /// scan, so an expression that is not a bare identifier cannot be
    /// watched.
    ExpressionNotAWatchableVariable = 6202,

    /// 6203 — a `read` or `readWrite` access type was requested.
    ///
    /// This is the refusal that is intrinsic to replay rather than
    /// merely unimplemented.  The recording samples what variables
    /// *were* at each step; it does not record that a value was
    /// *read*.  A read leaves no trace in the data — reading `x`
    /// changes nothing about `x` — so no amount of scanning recovers
    /// it.  `write` is the only access type a value table can answer,
    /// and it answers it as "the value is now different", which is
    /// what a write is observable as.
    AccessTypeNotRecorded = 6203,

    /// 6204 — a `condition` or `hitCondition` was supplied.
    ///
    /// Not intrinsic: source *breakpoints* already carry conditions
    /// (`SourceBreakpoint.condition`, evaluated against the locals at
    /// the matched step).  It is refused here because the value-change
    /// scan has no evaluator wired into it yet, and answering
    /// `verified: true` while silently ignoring the condition is
    /// exactly the class of lie this crate exists to prevent.  A
    /// watchpoint that ignores its condition stops in the wrong place
    /// and the user has no way to know.
    ConditionNotSupported = 6204,

    /// 6205 — the variable name never occurs in this recording.
    ///
    /// Distinct from [`Self::ExpressionNotAWatchableVariable`]: the
    /// `dataId` is a well-formed identifier, it is simply not one this
    /// trace recorded.  Reported separately because the user's fix
    /// differs — a typo, versus watching something the recorder did
    /// not capture.
    VariableNotInTrace = 6205,

    /// 6206 — this replay backend keeps no per-step value table.
    ///
    /// The materialized DB backend records values at every step.  The
    /// MCR/emulator and recreator backends do not — `load_history`
    /// already refuses on those for the same reason ("value history is
    /// not available for MCR traces").  Without that table there is
    /// nothing to compare step-over-step, so the value-change
    /// watchpoint has no substrate.
    BackendLacksValueHistory = 6206,
}

impl DataBreakpointRefusal {
    pub const fn as_u32(self) -> u32 {
        self as u32
    }

    /// A human-readable explanation.  This is for the `message` field
    /// of the DAP response and for the Python API's exception text —
    /// callers branch on [`Self::as_u32`], never on this string.
    pub const fn description(self) -> &'static str {
        match self {
            Self::EmptyDataId => "a watchpoint needs a variable name; the dataId was empty",
            Self::ExpressionNotAWatchableVariable => {
                "a recording indexes values by variable name, so only a plain identifier can be watched — \
                 not a field access, index, dereference or computed expression"
            }
            Self::AccessTypeNotRecorded => {
                "a recording samples what each variable held at each step; it does not record reads, \
                 which leave no trace in the data. Only write (value-change) watchpoints can be answered"
            }
            Self::ConditionNotSupported => {
                "conditional watchpoints are not implemented; the value-change scan has no expression \
                 evaluator wired into it, and honouring the request while ignoring the condition would \
                 stop in the wrong place with nothing to say so"
            }
            Self::VariableNotInTrace => "no variable by that name was recorded in this trace",
            Self::BackendLacksValueHistory => {
                "this replay backend keeps no per-step value table, so there is nothing to compare \
                 step-over-step; value-change watchpoints need a materialized recording"
            }
        }
    }

    /// The stable camelCase token that travels on the wire beside the
    /// code, so a log line or a test failure names the reason rather
    /// than an integer.
    pub const fn token(self) -> &'static str {
        match self {
            Self::EmptyDataId => "emptyDataId",
            Self::ExpressionNotAWatchableVariable => "expressionNotAWatchableVariable",
            Self::AccessTypeNotRecorded => "accessTypeNotRecorded",
            Self::ConditionNotSupported => "conditionNotSupported",
            Self::VariableNotInTrace => "variableNotInTrace",
            Self::BackendLacksValueHistory => "backendLacksValueHistory",
        }
    }
}

impl fmt::Display for DataBreakpointRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.description())
    }
}

/// One entry of a `setDataBreakpoints` request, reduced to the fields
/// the admission rules actually read.
///
/// Deliberately NOT the DAP-generated `dap_types::DataBreakpoint`:
/// this crate is shared with the daemon, which has its own DAP types,
/// and neither side should have to depend on the other's generated
/// bindings to ask the same question.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DataBreakpointRequest {
    /// The DAP `dataId`.  CodeTracer's daemon puts the watched
    /// expression here verbatim (see `handle_py_add_watchpoint`), so
    /// in practice this is the string the user passed to
    /// `Trace.add_watchpoint`.
    pub data_id: String,
    /// DAP `accessType`: `"read"`, `"write"` or `"readWrite"`.  `None`
    /// means the client did not say, which DAP leaves to the adapter;
    /// we read it as `write`, the only kind we can answer.
    pub access_type: Option<String>,
    pub condition: Option<String>,
    pub hit_condition: Option<String>,
}

impl DataBreakpointRequest {
    pub fn new(data_id: impl Into<String>) -> Self {
        DataBreakpointRequest {
            data_id: data_id.into(),
            ..Default::default()
        }
    }

    pub fn with_access_type(mut self, access_type: impl Into<String>) -> Self {
        self.access_type = Some(access_type.into());
        self
    }

    pub fn with_condition(mut self, condition: impl Into<String>) -> Self {
        self.condition = Some(condition.into());
        self
    }

    pub fn with_hit_condition(mut self, hit_condition: impl Into<String>) -> Self {
        self.hit_condition = Some(hit_condition.into());
        self
    }
}

/// An accepted watchpoint: the variable name the backend should watch
/// for a value change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatchedVariable {
    pub name: String,
}

/// What a backend knows about the recording it is holding.
///
/// The two questions here are the ONLY ones the admission rules ask of
/// a backend.  Everything else about the verdict is a property of the
/// request, and is therefore identical for every backend — which is
/// the property that lets a mock and the real thing be held to the
/// same rules.
pub trait TraceVocabulary {
    /// Does this backend keep a per-step table of variable values?
    ///
    /// `true` for the materialized DB backend, `false` for the
    /// MCR/emulator and recreator sessions, which already refuse
    /// `load_history` for this reason.
    fn has_per_step_values(&self) -> bool;

    /// Was a variable of this name recorded anywhere in the trace?
    fn knows_variable(&self, name: &str) -> bool;
}

/// Decide whether a data breakpoint can be honoured.
///
/// This is the single admission rule for watchpoints in CodeTracer.
/// The real replay backend calls it; so does the daemon's mock DAP
/// backend.  If you are adding a caller, call this — do not re-derive
/// the rules, and above all do not answer `verified: true` without
/// asking.
///
/// Order matters and is asserted by the tests: the cheapest and most
/// specific refusals come first, so a request that is wrong in several
/// ways reports the reason a user can act on.
pub fn verdict<V: TraceVocabulary + ?Sized>(
    request: &DataBreakpointRequest,
    vocabulary: &V,
) -> Result<WatchedVariable, DataBreakpointRefusal> {
    let name = request.data_id.trim();
    if name.is_empty() {
        return Err(DataBreakpointRefusal::EmptyDataId);
    }

    // `read` / `readWrite` before the identifier check: a request to
    // watch reads of a perfectly good variable is refused for the
    // access type, which is the thing the user has to change.  A
    // missing `accessType` reads as `write` — DAP leaves the default
    // to the adapter, and `write` is the only kind a value table can
    // answer.
    match request.access_type.as_deref() {
        None | Some("write") => {}
        Some(_) => return Err(DataBreakpointRefusal::AccessTypeNotRecorded),
    }

    if request.condition.is_some() || request.hit_condition.is_some() {
        return Err(DataBreakpointRefusal::ConditionNotSupported);
    }

    if !is_plain_identifier(name) {
        return Err(DataBreakpointRefusal::ExpressionNotAWatchableVariable);
    }

    // Backend-dependent from here down.  Capability before vocabulary:
    // a backend with no value table cannot answer "do you know this
    // name?" meaningfully, so reporting `VariableNotInTrace` from one
    // would be a guess dressed as a fact.
    if !vocabulary.has_per_step_values() {
        return Err(DataBreakpointRefusal::BackendLacksValueHistory);
    }

    if !vocabulary.knows_variable(name) {
        return Err(DataBreakpointRefusal::VariableNotInTrace);
    }

    Ok(WatchedVariable { name: name.to_string() })
}

/// Is `s` a bare variable name?
///
/// Intentionally strict and language-agnostic: leading letter or
/// underscore, then letters, digits or underscores.  Every language
/// CodeTracer records admits at least this much, and admitting more
/// would mean claiming to watch something the value table cannot
/// resolve.  Sigils that some languages allow in identifiers (Ruby's
/// `@x`, Perl's `$x`) are deliberately excluded for now rather than
/// guessed at — a wrong `true` here is a watchpoint that silently
/// never fires.
fn is_plain_identifier(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c.is_alphabetic() || c == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_alphanumeric() || c == '_')
}

/// A vocabulary that knows a fixed set of names.  Used by the daemon's
/// mock DAP backend, and by the parity tests that hold the mock and
/// the real backend to the same table.
#[derive(Debug, Clone, Default)]
pub struct FixedVocabulary {
    pub has_values: bool,
    pub names: Vec<String>,
}

impl FixedVocabulary {
    pub fn new(names: impl IntoIterator<Item = impl Into<String>>) -> Self {
        FixedVocabulary {
            has_values: true,
            names: names.into_iter().map(Into::into).collect(),
        }
    }

    /// A backend that keeps no per-step value table — the MCR /
    /// recreator shape.
    pub fn without_value_history() -> Self {
        FixedVocabulary {
            has_values: false,
            names: Vec::new(),
        }
    }
}

impl TraceVocabulary for FixedVocabulary {
    fn has_per_step_values(&self) -> bool {
        self.has_values
    }

    fn knows_variable(&self, name: &str) -> bool {
        self.names.iter().any(|n| n == name)
    }
}

/// The canonical table of `(request, vocabulary) -> verdict` cases.
///
/// This exists so the real backend's `setDataBreakpoints` arm and the
/// daemon's mock can be driven through the SAME cases from their own
/// test suites, in their own crates, and asserted to agree.  When the
/// mock and the real backend last disagreed, the disagreement was
/// total — the mock accepted everything, the backend accepted nothing
/// — and no test in the tree could see it, because no test compared
/// them.
///
/// Add a case here when you add a rule.  Both suites pick it up.
pub fn conformance_cases() -> Vec<(DataBreakpointRequest, FixedVocabulary, Result<WatchedVariable, DataBreakpointRefusal>)>
{
    let known = || FixedVocabulary::new(["counter", "total", "_tmp", "x2"]);
    let accept = |n: &str| {
        Ok(WatchedVariable {
            name: n.to_string(),
        })
    };
    vec![
        // ── accepted ───────────────────────────────────────────────
        (DataBreakpointRequest::new("counter"), known(), accept("counter")),
        (DataBreakpointRequest::new("_tmp"), known(), accept("_tmp")),
        (DataBreakpointRequest::new("x2"), known(), accept("x2")),
        // surrounding whitespace is trimmed, not refused
        (DataBreakpointRequest::new("  total  "), known(), accept("total")),
        // an explicit `write` is the same as no access type at all
        (
            DataBreakpointRequest::new("counter").with_access_type("write"),
            known(),
            accept("counter"),
        ),
        // ── refused ────────────────────────────────────────────────
        (
            DataBreakpointRequest::new(""),
            known(),
            Err(DataBreakpointRefusal::EmptyDataId),
        ),
        (
            DataBreakpointRequest::new("   "),
            known(),
            Err(DataBreakpointRefusal::EmptyDataId),
        ),
        (
            DataBreakpointRequest::new("counter").with_access_type("read"),
            known(),
            Err(DataBreakpointRefusal::AccessTypeNotRecorded),
        ),
        (
            DataBreakpointRequest::new("counter").with_access_type("readWrite"),
            known(),
            Err(DataBreakpointRefusal::AccessTypeNotRecorded),
        ),
        (
            DataBreakpointRequest::new("counter").with_condition("counter > 3"),
            known(),
            Err(DataBreakpointRefusal::ConditionNotSupported),
        ),
        (
            DataBreakpointRequest::new("counter").with_hit_condition("5"),
            known(),
            Err(DataBreakpointRefusal::ConditionNotSupported),
        ),
        (
            DataBreakpointRequest::new("obj.field"),
            known(),
            Err(DataBreakpointRefusal::ExpressionNotAWatchableVariable),
        ),
        (
            DataBreakpointRequest::new("arr[0]"),
            known(),
            Err(DataBreakpointRefusal::ExpressionNotAWatchableVariable),
        ),
        (
            DataBreakpointRequest::new("*ptr"),
            known(),
            Err(DataBreakpointRefusal::ExpressionNotAWatchableVariable),
        ),
        (
            DataBreakpointRequest::new("counter + 1"),
            known(),
            Err(DataBreakpointRefusal::ExpressionNotAWatchableVariable),
        ),
        (
            DataBreakpointRequest::new("2counter"),
            known(),
            Err(DataBreakpointRefusal::ExpressionNotAWatchableVariable),
        ),
        (
            DataBreakpointRequest::new("nowhere_near_this_trace"),
            known(),
            Err(DataBreakpointRefusal::VariableNotInTrace),
        ),
        (
            DataBreakpointRequest::new("counter"),
            FixedVocabulary::without_value_history(),
            Err(DataBreakpointRefusal::BackendLacksValueHistory),
        ),
        // Ordering: an access-type refusal outranks a bad identifier,
        // because the access type is the thing the user must change
        // before the identifier even matters.
        (
            DataBreakpointRequest::new("obj.field").with_access_type("read"),
            known(),
            Err(DataBreakpointRefusal::AccessTypeNotRecorded),
        ),
        // Ordering: a backend with no value table refuses on the
        // capability, not on the name — it cannot know the name.
        (
            DataBreakpointRequest::new("nowhere_near_this_trace"),
            FixedVocabulary::without_value_history(),
            Err(DataBreakpointRefusal::BackendLacksValueHistory),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_conformance_case_matches_the_shared_verdict() {
        for (request, vocabulary, expected) in conformance_cases() {
            let actual = verdict(&request, &vocabulary);
            assert_eq!(
                actual, expected,
                "shared verdict disagreed with its own conformance table for {request:?}"
            );
        }
    }

    #[test]
    fn refusal_codes_are_distinct_and_in_the_62xx_block() {
        let all = [
            DataBreakpointRefusal::EmptyDataId,
            DataBreakpointRefusal::ExpressionNotAWatchableVariable,
            DataBreakpointRefusal::AccessTypeNotRecorded,
            DataBreakpointRefusal::ConditionNotSupported,
            DataBreakpointRefusal::VariableNotInTrace,
            DataBreakpointRefusal::BackendLacksValueHistory,
        ];
        let mut codes: Vec<u32> = all.iter().map(|r| r.as_u32()).collect();
        let count = codes.len();
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(codes.len(), count, "two refusals share a code");
        for r in all {
            assert!(
                (6201..=6299).contains(&r.as_u32()),
                "{} is outside the 62xx block reserved for data-breakpoint refusals",
                r.token()
            );
        }
    }

    #[test]
    fn the_conformance_table_exercises_every_refusal_variant() {
        // A conformance table that has stopped covering a variant is
        // the failure mode this whole crate exists to prevent: the
        // rule still exists, both sides still claim to implement it,
        // and nothing checks that they agree about it.
        let covered: Vec<DataBreakpointRefusal> = conformance_cases()
            .into_iter()
            .filter_map(|(_, _, outcome)| outcome.err())
            .collect();
        for expected in [
            DataBreakpointRefusal::EmptyDataId,
            DataBreakpointRefusal::ExpressionNotAWatchableVariable,
            DataBreakpointRefusal::AccessTypeNotRecorded,
            DataBreakpointRefusal::ConditionNotSupported,
            DataBreakpointRefusal::VariableNotInTrace,
            DataBreakpointRefusal::BackendLacksValueHistory,
        ] {
            assert!(
                covered.contains(&expected),
                "no conformance case produces {} — the mock and the real backend could \
                 disagree about it without any test noticing",
                expected.token()
            );
        }
    }

    #[test]
    fn the_conformance_table_has_accepted_cases_too() {
        // A table of nothing but refusals would pass against a backend
        // that refuses everything -- which is precisely the state the
        // real backend was in.
        let accepted = conformance_cases()
            .into_iter()
            .filter(|(_, _, outcome)| outcome.is_ok())
            .count();
        assert!(
            accepted >= 3,
            "only {accepted} accepting conformance cases; a table of pure refusals \
             would pass against a backend that implements nothing"
        );
    }

    #[test]
    fn a_read_watchpoint_is_refused_for_the_reason_that_is_intrinsic() {
        // Guards the distinction that matters most in the docs: this
        // one is not "not implemented yet", it is "the recording does
        // not contain the information".
        let r = verdict(
            &DataBreakpointRequest::new("counter").with_access_type("read"),
            &FixedVocabulary::new(["counter"]),
        );
        assert_eq!(r, Err(DataBreakpointRefusal::AccessTypeNotRecorded));
    }

    #[test]
    fn identifier_rules() {
        assert!(is_plain_identifier("x"));
        assert!(is_plain_identifier("_x"));
        assert!(is_plain_identifier("x_1"));
        assert!(!is_plain_identifier(""));
        assert!(!is_plain_identifier("1x"));
        assert!(!is_plain_identifier("a.b"));
        assert!(!is_plain_identifier("a b"));
        assert!(!is_plain_identifier("@x"));
    }
}
