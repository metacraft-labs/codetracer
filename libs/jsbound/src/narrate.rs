//! Narratives: what a visitor did in a boundary session, derived from the
//! boundary log alone, and the decoded
//! records the boundary tools serve (`events`).
//!
//! A narrative needs no replay, so it exists for a session that cannot be
//! replayed too. It is built from the records in `seq` order:
//!
//! * `navigation` entries from `Navigation` records;
//! * `input` entries from `Input` records, each shown by its `label` (the
//!   semantic name the page or its framework declared) and its target;
//!   the value a public field had after the event, or [`SENSITIVE`] for a
//!   sensitive one (a `Scrubbed` record took the place of its value);
//! * `network` entries from each `NetRequest` and the first `NetResponse` of
//!   the same request: method, URL as logged (scrubbed and holed), status;
//! * `error`, `mark`, `refusal` and `gap` entries from those records;
//! * `declassify` entries from `Declassify` records, shown by `fn_id` with
//!   the declassifier's output: "`isValidEmail` false, then true".
//!
//! Every text taken from the log is the recorder's scrubbed form; the
//! sensitive-hole token in it is shown as [`SENSITIVE`]. All of it
//! is still visitor- and page-authored content: a consumer hands it on as
//! data, never as instructions.
//!
//! Each entry carries its `seq` and its recorded `time`, in milliseconds
//! since the Unix epoch, taken from the clock readings the page made (a
//! `Date.now()`, a `new Date()`, or a monotonic reading added to the
//! recorded `performance.timeOrigin`): the first reading in the same task at
//! or after the entry's record (a task runs in an instant, next to the time a
//! person acts), else the last reading before it, else `null`. The log has
//! no other time: a recorder logs what the page reads, not when.
//!
//! A narrative document holds three granularities, so that every consumer
//! reads the same derivation: `full` (one entry per record above, every
//! input event included), `steps` (what a person would call the visitor's
//! steps: pointer and focus noise dropped, a run of keystrokes into one field
//! one `typed` entry, a run of scrolling one `scroll` entry), and `summary`
//! (the session's facts and counts with its navigations, marks, errors,
//! declassifier outputs, refusals and gaps).

use std::collections::{BTreeMap, HashMap};

use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::container::BoundaryRecording;
use crate::decode::DecodedLog;
use crate::record::{BlobRef, Record, HOLE_TOKEN};

/// The version of the narrative document this module writes.
pub const NARRATIVE_VERSION: u32 = 1;

/// What a sensitive value is shown as: a hole token, and a value a
/// `Scrubbed` record stands for.
pub const SENSITIVE: &str = "\u{2039}sensitive\u{203A}";

/// The most `full` entries a narrative keeps; the rest are cut and the
/// section says so (`full_truncated`).
pub const MAX_FULL_ENTRIES: usize = 20_000;

/// The most `steps` entries a narrative keeps (`steps_truncated`).
pub const MAX_STEP_ENTRIES: usize = 5_000;

/// The longest text taken from the log into an entry (a value, a label, a
/// URL, a message), in characters; a longer one is cut and ends with `…`.
pub const MAX_TEXT: usize = 512;

/// The most named keys a `typed` entry lists.
const MAX_NAMED_KEYS: usize = 32;

/// The input event types `steps` keeps as entries of their own.
const STEP_EVENTS: &[&str] = &[
    "click",
    "dblclick",
    "auxclick",
    "contextmenu",
    "submit",
    "reset",
    "visibilitychange",
    "beforeunload",
    "online",
    "offline",
];

/// The input event types a `typed` entry is made of.
const TYPING_EVENTS: &[&str] = &[
    "keydown",
    "keypress",
    "keyup",
    "beforeinput",
    "input",
    "compositionstart",
    "compositionupdate",
    "compositionend",
];

/// The input event types a `scroll` entry is made of.
const SCROLL_EVENTS: &[&str] = &["scroll", "wheel", "touchmove"];

/// One step of the narrative.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Entry {
    /// The `seq` of the record the entry starts at (a `Gap`'s `first_seq`).
    pub seq: u64,
    /// The recorded wall-clock time (see the module documentation).
    pub time: Option<f64>,
    /// What happened.
    #[serde(flatten)]
    pub what: What,
    /// The entry as one line of English.
    pub text: String,
}

/// What an [`Entry`] records.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum What {
    /// The page's URL changed (`Navigation`).
    Navigation {
        /// `pushState`, `replaceState`, `popstate`, `hashchange` or `unload`.
        how: &'static str,
        url: String,
    },
    /// One input event (`Input`).
    Input {
        /// The DOM event type.
        event: String,
        /// The target's semantic label, `null` when it has none.
        label: Option<String>,
        /// The target.
        target: String,
        /// A keyboard event's `key` (masked as recorded at a sensitive field).
        #[serde(skip_serializing_if = "Option::is_none")]
        key: Option<String>,
        /// After an `input` or `change` event, the field's value: as logged
        /// for a public field, [`SENSITIVE`] for a sensitive one, `checked`
        /// or `unchecked` for a checkbox or radio button.
        #[serde(skip_serializing_if = "Option::is_none")]
        value: Option<String>,
    },
    /// A run of keystrokes and text input into one field (`steps` only).
    Typed {
        label: Option<String>,
        target: String,
        /// The printable keystrokes (masked ones included).
        characters: u64,
        /// The named keys pressed (`Enter`, `Tab`, `Backspace`, …), in order.
        named_keys: Vec<String>,
        /// The field's value at the end of the run, as for [`What::Input`].
        #[serde(skip_serializing_if = "Option::is_none")]
        value: Option<String>,
    },
    /// A run of scrolling at one target (`steps` only).
    Scroll {
        label: Option<String>,
        target: String,
        /// How many scroll, wheel and touch-move events the run has.
        events: u64,
    },
    /// A request and its outcome (`NetRequest`, `NetResponse`).
    Network {
        /// `fetch`, `xhr`, `beacon`, `websocket` or `eventsource`.
        api: &'static str,
        method: String,
        url: String,
        /// The response's status, when there is a response.
        status: Option<u16>,
        /// `response`, `network-error`, `abort`, `timeout`, or `pending` when
        /// the log holds no response.
        outcome: &'static str,
        /// The response's `seq`, when there is a response.
        response_seq: Option<u64>,
    },
    /// An uncaught error (`Error`).
    Error {
        /// `error` or `unhandledrejection`.
        error: &'static str,
        /// The message as logged: its template.
        message: String,
        /// Where it was thrown: the first frame's `url:line`, when known.
        source: Option<String>,
    },
    /// A mark the page made (`Mark`): experiment exposures and conversions.
    Mark {
        name: String,
        /// The mark's data, as JSON.
        data: Value,
    },
    /// A declassifier's output (`Declassify`).
    Declassify {
        fn_id: String,
        /// The output, as JSON.
        output: Value,
    },
    /// A feature the recorder refused (`Refusal`).
    Refusal { feature: String, detail: String },
    /// Records that are missing (`Gap`).
    Gap {
        first_seq: u64,
        last_seq: u64,
        /// `client-ring-overflow`, `batch-never-arrived` or `batch-refused`.
        reason: &'static str,
    },
}

/// `text` with every hole token shown as [`SENSITIVE`], whole: how the
/// decoded records ([`events`]) show it, which are never cut.
pub fn unholed(text: &str) -> String {
    text.replace(HOLE_TOKEN, SENSITIVE)
}

/// `text` with every hole token shown as [`SENSITIVE`], cut at
/// [`MAX_TEXT`] characters: how a narrative entry shows it.
pub fn shown(text: &str) -> String {
    let replaced = unholed(text);
    if replaced.chars().count() <= MAX_TEXT {
        return replaced;
    }
    let mut cut: String = replaced.chars().take(MAX_TEXT - 1).collect();
    cut.push('\u{2026}');
    cut
}

/// `value` with every string in it (object keys too) passed through
/// [`shown`].
fn shown_json(value: Value) -> Value {
    map_strings(value, &shown)
}

/// `value` with every string in it (object keys too) passed through `f`.
fn map_strings(value: Value, f: &dyn Fn(&str) -> String) -> Value {
    match value {
        Value::String(s) => Value::String(f(&s)),
        Value::Array(items) => Value::Array(items.into_iter().map(|v| map_strings(v, f)).collect()),
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(k, v)| (f(&k), map_strings(v, f)))
                .collect(),
        ),
        other => other,
    }
}

/// A JSON field of a record as JSON, or as a string when it is not JSON,
/// with its strings [`shown`].
fn json_field(text: &str) -> Value {
    shown_json(serde_json::from_str(text).unwrap_or_else(|_| Value::String(text.to_string())))
}

fn navigation_how(kind: u8) -> &'static str {
    match kind {
        1 => "pushState",
        2 => "replaceState",
        3 => "popstate",
        4 => "hashchange",
        _ => "unload",
    }
}

fn net_api(api: u8) -> &'static str {
    match api {
        1 => "fetch",
        2 => "xhr",
        3 => "beacon",
        4 => "websocket",
        _ => "eventsource",
    }
}

fn net_outcome(outcome: u8) -> &'static str {
    match outcome {
        2 => "network-error",
        3 => "abort",
        4 => "timeout",
        _ => "response",
    }
}

fn gap_reason(reason: u8) -> &'static str {
    match reason {
        1 => "client-ring-overflow",
        2 => "batch-never-arrived",
        _ => "batch-refused",
    }
}

/// `End.reason` as a word.
pub fn end_reason(reason: u8) -> &'static str {
    match reason {
        1 => "pagehide",
        2 => "stopped",
        3 => "idle",
        4 => "session-cap",
        _ => "unknown",
    }
}

/// How an entry names its target: “label”, or the target when unlabelled.
fn named(label: &Option<String>, target: &str) -> String {
    match label {
        Some(l) => format!("\u{201C}{l}\u{201D}"),
        None => target.to_string(),
    }
}

/// The wall-clock times the page read, as the log goes.
#[derive(Default)]
struct Clock {
    /// The last wall-clock time read, in ms since the epoch.
    wall: Option<f64>,
    /// `performance.timeOrigin`, once the page read it.
    origin: Option<f64>,
    /// The first wall-clock time read.
    first: Option<f64>,
}

impl Clock {
    /// Account for a `Clock` record, by its `src` (which clock the page read).
    fn read(&mut self, src: u8, bits: u64) {
        let value = f64::from_bits(bits);
        if !value.is_finite() {
            return;
        }
        let wall = match src {
            // Date.now(), new Date(): the wall clock.
            1 | 3 => Some(value),
            // performance.timeOrigin: the base of the monotonic readings.
            7 => {
                self.origin = Some(value);
                None
            }
            // performance.now(), an animation frame's and an event's
            // timeStamp: monotonic, relative to the time origin.
            2 | 4 | 5 => self.origin.map(|o| o + value),
            // IdleDeadline.timeRemaining() is a duration, not a time.
            _ => None,
        };
        if let Some(w) = wall {
            self.wall = Some(w);
            self.first.get_or_insert(w);
        }
    }
}

/// The `key` of a keyboard event's recorded properties.
fn event_key(props: &str) -> Option<String> {
    serde_json::from_str::<Value>(props)
        .ok()?
        .get("key")?
        .as_str()
        .map(shown)
}

/// The value a `DomEffect` shows: a string as itself, anything else as its
/// JSON; `checked` as `checked`/`unchecked`.
fn effect_value(effect: u8, value: &str) -> Option<String> {
    let parsed: Value = serde_json::from_str(value).ok()?;
    match effect {
        1 => Some(match parsed {
            Value::String(s) => shown(&s),
            other => shown(&other.to_string()),
        }),
        2 => Some(if parsed == Value::Bool(true) {
            "checked".to_string()
        } else {
            "unchecked".to_string()
        }),
        _ => None,
    }
}

/// The wall-clock time of each record of `log`, by index (see the module
/// documentation): the first reading from the record to the end of its task
/// (the next `Task` or `DocTask` record), else the last reading before it.
fn record_times(log: &DecodedLog) -> Vec<Option<f64>> {
    let mut clock = Clock::default();
    // The reading each record is, if it is one, and the last one up to it.
    let mut readings = Vec::with_capacity(log.records.len());
    let mut last = Vec::with_capacity(log.records.len());
    for record in &log.records {
        let before = clock.wall;
        if let Record::Clock { src, bits, .. } = record {
            clock.read(*src, *bits);
        }
        readings.push(if clock.wall != before {
            clock.wall
        } else {
            None
        });
        last.push(clock.wall);
    }
    let mut times = vec![None; log.records.len()];
    let mut ahead: Option<f64> = None;
    for i in (0..log.records.len()).rev() {
        if readings[i].is_some() {
            ahead = readings[i];
        }
        times[i] = ahead.or(last[i]);
        if matches!(log.records[i], Record::Task { .. } | Record::DocTask { .. }) {
            ahead = None;
        }
    }
    times
}

/// Every entry of the `full` granularity, in `seq` order (not cut).
pub fn full_entries(log: &DecodedLog) -> Vec<Entry> {
    let times = record_times(log);
    let mut entries = Vec::new();
    // The value each target showed after its last `DomEffect` or `Scrubbed`.
    let mut values: HashMap<String, String> = HashMap::new();
    // The index of each request's entry, by `req_id`, until its response.
    let mut requests: HashMap<u64, usize> = HashMap::new();
    let entry = |seq: u64, time: Option<f64>, what: What| {
        let text = describe(&what);
        Entry {
            seq,
            time,
            what,
            text,
        }
    };
    for (record, time) in log.records.iter().zip(times) {
        match record {
            Record::DomEffect {
                target,
                effect,
                value,
                ..
            } => {
                if let Some(v) = effect_value(*effect, value) {
                    values.insert(target.clone(), v);
                }
            }
            Record::Scrubbed { target, .. } => {
                values.insert(target.clone(), SENSITIVE.to_string());
            }
            Record::Navigation { seq, kind, url } => entries.push(entry(
                *seq,
                time,
                What::Navigation {
                    how: navigation_how(*kind),
                    url: shown(url),
                },
            )),
            Record::Input {
                seq,
                r#type,
                target,
                props,
                label,
                ..
            } => {
                let keyboard = matches!(r#type.as_str(), "keydown" | "keypress" | "keyup");
                let changes = matches!(r#type.as_str(), "input" | "change");
                entries.push(entry(
                    *seq,
                    time,
                    What::Input {
                        event: r#type.clone(),
                        label: (!label.is_empty()).then(|| shown(label)),
                        target: shown(target),
                        key: if keyboard { event_key(props) } else { None },
                        value: if changes {
                            values.get(target).cloned()
                        } else {
                            None
                        },
                    },
                ));
            }
            Record::NetRequest {
                seq,
                req_id,
                api,
                method,
                url,
                ..
            } => {
                requests.insert(*req_id, entries.len());
                entries.push(entry(
                    *seq,
                    time,
                    What::Network {
                        api: net_api(*api),
                        method: shown(method),
                        url: shown(url),
                        status: None,
                        outcome: "pending",
                        response_seq: None,
                    },
                ));
            }
            Record::NetResponse {
                seq,
                req_id,
                outcome,
                status,
                ..
            } => {
                // The first response of a request completes its entry; a
                // streamed body's later records add nothing to it.
                if let Some(i) = requests.remove(req_id) {
                    if let What::Network {
                        status: s,
                        outcome: o,
                        response_seq,
                        ..
                    } = &mut entries[i].what
                    {
                        *o = net_outcome(*outcome);
                        *s = (*outcome == 1 || *outcome == 5).then_some(*status);
                        *response_seq = Some(*seq);
                    }
                    entries[i].text = describe(&entries[i].what);
                }
            }
            Record::Error {
                seq,
                kind,
                message,
                frames,
            } => entries.push(entry(
                *seq,
                time,
                What::Error {
                    error: if *kind == 2 {
                        "unhandledrejection"
                    } else {
                        "error"
                    },
                    message: shown(message),
                    source: error_source(frames),
                },
            )),
            Record::Mark { seq, name, data } => entries.push(entry(
                *seq,
                time,
                What::Mark {
                    name: shown(name),
                    data: json_field(data),
                },
            )),
            Record::Declassify { seq, fn_id, output } => entries.push(entry(
                *seq,
                time,
                What::Declassify {
                    fn_id: shown(fn_id),
                    output: json_field(output),
                },
            )),
            Record::Refusal {
                seq,
                feature,
                detail,
            } => entries.push(entry(
                *seq,
                time,
                What::Refusal {
                    feature: shown(feature),
                    detail: shown(detail),
                },
            )),
            Record::Gap {
                first_seq,
                last_seq,
                reason,
            } => entries.push(entry(
                *first_seq,
                time,
                What::Gap {
                    first_seq: *first_seq,
                    last_seq: *last_seq,
                    reason: gap_reason(*reason),
                },
            )),
            _ => {}
        }
    }
    entries
}

/// The first frame of an `Error`'s frames (`[{url, line, col, fn}]`) as
/// `url:line`.
fn error_source(frames: &str) -> Option<String> {
    let frames: Value = serde_json::from_str(frames).ok()?;
    let first = frames.as_array()?.first()?;
    let url = first.get("url").and_then(Value::as_str).unwrap_or("");
    if url.is_empty() {
        return None;
    }
    Some(match first.get("line").and_then(Value::as_u64) {
        Some(line) => shown(&format!("{url}:{line}")),
        None => shown(url),
    })
}

/// The entry as one line of English.
fn describe(what: &What) -> String {
    match what {
        What::Navigation { how, url } => format!("{how} to {url}"),
        What::Input {
            event,
            label,
            target,
            key,
            value,
        } => {
            let mut text = match key {
                Some(k) => format!("{event} {k} on {}", named(label, target)),
                None => format!("{event} on {}", named(label, target)),
            };
            if let Some(v) = value {
                text.push_str(&format!(": {v}"));
            }
            text
        }
        What::Typed {
            label,
            target,
            characters,
            named_keys,
            value,
        } => {
            let mut text = format!(
                "typed {characters} character{} into {}",
                if *characters == 1 { "" } else { "s" },
                named(label, target)
            );
            if !named_keys.is_empty() {
                text.push_str(&format!(" (keys: {})", named_keys.join(", ")));
            }
            if let Some(v) = value {
                text.push_str(&format!(": {v}"));
            }
            text
        }
        What::Scroll {
            label,
            target,
            events,
        } => format!("scrolled {} ({events} events)", named(label, target)),
        What::Network {
            api,
            method,
            url,
            status,
            outcome,
            ..
        } => match (status, *outcome) {
            (Some(s), _) => format!("{api} {method} {url} \u{2192} {s}"),
            (None, o) => format!("{api} {method} {url} \u{2192} {o}"),
        },
        What::Error {
            error,
            message,
            source,
        } => match source {
            Some(s) => format!("{error}: {message} at {s}"),
            None => format!("{error}: {message}"),
        },
        What::Mark { name, data } => {
            if data.is_null() {
                format!("mark {name}")
            } else {
                format!("mark {name} {data}")
            }
        }
        What::Declassify { fn_id, output } => format!("{fn_id} \u{2192} {output}"),
        What::Refusal { feature, detail } => format!("refused {feature}: {detail}"),
        What::Gap {
            first_seq,
            last_seq,
            reason,
        } => format!("records {first_seq} to {last_seq} missing ({reason})"),
    }
}

/// An entry of `full` that `steps` drops, keeps, or folds into a run.
enum StepClass {
    Keep,
    Drop,
    Typing,
    Scrolling,
}

fn step_class(entry: &Entry) -> StepClass {
    match &entry.what {
        What::Input { event, .. } => {
            let e = event.as_str();
            if STEP_EVENTS.contains(&e) {
                StepClass::Keep
            } else if TYPING_EVENTS.contains(&e) {
                StepClass::Typing
            } else if SCROLL_EVENTS.contains(&e) {
                StepClass::Scrolling
            } else if e == "change" {
                // A `change` that follows typing into its field joins it (see
                // `steps`); any other (a select, a checkbox) is a step.
                StepClass::Keep
            } else {
                StepClass::Drop
            }
        }
        _ => StepClass::Keep,
    }
}

/// Whether a keyboard event's key is printable (one character, or the
/// masking of one), as opposed to a named key (`Enter`, `Tab`, …).
fn printable(key: &str) -> bool {
    key.chars().count() == 1
}

/// The `steps` granularity from the `full` entries (see the module
/// documentation): kept entries as they are; pointer, focus and other noise
/// dropped; each run of typing into one target (a later `change` at it
/// included) one `typed` entry at the run's first `seq`; each run of
/// scrolling at one target one `scroll` entry.
pub fn step_entries(full: &[Entry]) -> Vec<Entry> {
    let mut steps: Vec<Entry> = Vec::new();
    // The index in `steps` of the open run, and its target.
    let mut open: Option<(usize, String)> = None;
    for entry in full {
        let class = step_class(entry);
        let What::Input {
            event,
            label,
            target,
            key,
            value,
        } = &entry.what
        else {
            open = None;
            steps.push(entry.clone());
            continue;
        };
        let continues = |kind: &str| -> Option<usize> {
            let (i, t) = open.as_ref()?;
            let same_kind = matches!(
                (&steps[*i].what, kind),
                (What::Typed { .. }, "typed") | (What::Scroll { .. }, "scroll")
            );
            (t == target && same_kind).then_some(*i)
        };
        match class {
            StepClass::Drop => {}
            StepClass::Typing => {
                let i = match continues("typed") {
                    Some(i) => i,
                    None => {
                        steps.push(Entry {
                            seq: entry.seq,
                            time: entry.time,
                            what: What::Typed {
                                label: label.clone(),
                                target: target.clone(),
                                characters: 0,
                                named_keys: Vec::new(),
                                value: None,
                            },
                            text: String::new(),
                        });
                        open = Some((steps.len() - 1, target.clone()));
                        steps.len() - 1
                    }
                };
                if let What::Typed {
                    characters,
                    named_keys,
                    value: v,
                    ..
                } = &mut steps[i].what
                {
                    if event == "keydown" {
                        if let Some(k) = key {
                            if printable(k) {
                                *characters += 1;
                            } else if named_keys.len() < MAX_NAMED_KEYS {
                                named_keys.push(k.clone());
                            }
                        }
                    }
                    if value.is_some() {
                        v.clone_from(value);
                    }
                }
                steps[i].text = describe(&steps[i].what);
            }
            StepClass::Scrolling => {
                let i = match continues("scroll") {
                    Some(i) => i,
                    None => {
                        steps.push(Entry {
                            seq: entry.seq,
                            time: entry.time,
                            what: What::Scroll {
                                label: label.clone(),
                                target: target.clone(),
                                events: 0,
                            },
                            text: String::new(),
                        });
                        open = Some((steps.len() - 1, target.clone()));
                        steps.len() - 1
                    }
                };
                if let What::Scroll { events, .. } = &mut steps[i].what {
                    *events += 1;
                }
                steps[i].text = describe(&steps[i].what);
            }
            StepClass::Keep => {
                if event == "change" {
                    if let Some(i) = continues("typed") {
                        if let What::Typed { value: v, .. } = &mut steps[i].what {
                            if value.is_some() {
                                v.clone_from(value);
                            }
                        }
                        steps[i].text = describe(&steps[i].what);
                        continue;
                    }
                }
                open = None;
                steps.push(entry.clone());
            }
        }
    }
    steps
}

/// The kinds `summary` lists.
fn in_summary(entry: &Entry) -> bool {
    matches!(
        entry.what,
        What::Navigation { .. }
            | What::Mark { .. }
            | What::Error { .. }
            | What::Declassify { .. }
            | What::Refusal { .. }
            | What::Gap { .. }
    )
}

/// The facts of the session the narrative is about, read from the log.
#[derive(Debug, Clone, Default)]
struct Facts {
    session_id: String,
    build_hash: String,
    level: u8,
    framework: String,
    url: String,
    arms: Map<String, Value>,
    ua_major: u16,
    first_seq: u64,
    last_seq: u64,
    end: String,
    refusals: u64,
    gaps: u64,
    has_error: bool,
}

fn facts(log: &DecodedLog) -> Facts {
    let mut f = Facts::default();
    for record in &log.records {
        if f.first_seq == 0 {
            f.first_seq = match record {
                Record::Gap { first_seq, .. } => *first_seq,
                other => other.seq().unwrap_or(0),
            };
        }
        match record {
            Record::Header {
                protocol_level,
                framework,
                build_hash,
                session_id,
                ..
            } => {
                f.session_id = session_id.clone();
                f.build_hash = build_hash.clone();
                f.level = *protocol_level;
                f.framework = framework.clone();
            }
            Record::Env {
                ua_major,
                arms,
                url,
                ..
            } => {
                f.ua_major = *ua_major;
                f.url = shown(url);
                if let Ok(Value::Object(map)) = serde_json::from_str::<Value>(arms) {
                    if map.values().all(Value::is_string) {
                        f.arms = map
                            .into_iter()
                            .map(|(k, v)| (shown(&k), shown_json(v)))
                            .collect();
                    }
                }
            }
            Record::Refusal { .. } => f.refusals += 1,
            Record::Gap { .. } => f.gaps += 1,
            Record::Error { .. } => f.has_error = true,
            Record::End { last_seq, reason } => {
                f.last_seq = *last_seq;
                f.end = end_reason(*reason).to_string();
            }
            _ => {}
        }
    }
    f
}

/// How many entries of each kind, and of each input event type.
fn counts(full: &[Entry], log: &DecodedLog) -> Value {
    let mut kinds: BTreeMap<&'static str, u64> = BTreeMap::new();
    let mut events: BTreeMap<String, u64> = BTreeMap::new();
    for e in full {
        let kind = match &e.what {
            What::Navigation { .. } => "navigations",
            What::Input { event, .. } => {
                *events.entry(event.clone()).or_default() += 1;
                "inputs"
            }
            What::Typed { .. } | What::Scroll { .. } => continue,
            What::Network { .. } => "requests",
            What::Error { .. } => "errors",
            What::Mark { .. } => "marks",
            What::Declassify { .. } => "declassifications",
            What::Refusal { .. } => "refusals",
            What::Gap { .. } => "gaps",
        };
        *kinds.entry(kind).or_default() += 1;
    }
    json!({
        "records": log.records.len(),
        "entries": kinds,
        "input_events": events,
    })
}

/// The narrative document of a recording (see the module documentation):
/// the session's facts, `counts`, and the three granularities.
pub fn narrate(recording: &BoundaryRecording) -> Value {
    narrate_log(&recording.log, &recording.meta.recording_id)
}

/// [`narrate`] for a decoded log and the recording id it is filed under.
pub fn narrate_log(log: &DecodedLog, recording_id: &str) -> Value {
    let full = full_entries(log);
    let steps = step_entries(&full);
    let f = facts(log);
    let summary: Vec<&Entry> = full.iter().filter(|e| in_summary(e)).collect();
    let times: Vec<f64> = full.iter().filter_map(|e| e.time).collect();
    let mut clock = Clock::default();
    for record in &log.records {
        if let Record::Clock { src, bits, .. } = record {
            clock.read(*src, *bits);
        }
    }
    let (start, end) = (
        clock.first.or_else(|| times.first().copied()),
        clock.wall.or_else(|| times.last().copied()),
    );
    let declassified: Vec<Value> = full
        .iter()
        .filter_map(|e| match &e.what {
            What::Declassify { fn_id, output } => Some(json!({"fn_id": fn_id, "output": output})),
            _ => None,
        })
        .collect();
    json!({
        "version": NARRATIVE_VERSION,
        "derived_by": concat!("jsbound ", env!("CARGO_PKG_VERSION")),
        "recording_id": recording_id,
        "session_id": f.session_id,
        "build_hash": f.build_hash,
        "protocol_level": f.level,
        "framework": f.framework,
        "url": f.url,
        "arms": f.arms,
        "ua_major": f.ua_major,
        "start_time": start,
        "end_time": end,
        "first_seq": f.first_seq,
        "last_seq": f.last_seq,
        "end": f.end,
        "replayable": f.refusals == 0 && f.gaps == 0,
        "has_error": f.has_error,
        "counts": counts(&full, log),
        "declassified": declassified,
        "summary": summary.iter().take(MAX_STEP_ENTRIES).collect::<Vec<_>>(),
        "summary_truncated": summary.len() > MAX_STEP_ENTRIES,
        "steps": steps.iter().take(MAX_STEP_ENTRIES).collect::<Vec<_>>(),
        "steps_truncated": steps.len() > MAX_STEP_ENTRIES,
        "full": full.iter().take(MAX_FULL_ENTRIES).collect::<Vec<_>>(),
        "full_truncated": full.len() > MAX_FULL_ENTRIES,
    })
}

/// What `events` selects: a `seq` range and record kinds, at most `limit`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventQuery {
    /// The least position served (a record's `seq`; `Header` and `Env` are
    /// at 0, a `Gap` at its `first_seq`, `End` at its `last_seq`).
    pub seq_from: u64,
    /// The greatest position served.
    pub seq_to: u64,
    /// The record kinds served (`Input`, `NetRequest`, …); all when empty.
    pub kinds: Vec<String>,
    /// The most records served.
    pub limit: usize,
}

/// The most records one `events` answer holds.
pub const MAX_EVENTS: usize = 2_000;

/// The largest response body an event shows as text; a longer one shows its
/// length and SHA-256 only.
pub const MAX_EVENT_BODY: usize = 4096;

impl Default for EventQuery {
    fn default() -> Self {
        EventQuery {
            seq_from: 0,
            seq_to: u64::MAX,
            kinds: Vec::new(),
            limit: 500,
        }
    }
}

/// A record's position in the log, for [`EventQuery`].
fn position(record: &Record) -> u64 {
    match record {
        Record::Header { .. } | Record::Env { .. } => 0,
        Record::Gap { first_seq, .. } => *first_seq,
        Record::End { last_seq, .. } => *last_seq,
        other => other.seq().unwrap_or(0),
    }
}

/// A body as an event shows it: UTF-8 text up to [`MAX_EVENT_BODY`] bytes,
/// else its length (and hex for short binary).
fn body_json(blob: &BlobRef, recording: &BoundaryRecording) -> Value {
    let bytes: Option<&[u8]> = match blob {
        BlobRef::Inline(b) => Some(b),
        BlobRef::Ref { sha256, .. } => recording.blobs.get(sha256),
    };
    let len = match blob {
        BlobRef::Inline(b) => b.len() as u64,
        BlobRef::Ref { len, .. } => *len,
    };
    match bytes {
        Some(b) if b.len() <= MAX_EVENT_BODY => match std::str::from_utf8(b) {
            Ok(text) => json!({"len": len, "text": unholed(text)}),
            Err(_) => json!({"len": len, "hex": crate::record::hex(b)}),
        },
        _ => json!({"len": len, "omitted": true}),
    }
}

/// The decoded records `query` selects, in log order, as the boundary
/// tools serve them: each record's canonical JSON (u64 fields as decimal
/// strings, as the shared vectors write them), with every hole token shown
/// as [`SENSITIVE`] and a body shown by [`body_json`]. Unlike a narrative
/// entry's text, nothing is cut: a record is served whole. A `Scrubbed`
/// record already stands for a sensitive value: it is served as it is.
pub fn events(recording: &BoundaryRecording, query: &EventQuery) -> Value {
    let limit = query.limit.clamp(1, MAX_EVENTS);
    let mut out = Vec::new();
    let mut next: Option<u64> = None;
    for record in &recording.log.records {
        let at = position(record);
        if at < query.seq_from || at > query.seq_to {
            continue;
        }
        if !query.kinds.is_empty() && !query.kinds.iter().any(|k| k == record.kind_name()) {
            continue;
        }
        if out.len() == limit {
            next = Some(at);
            break;
        }
        let mut value = record.to_json();
        if let Some(blob) = record.blob() {
            let field = if matches!(record, Record::NetResponse { .. }) {
                "body"
            } else {
                "data"
            };
            value[field] = body_json(blob, recording);
        }
        out.push(map_strings(value, &unholed));
    }
    json!({
        "recording_id": recording.meta.recording_id,
        "seq_from": query.seq_from,
        "seq_to": query.seq_to,
        "events": out,
        "truncated": next.is_some(),
        "next_seq": next,
    })
}
