//! The locals budget, applied: how many collection elements one
//! `ct/load-locals` answer carries, and the slices a client asks for after it.
//!
//! `ct/load-locals` has always carried `countBudget` and `minCountLimit`
//! (UI-Data-Loading-Guidelines Pattern 3), and until this module no backend
//! read them: every collection arrived whole and the State pane's "Load
//! More" had nothing to load. Here:
//!
//! - [`apply_count_budget`] cuts each collection of an answer to its share of
//!   the budget and records its full length in `elementsTotal` (not
//!   `partiallyExpanded`, which says the RECORDING is incomplete). Every collection keeps at least `min_count_limit`
//!   elements (or all of them, if it has fewer), whatever the budget; beyond
//!   that, collections are served in the order a reader meets them —
//!   breadth-first over the locals — until the budget is spent.
//! - [`elements_slice`] answers `ct/load-value-elements`: elements
//!   `start ..< start + count` of the collection at a path, out of the
//!   untruncated answer the handler kept for the stop.
//!
//! Only the elements of a collection are cut — `Seq`, `Slice`, `Array`,
//! `Varargs`, the sets and tables. The fields of a struct, a tuple or a
//! variant are never dropped: a struct with half its fields is not a smaller
//! struct, it is a wrong one.

use std::collections::VecDeque;

use codetracer_trace_types::TypeKind;

use crate::value::Value;

/// Whether a value of `kind` is a collection whose `elements` are elements
/// (and may be cut), rather than fields.
pub fn is_collection(kind: TypeKind) -> bool {
    matches!(
        kind,
        TypeKind::Seq
            | TypeKind::Slice
            | TypeKind::Array
            | TypeKind::Varargs
            | TypeKind::Set
            | TypeKind::HashSet
            | TypeKind::OrderedSet
            | TypeKind::TableKind
    )
}

/// Whether `value` or anything in it is a collection cut short: its
/// `elements` hold fewer than its `elements_total`.
pub fn is_cut(value: &Value) -> bool {
    (is_collection(value.kind) && value.elements_total > value.elements.len())
        || value.elements.iter().any(is_cut)
        || value.ref_value.as_deref().is_some_and(is_cut)
        || value.active_variant_value.as_deref().is_some_and(is_cut)
}

/// Cut the collections of `values` to `count_budget` elements in total,
/// keeping at least `min_count_limit` in each. A budget of 0 or less means
/// "no budget": nothing is cut. Returns how many elements were dropped.
pub fn apply_count_budget(values: &mut [&mut Value], count_budget: i64, min_count_limit: i64) -> usize {
    if count_budget <= 0 {
        return 0;
    }
    let floor = min_count_limit.max(0) as usize;
    let mut remaining = count_budget as usize;
    let mut dropped = 0usize;
    // Breadth-first: a reader meets every local before any local's members,
    // so the budget goes to what is visible first.
    let mut queue: VecDeque<&mut Value> = values.iter_mut().map(|v| &mut **v).collect();
    while let Some(value) = queue.pop_front() {
        if is_collection(value.kind) {
            let len = value.elements.len();
            let keep = len.min(floor.max(remaining));
            if keep < len {
                value.elements.truncate(keep);
                // A collection the worker already cut keeps the true length
                // it said (`ValueRecordWithType::Sequence::len`).
                value.elements_total = value.elements_total.max(len);
                dropped += len - keep;
            }
            remaining = remaining.saturating_sub(keep);
        }
        for child in value.elements.iter_mut() {
            queue.push_back(child);
        }
        if let Some(r) = value.ref_value.as_deref_mut() {
            queue.push_back(r);
        }
        if let Some(v) = value.active_variant_value.as_deref_mut() {
            queue.push_back(v);
        }
    }
    dropped
}

/// Why a slice could not be answered.
#[derive(Debug, PartialEq, Eq)]
pub enum SliceError {
    /// No local (or watch) of that name in the stop's answer.
    UnknownExpression,
    /// The path leaves the value: an index past a value's elements.
    PathOutOfRange,
    /// The value at the path is not a collection.
    NotACollection,
}

/// One slice of a collection: its elements, where they start, and whether
/// more remain after them.
#[derive(Debug, PartialEq)]
pub struct ElementsSlice {
    pub elements: Vec<Value>,
    pub start_index: usize,
    pub total: usize,
    pub more: bool,
}

/// Elements `start .. start + count` of the collection reached from `root` by
/// `path` (element indices, outermost first; a pointer or reference is
/// followed without an index). A `count` of 0 means "the rest".
pub fn elements_slice(root: &Value, path: &[usize], start: usize, count: usize) -> Result<ElementsSlice, SliceError> {
    let mut value = root;
    for &i in path {
        value = deref(value);
        value = value.elements.get(i).ok_or(SliceError::PathOutOfRange)?;
    }
    let value = deref(value);
    if !is_collection(value.kind) {
        return Err(SliceError::NotACollection);
    }
    let total = value.elements.len();
    let begin = start.min(total);
    let end = if count == 0 {
        total
    } else {
        begin.saturating_add(count).min(total)
    };
    Ok(ElementsSlice {
        elements: value.elements[begin..end].to_vec(),
        start_index: begin,
        total,
        more: end < total,
    })
}

fn deref(mut value: &Value) -> &Value {
    while !is_collection(value.kind) {
        match value.ref_value.as_deref() {
            Some(r) => value = r,
            None => break,
        }
    }
    value
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use crate::value::Type;

    fn int(i: i64) -> Value {
        let mut v = Value::new(TypeKind::Int, Type::new(TypeKind::Int, "int"));
        v.i = i.to_string();
        v
    }

    fn seq(n: i64) -> Value {
        let mut v = Value::new(TypeKind::Seq, Type::new(TypeKind::Seq, "seq[int]"));
        v.elements = (0..n).map(int).collect();
        v
    }

    fn strukt(fields: Vec<Value>) -> Value {
        let mut v = Value::new(TypeKind::Struct, Type::new(TypeKind::Struct, "S"));
        v.elements = fields;
        v
    }

    #[test]
    fn no_budget_cuts_nothing() {
        let mut a = seq(5000);
        assert_eq!(apply_count_budget(&mut [&mut a], 0, 50), 0);
        assert_eq!(a.elements.len(), 5000);
        assert_eq!(a.elements_total, 0);
    }

    #[test]
    fn a_collection_within_the_budget_is_whole() {
        let mut a = seq(10);
        apply_count_budget(&mut [&mut a], 100, 5);
        assert_eq!(a.elements.len(), 10);
        assert_eq!(a.elements_total, 0);
        assert_eq!(a.elements_total, 0);
    }

    #[test]
    fn a_long_collection_is_cut_and_says_how_long_it_is() {
        let mut a = seq(5000);
        let dropped = apply_count_budget(&mut [&mut a], 3000, 50);
        assert_eq!(a.elements.len(), 3000);
        assert_eq!(a.elements_total, 5000);
        assert_eq!(dropped, 2000);
    }

    #[test]
    fn every_collection_keeps_its_floor_after_the_budget_is_spent() {
        let mut a = seq(100);
        let mut b = seq(100);
        apply_count_budget(&mut [&mut a, &mut b], 100, 30);
        assert_eq!(a.elements.len(), 100);
        assert_eq!(b.elements.len(), 30);
        assert_eq!(b.elements_total, 100);
    }

    #[test]
    fn struct_fields_are_never_cut() {
        let mut s = strukt((0..80).map(int).collect());
        apply_count_budget(&mut [&mut s], 10, 0);
        assert_eq!(s.elements.len(), 80);
        assert_eq!(s.elements_total, 0);
    }

    #[test]
    fn nested_collections_share_the_budget_breadth_first() {
        // An outer list of 3 inner lists of 40: the outer's 3 come first.
        let mut outer = Value::new(TypeKind::Seq, Type::new(TypeKind::Seq, "seq[seq[int]]"));
        outer.elements = vec![seq(40), seq(40), seq(40)];
        apply_count_budget(&mut [&mut outer], 50, 10);
        assert_eq!(outer.elements.len(), 3);
        assert_eq!(outer.elements[0].elements.len(), 40);
        // 50 - 3 - 40 = 7 left, below the floor of 10: each later list gets 10.
        assert_eq!(outer.elements[1].elements.len(), 10);
        assert_eq!(outer.elements[2].elements.len(), 10);
        assert_eq!(outer.elements[2].elements_total, 40);
    }

    #[test]
    fn a_slice_continues_where_the_answer_stopped() {
        let full = seq(120);
        let s = elements_slice(&full, &[], 50, 50).unwrap();
        assert_eq!(s.start_index, 50);
        assert_eq!(s.elements.len(), 50);
        assert_eq!(s.elements[0].i, "50");
        assert_eq!(s.total, 120);
        assert!(s.more);
        let last = elements_slice(&full, &[], 100, 50).unwrap();
        assert_eq!(last.elements.len(), 20);
        assert!(!last.more);
        let rest = elements_slice(&full, &[], 60, 0).unwrap();
        assert_eq!(rest.elements.len(), 60);
        assert!(!rest.more);
    }

    #[test]
    fn a_slice_follows_a_path_into_nested_collections() {
        let mut outer = Value::new(TypeKind::Seq, Type::new(TypeKind::Seq, "seq[seq[int]]"));
        outer.elements = vec![seq(3), seq(90)];
        let s = elements_slice(&outer, &[1], 80, 50).unwrap();
        assert_eq!(s.elements.len(), 10);
        assert_eq!(s.elements[0].i, "80");
    }

    #[test]
    fn a_slice_refuses_what_it_cannot_answer() {
        let full = seq(3);
        assert_eq!(elements_slice(&full, &[7], 0, 1), Err(SliceError::PathOutOfRange));
        assert_eq!(elements_slice(&int(1), &[], 0, 1), Err(SliceError::NotACollection));
    }

    #[test]
    fn a_kept_flow_value_comes_back_whole_and_identical_values_are_stored_once() {
        let mut kept = HeldBackValues::default();
        assert!(kept.is_empty());
        let whole = seq(300);
        kept.keep(7, false, "xs", &whole);
        kept.keep(6, true, "xs", &whole); // the previous step's after value
        assert_eq!(kept.whole(7, false, "xs"), Some(whole.clone()));
        assert_eq!(kept.whole(6, true, "xs"), Some(whole.clone()));
        assert_eq!(kept.whole(7, true, "xs"), None, "the side is part of the key");
        assert_eq!(kept.whole(7, false, "ys"), None);
        let once = kept.stored_bytes();
        let json = serde_json::to_vec(&whole).unwrap().len();
        assert!(
            once <= json,
            "stored once (and compressed natively): {once} of {json} bytes"
        );

        let mut other = HeldBackValues::default();
        other.keep(9, false, "ys", &seq(20));
        kept.absorb(other);
        assert_eq!(kept.whole(9, false, "ys"), Some(seq(20)));

        // A slice of the kept value continues a preview.
        let slice = elements_slice(&kept.whole(7, false, "xs").unwrap(), &[], 16, 0).unwrap();
        assert_eq!(
            (slice.start_index, slice.elements.len(), slice.total, slice.more),
            (16, 284, 300, false)
        );
    }
}

/// The whole values behind the previews a flow sent: for each value the
/// flow's budget cut (`flow_preloader::flow_ct_value`), the uncut value, kept
/// so `ct/load-flow-value-elements` can continue the preview from the popup.
///
/// A value cannot be read again by seeking a replay to the step's tick,
/// because consecutive steps of an rr recording share a tick (a loop's passes
/// start `481, 481, 482, …`), so a seek can land on another pass. So either
/// the value is kept, or the step's exact stop is:
///
/// * a replay that names its stops exactly (`ReplaySession::load_stop_position`:
///   rr's event, ticks, PC and registers; MCR's geid and instruction count)
///   gets the stop's position (`positions`), and the value is loaded whole
///   there when the popup asks. The flow then loads only the preview.
/// * any other gets the uncut value, stored once by its content (a flow's
///   after value is usually the next step's before value) and, natively,
///   compressed.
#[derive(Debug, Default, Clone)]
pub struct HeldBackValues {
    keys: std::collections::HashMap<(i64, bool, String), u64>,
    blobs: std::collections::HashMap<u64, StoredValue>,
    positions: std::collections::HashMap<(i64, bool, String), crate::task::Location>,
}

#[derive(Debug, Clone)]
struct StoredValue {
    compressed: bool,
    bytes: Vec<u8>,
}

impl HeldBackValues {
    /// Keep `whole`, the uncut value of `expression` at the flow step
    /// `step_count` (its after value when `after`).
    pub fn keep(&mut self, step_count: i64, after: bool, expression: &str, whole: &Value) {
        let Ok(json) = serde_json::to_vec(whole) else {
            return;
        };
        let id = content_id(&json);
        self.blobs.entry(id).or_insert_with(|| pack(json));
        self.keys.insert((step_count, after, expression.to_string()), id);
    }

    /// The uncut value of `expression` at `step_count`, if the flow cut it.
    /// Keep the exact stop at which `expression`'s value on `step_count` can
    /// be loaded whole: the stop's location, its `replay_position` set, as a
    /// `JumpToCall` returns to it.
    pub fn keep_position(&mut self, step_count: i64, after: bool, expression: &str, stop: &crate::task::Location) {
        self.positions
            .insert((step_count, after, expression.to_string()), stop.clone());
    }

    /// The stop kept by `keep_position`.
    pub fn position(&self, step_count: i64, after: bool, expression: &str) -> Option<&crate::task::Location> {
        self.positions.get(&(step_count, after, expression.to_string()))
    }

    pub fn whole(&self, step_count: i64, after: bool, expression: &str) -> Option<Value> {
        let id = self.keys.get(&(step_count, after, expression.to_string()))?;
        let stored = self.blobs.get(id)?;
        let json = unpack(stored)?;
        serde_json::from_slice(&json).ok()
    }

    /// Add `other`'s values to these.
    pub fn absorb(&mut self, other: HeldBackValues) {
        self.blobs.extend(other.blobs);
        self.keys.extend(other.keys);
        self.positions.extend(other.positions);
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty() && self.positions.is_empty()
    }

    /// The bytes the kept values occupy.
    pub fn stored_bytes(&self) -> usize {
        self.blobs.values().map(|b| b.bytes.len()).sum()
    }
}

fn content_id(json: &[u8]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    json.len().hash(&mut hasher);
    json.hash(&mut hasher);
    hasher.finish()
}

#[cfg(not(target_arch = "wasm32"))]
fn pack(json: Vec<u8>) -> StoredValue {
    match zstd::encode_all(json.as_slice(), 3) {
        Ok(bytes) => StoredValue {
            compressed: true,
            bytes,
        },
        Err(_) => StoredValue {
            compressed: false,
            bytes: json,
        },
    }
}

#[cfg(target_arch = "wasm32")]
fn pack(json: Vec<u8>) -> StoredValue {
    // The wasm build has a zstd decoder (`ruzstd`) but no encoder.
    StoredValue {
        compressed: false,
        bytes: json,
    }
}

fn unpack(stored: &StoredValue) -> Option<Vec<u8>> {
    if !stored.compressed {
        return Some(stored.bytes.clone());
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        zstd::decode_all(stored.bytes.as_slice()).ok()
    }
    #[cfg(target_arch = "wasm32")]
    {
        None
    }
}
