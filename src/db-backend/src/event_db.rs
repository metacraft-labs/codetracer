use std::cmp::min;
use std::collections::HashMap;
use std::error::Error;

use codetracer_trace_types::{EventLogKind, StepId, TypeKind};
use log::error;

use crate::task::{
    DbEventKind, EVENT_KINDS_COUNT, ProgramEvent, Stop, StringAndValueTuple, TableData, TableRow, TableUpdate,
    TraceValues, UpdateTableArgs,
};

/// M25 (spec §3.2.1.1) — composite key for the source-location index
/// alongside the existing `tracepoint_id` lookup. The marker
/// derivation depends on O(1) lookup of "every firing at this source
/// line" — the same surface benefits every other tracepoint consumer
/// at the same time.
///
/// Kept as a small struct (rather than a tuple) so callers don't
/// have to memorise the field order — the verification test for
/// correlation-marker scenarios looks up firings by `(path, line)`.
#[derive(Debug, Default, Clone, PartialEq, Eq, Hash)]
pub struct TracepointSourceLocation {
    pub path: String,
    pub line: i64,
}

impl TracepointSourceLocation {
    pub fn new(path: impl Into<String>, line: i64) -> Self {
        Self {
            path: path.into(),
            line,
        }
    }
}

/// One indexed firing — the minimum data the M25 marker derivation
/// (and any future source-location-based tracepoint consumer) needs
/// to look up the originating `ProgramEvent` in
/// `EventDb::single_tables`. Kept lean so the index stays cheap to
/// maintain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SourceLocationFiring {
    pub single_table_id: SingleTableId,
    pub index_in_table: IndexInSingleTable,
    pub step_id: StepId,
}

/// The column an event list is ordered by — the event log's header click
/// (the desktop's DataTables `order`, the native front-ends' `ct/event-load`
/// `sortKey`). Every key orders by one field of [`ProgramEvent`]; the
/// recorded order (tick, then event number) breaks ties, so a sort is stable
/// and reproducible.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventOrderKey {
    Tick,
    Index,
    Location,
    Kind,
    Output,
}

impl EventOrderKey {
    /// The key a column name selects: the event log's column titles
    /// (`tick`, `#`, `location`, `kind`, `output` — `EventLogColumn` in the
    /// frontend) and the desktop's dense-table data names
    /// (`directLocationRRTicks`, `rrEventId`, `fullPath`, `kind`, `content`).
    pub fn from_column_name(name: &str) -> Option<EventOrderKey> {
        match name {
            "tick" | "directLocationRRTicks" => Some(EventOrderKey::Tick),
            "#" | "index" | "rrEventId" => Some(EventOrderKey::Index),
            "location" | "fullPath" => Some(EventOrderKey::Location),
            "kind" => Some(EventOrderKey::Kind),
            "output" | "content" => Some(EventOrderKey::Output),
            _ => None,
        }
    }
}

/// How an event list is ordered: a key and a direction. The recorded order
/// is `Tick` ascending — [`EventOrder::is_recorded`] — which every reader
/// already returns without sorting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EventOrder {
    pub key: EventOrderKey,
    pub ascending: bool,
}

impl EventOrder {
    pub fn is_recorded(&self) -> bool {
        self.key == EventOrderKey::Tick && self.ascending
    }
}

fn key_ordering(a: &ProgramEvent, b: &ProgramEvent, key: EventOrderKey) -> std::cmp::Ordering {
    match key {
        EventOrderKey::Tick => a.direct_location_rr_ticks.cmp(&b.direct_location_rr_ticks),
        EventOrderKey::Index => a.rr_event_id.cmp(&b.rr_event_id),
        EventOrderKey::Location => a
            .high_level_path
            .cmp(&b.high_level_path)
            .then(a.high_level_line.cmp(&b.high_level_line)),
        EventOrderKey::Kind => (a.kind as u8).cmp(&(b.kind as u8)),
        EventOrderKey::Output => a.content.cmp(&b.content),
    }
}

/// The positions of `count` events (`event_at(i)` is the i-th, in recorded
/// order) in `order`: the direction applies to the key alone, and events the
/// key cannot tell apart keep their recorded order (tick, then event number)
/// whichever way the column is sorted.
pub fn ordered_event_positions<'a, F>(count: usize, event_at: F, order: EventOrder) -> Vec<usize>
where
    F: Fn(usize) -> &'a ProgramEvent,
{
    let mut positions: Vec<usize> = (0..count).collect();
    if order.is_recorded() {
        return positions;
    }
    positions.sort_by(|&i, &j| {
        let (a, b) = (event_at(i), event_at(j));
        let primary = key_ordering(a, b, order.key);
        let primary = if order.ascending { primary } else { primary.reverse() };
        primary
            .then(a.direct_location_rr_ticks.cmp(&b.direct_location_rr_ticks))
            .then(a.rr_event_id.cmp(&b.rr_event_id))
            .then(i.cmp(&j))
    });
    positions
}

#[derive(Debug, Default, Clone)]
pub struct SingleTable {
    pub kind: DbEventKind,
    pub events: Vec<ProgramEvent>,
}

impl SingleTable {
    pub fn new(kind: DbEventKind) -> SingleTable {
        SingleTable { kind, events: vec![] }
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SingleTableId(pub usize);

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct IndexInSingleTable(pub usize);

#[derive(Debug, Default, Clone)]
pub struct EventDb {
    pub single_tables: Vec<SingleTable>,
    pub disabled_tables: Vec<SingleTableId>,
    pub global_table: Vec<(StepId, SingleTableId, IndexInSingleTable)>,
    // M-REC-4: the historical comment used "trace_id" for what is actually
    // a tracepoint id (the key of `tracepoint_values`).  The recording-id
    // migration reserves "trace_id" for OpenTelemetry W3C TraceContext;
    // here the key is a `tracepoint_id`.
    // tracepoint_id => [(name: , value: ..)]
    // tracepoint_id => [index => [multiple expressions with values possibly]]
    // register_(id, from_start, group_of_results);
    // and update eventdb/send updates?
    pub tracepoint_values: HashMap<usize, Vec<Vec<StringAndValueTuple>>>,
    pub tracepoint_errors: HashMap<usize, String>,
    pub visible_rows: Vec<usize>,
    pub selected_kinds: [bool; EVENT_KINDS_COUNT],
    pub trace_list: Vec<SingleTableId>,
    /// M25 (spec §3.2.1.1) source-location -> firings index. Populated
    /// alongside `tracepoint_values` whenever a tracepoint result is
    /// registered. The marker pairing index (M25 `correlation_index`)
    /// reads this map to derive its view without re-walking
    /// `single_tables`.
    pub firings_by_source_location: HashMap<TracepointSourceLocation, Vec<SourceLocationFiring>>,
}

impl EventDb {
    pub fn new() -> EventDb {
        EventDb {
            single_tables: vec![],
            global_table: vec![],
            disabled_tables: vec![],
            tracepoint_values: HashMap::new(),
            tracepoint_errors: HashMap::new(),
            visible_rows: vec![],
            selected_kinds: [true; EVENT_KINDS_COUNT],
            trace_list: vec![SingleTableId(0)],
            firings_by_source_location: HashMap::new(),
        }
    }

    /// M25 (spec §3.2.1.1) — O(1) lookup of every tracepoint firing
    /// registered at a given `(path, line)` source location. Returns
    /// an empty slice when no firing has been recorded at the
    /// location. The marker pairing index uses this to project the
    /// general tracepoint cache into a `(boundary_id, direction)`
    /// view without re-scanning `single_tables`.
    pub fn lookup_by_source_location(&self, key: &TracepointSourceLocation) -> &[SourceLocationFiring] {
        self.firings_by_source_location
            .get(key)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Resolve a [`SourceLocationFiring`] back to its
    /// [`ProgramEvent`] so the marker derivation can read the
    /// payload metadata. Helper kept here so callers don't have to
    /// memorise the `+ 1` offset between `tracepoint_id` and
    /// `SingleTableId`.
    pub fn program_event_at(&self, firing: &SourceLocationFiring) -> Option<&ProgramEvent> {
        self.single_tables
            .get(firing.single_table_id.0)
            .and_then(|table| table.events.get(firing.index_in_table.0))
    }

    fn process_for_global(
        &self,
        events: &[ProgramEvent],
        single_table_id: SingleTableId,
    ) -> Vec<(StepId, SingleTableId, IndexInSingleTable)> {
        let mut vec: Vec<(StepId, SingleTableId, IndexInSingleTable)> = vec![];
        for (i, event) in events.iter().enumerate() {
            vec.push((
                StepId(event.direct_location_rr_ticks),
                single_table_id,
                IndexInSingleTable(i),
            ))
        }
        vec
    }

    fn sort_global_table(&mut self) {
        self.global_table.sort_by_key(|&(step_id, table_id, event_index)| {
            let record_table_order = if table_id.0 == 0 { 1 } else { 0 };
            (step_id, record_table_order, table_id, event_index)
        })
    }

    pub fn get_trace_length(&mut self, tracepoint_id: usize) -> usize {
        self.single_tables[tracepoint_id + 1].events.len()
    }

    pub fn get_events_count(&mut self) -> usize {
        let mut filtered: usize = 0;
        for (_, table_id, event_index) in self.global_table.iter() {
            let event = self.get_program_event(table_id, event_index);
            if !self.selected_kinds[event.kind as usize] {
                filtered += 1
            }
        }
        self.global_table.len() - filtered
    }

    pub fn add_new_table(&mut self, kind: DbEventKind, events: &[ProgramEvent]) {
        self.single_tables.push(SingleTable {
            kind,
            events: events.to_vec(),
        })
    }

    pub fn replace_record_events(&mut self, events: &[ProgramEvent]) {
        if self.single_tables.is_empty() {
            self.add_new_table(DbEventKind::Record, events);
        } else {
            self.single_tables[0] = SingleTable {
                kind: DbEventKind::Record,
                events: events.to_vec(),
            };
        }
        if !self.trace_list.contains(&SingleTableId(0)) {
            self.trace_list.push(SingleTableId(0));
        }
        self.refresh_global();
    }

    /// Replace the events of an existing event-table slot.
    ///
    /// `event_slot` is an index into `single_tables`.  M-REC-4 renamed the
    /// parameter from `trace_id` to `event_slot` to remove the lexical
    /// clash with the new `recording_id` recording identifier (parent spec
    /// §2's third meaning of "trace_id").
    fn update_single_table(&mut self, kind: DbEventKind, events: &[ProgramEvent], event_slot: usize) {
        if event_slot < self.single_tables.len() {
            self.single_tables[event_slot] = SingleTable {
                kind,
                events: events.to_vec(),
            };
        } else {
            error!(
                "wrong index: single tables len {}, event_slot {}",
                self.single_tables.len(),
                event_slot
            );
        }
    }

    /// Append an event to an event-table slot, growing `single_tables` as
    /// needed.  See [`Self::update_single_table`] for the `event_slot` /
    /// `trace_id` rename context (M-REC-4).
    fn insert_in_single_table(&mut self, event: ProgramEvent, event_slot: usize) {
        if self.single_tables.len() <= event_slot {
            self.single_tables
                .resize(event_slot + 1, SingleTable::new(DbEventKind::Trace));
        }
        self.single_tables[event_slot].events.push(event);
    }

    pub fn refresh_global(&mut self) {
        self.global_table = vec![];
        let tables = self.single_tables.clone();
        for table_id in self.trace_list.iter() {
            if !self.disabled_tables.contains(table_id) {
                let global_events = self.process_for_global(&tables[table_id.0].events, *table_id);
                self.global_table.extend(global_events);
            }
        }
        // for (i, st) in tables.iter().enumerate() {
        //     if !self.disabled_tables.contains(&SingleTableId(i)) {
        //         let global_events = self.process_for_global(&st.events, SingleTableId(i));
        //         self.global_table.extend(global_events);
        //     }
        // }
        self.sort_global_table();
    }

    fn convert_stop_to_program_event(&self, trace: &Stop) -> ProgramEvent {
        let mut res: String = Default::default();
        if trace.error_message.is_empty() {
            for named_value in &trace.locals {
                let name = &named_value.field0;
                let value = &named_value.field1;
                if value.kind != TypeKind::Error {
                    res += &(format!("{}={} ", name, value.text_repr()));
                } else {
                    res += &(format!("{}=<span class=error-trace>{}</span>", name, value.msg));
                }
            }
        } else {
            res += &format!("<span class=error-trace>{}</span>", trace.error_message);
        }
        ProgramEvent {
            kind: EventLogKind::TraceLogEvent,
            semantic_kind: String::new(),
            content: res,
            rr_event_id: trace.event,
            high_level_path: trace.path.to_string(),
            high_level_line: trace.line,
            direct_location_rr_ticks: trace.rr_ticks as i64,
            tracepoint_result_index: trace.tracepoint_id as i64,
            event_index: trace.iteration,
            metadata: "".to_string(),
            bytes: 0,
            stdout: false,
            base64_encoded: false,
            max_rr_ticks: 0,
            source_generation: 0,
            source_digest: String::new(),
        }
    }

    pub fn register_tracepoint_results(&mut self, results: &[Stop]) {
        for result in results {
            let table_id = self.make_single_table_id(result.tracepoint_id);
            if !self.trace_list.contains(&table_id) {
                self.trace_list.push(table_id);
            }
            let event = self.convert_stop_to_program_event(result);
            self.register_in_global_table(std::slice::from_ref(&event), table_id);
            // sort global?
            // M25 §3.2.1.1 — record the firing in the source-location
            // index BEFORE pushing into `single_tables` so we can use
            // the post-push length as the firing's index.
            let location = TracepointSourceLocation::new(event.high_level_path.clone(), event.high_level_line);
            let next_index = self.single_tables.get(table_id.0).map(|t| t.events.len()).unwrap_or(0);
            self.insert_in_single_table(event, table_id.0);
            self.firings_by_source_location
                .entry(location)
                .or_default()
                .push(SourceLocationFiring {
                    single_table_id: table_id,
                    index_in_table: IndexInSingleTable(next_index),
                    step_id: StepId(result.rr_ticks as i64),
                });

            self.tracepoint_values.entry(result.tracepoint_id).or_default();
            self.tracepoint_values
                .entry(result.tracepoint_id)
                .and_modify(|e| e.push(result.locals.clone()));
        }
        self.refresh_global();
        // self.sort_global_table();
    }

    fn register_in_global_table(&mut self, events: &[ProgramEvent], table_id: SingleTableId) {
        let global_events = self.process_for_global(events, table_id);
        self.global_table.extend(global_events);
    }

    pub fn register_events(&mut self, kind: DbEventKind, events: &[ProgramEvent], tracepoint_ids: Vec<i64>) {
        if kind == DbEventKind::Trace {
            for id in tracepoint_ids {
                let table_id = (id + 1) as usize;
                if events.is_empty() {
                    self.update_single_table(kind, events, table_id);
                    return;
                } else {
                    self.register_in_global_table(events, SingleTableId(table_id));
                    self.update_single_table(kind, events, table_id);
                }
            }
        } else {
            self.add_new_table(kind, events);
            self.register_in_global_table(events, SingleTableId(0));
        }
        // for event in events {
        //     info!("metadata {:?}", event.metadata);
        // }
        // info!("self {self:?}");
    }

    pub fn get_program_event(&self, table_id: &SingleTableId, event_index: &IndexInSingleTable) -> &ProgramEvent {
        &self.single_tables[table_id.0].events[event_index.0]
    }

    pub fn make_single_table_id(&self, id: usize) -> SingleTableId {
        SingleTableId(id + 1)
    }

    pub fn disable_table(&mut self, table_id: SingleTableId) {
        self.disabled_tables.push(table_id);
    }

    pub fn enable_table(&mut self, check_id: SingleTableId) {
        self.disabled_tables.retain(|table_id| table_id != &check_id);
    }

    fn update_visible(&mut self) {
        self.visible_rows = vec![];
        for (i, (_, table_id, event_index)) in self.global_table.iter().enumerate() {
            let event = self.get_program_event(table_id, event_index);
            if self.selected_kinds[event.kind as usize] {
                self.visible_rows.push(i);
            }
        }
    }

    pub fn update_table(
        &mut self,
        args: UpdateTableArgs,
    ) -> Result<(TableUpdate, Option<TraceValues>), Box<dyn Error>> {
        let mut table_data: Vec<TableRow> = vec![];
        let event_count: usize;
        let mut trace_values_option: Option<TraceValues> = None;
        // Event log datatable ajax update
        if !args.is_trace && args.event_slot == 0 {
            if self.selected_kinds != args.selected_kinds {
                self.selected_kinds = args.selected_kinds;
                self.update_visible();
            }
            // The header click (DataTables' `order`): the first ordering
            // column, by the data name its column declares. Until this was
            // read the table sent it on every draw and got the recorded
            // order back, so clicking a column header moved its arrow and
            // nothing else.
            let order = args.table_args.order.first().and_then(|o| {
                let name = args.table_args.columns.get(o.column).map(|c| c.data.as_str())?;
                Some(EventOrder {
                    key: EventOrderKey::from_column_name(name)?,
                    ascending: o.dir != "desc",
                })
            });
            if let Some(order) = order.filter(|o| !o.is_recorded()) {
                let matching: Vec<&ProgramEvent> = self
                    .global_table
                    .iter()
                    .map(|(_, table_id, event_index)| self.get_program_event(table_id, event_index))
                    .filter(|event| {
                        args.selected_kinds[event.kind as usize]
                            && (args.table_args.search.value.is_empty()
                                || event.content.contains(&args.table_args.search.value))
                    })
                    .collect();
                let positions = ordered_event_positions(matching.len(), |i| matching[i], order);
                for &i in positions
                    .iter()
                    .skip(args.table_args.start)
                    .take(args.table_args.length)
                {
                    table_data.push(TableRow::new(matching[i]));
                }
                event_count = matching.len();
            } else if args.table_args.search.value.is_empty() {
                let mut start = args.table_args.start;
                if !self.single_tables.is_empty()
                    && self.single_tables[0].events.len() != self.global_table.len()
                    && args.table_args.start != 0
                {
                    start = if self.visible_rows.len() >= args.table_args.start {
                        self.visible_rows[args.table_args.start]
                    } else {
                        args.table_args.start
                    };
                }
                if start < self.global_table.len() {
                    for (_, table_id, event_index) in self.global_table[start..].iter() {
                        let event = self.get_program_event(table_id, event_index);
                        if args.selected_kinds[event.kind as usize] {
                            table_data.push(TableRow::new(event));
                            if table_data.len() >= args.table_args.length {
                                break;
                            };
                        }
                    }
                }
                event_count = self.get_events_count();
            } else {
                let mut searched_table: Vec<TableRow> = vec![];
                // Search through all values
                for (_, table_id, event_index) in self.global_table.iter() {
                    let event = self.get_program_event(table_id, event_index);
                    if args.selected_kinds[event.kind as usize] {
                        match args.table_args.search.value.parse::<i64>() {
                            Ok(search_num) => {
                                if event.content.contains(&args.table_args.search.value)
                                    || event.direct_location_rr_ticks == search_num
                                    || event.rr_event_id == search_num as usize
                                {
                                    searched_table.push(TableRow::new(event));
                                }
                            }
                            Err(_) => {
                                if event.content.contains(&args.table_args.search.value) {
                                    searched_table.push(TableRow::new(event));
                                }
                            }
                        };
                    }
                }
                // Use the searched events to send to virtualization layer
                if args.table_args.start < searched_table.len() {
                    for row in searched_table[args.table_args.start..].iter() {
                        table_data.push(row.clone());
                        if table_data.len() >= args.table_args.length {
                            break;
                        };
                    }
                }
                event_count = searched_table.len();
            }
        // Tracepoint log datatable ajax update
        } else if args.table_args.search.value.is_empty() && args.event_slot < self.single_tables.len() - 1 {
            let table: &SingleTable = &self.single_tables[min(self.single_tables.len() - 1, args.event_slot + 1)];
            let mut trace_locals: Vec<Vec<StringAndValueTuple>> = vec![vec![]];
            if args.table_args.start < table.events.len() {
                for (i, event) in table.events[args.table_args.start..].iter().enumerate() {
                    table_data.push(TableRow::new(event));
                    if let Some(value) = self.tracepoint_values.get(&args.event_slot) {
                        // FIXME(alexander): here we had a crash on `log(0)` after reforms
                        for trace in value[args.table_args.start + i].iter() {
                            while trace_locals.len() <= args.table_args.start + i {
                                trace_locals.push(vec![]);
                            }
                            trace_locals[args.table_args.start + i].push(trace.clone());
                        }
                    }
                    if table_data.len() >= args.table_args.length {
                        break;
                    };
                }
            }
            event_count = table.events.len();
            let tv = TraceValues {
                id: args.event_slot,
                locals: trace_locals,
            };
            trace_values_option = Some(tv);
        } else {
            let mut trace_locals: Vec<Vec<StringAndValueTuple>> = vec![vec![]];
            let mut searched_table: Vec<TableRow> = vec![];
            // Search through all values
            if self.single_tables.len() > args.event_slot + 1 {
                let table: &SingleTable = &self.single_tables[args.event_slot + 1];
                for event in table.events.iter() {
                    match args.table_args.search.value.parse::<i64>() {
                        Ok(search_num) => {
                            if event.content.contains(&args.table_args.search.value)
                                || event.direct_location_rr_ticks == search_num
                            {
                                searched_table.push(TableRow::new(event));
                            }
                        }
                        Err(_) => {
                            if event.content.contains(&args.table_args.search.value) {
                                searched_table.push(TableRow::new(event));
                                // trace_locals.push(values[args.table_args.start + i].clone());
                            }
                        }
                    };
                }
            }
            // Use the searched events to send to virtualization layer
            if args.table_args.start < searched_table.len() {
                for (i, row) in searched_table[args.table_args.start..].iter().enumerate() {
                    table_data.push(row.clone());
                    if let Some(value) = self.tracepoint_values.get(&args.event_slot) {
                        // FIXME(alexander): here we had a crash on `log(0)` after reforms
                        for trace in value[args.table_args.start + i].iter() {
                            if trace_locals.len() <= args.table_args.start + i {
                                trace_locals.push(vec![]);
                            }
                            trace_locals[args.table_args.start + i].push(trace.clone());
                        }
                    }
                    if table_data.len() >= args.table_args.length {
                        break;
                    };
                }
            }
            event_count = searched_table.len();
            let tv = TraceValues {
                id: args.event_slot,
                locals: trace_locals,
            };
            trace_values_option = Some(tv);
        }
        let table_update = TableUpdate {
            data: TableData {
                draw: args.table_args.draw,
                records_total: event_count,
                records_filtered: event_count,
                data: table_data,
            },
            is_trace: args.is_trace,
            event_slot: args.event_slot,
        };
        Ok((table_update, trace_values_option))
    }

    pub fn register_tracepoint_values(&mut self, tracepoint_id: usize, locals: Vec<Vec<StringAndValueTuple>>) {
        let table_id = self.make_single_table_id(tracepoint_id);
        if !self.trace_list.contains(&table_id) {
            self.trace_list.push(table_id);
        }
        self.tracepoint_values.insert(tracepoint_id, locals.clone());
    }

    pub fn clear_single_table(&mut self, single_table_id: SingleTableId) {
        self.single_tables[single_table_id.0].events = vec![];
    }

    pub fn reset_tracepoint_data(&mut self, tracepoint_id_list: &[usize]) {
        self.tracepoint_values = HashMap::new();
        self.tracepoint_errors = HashMap::new();
        // M25 §3.2.1.1 — the source-location index must drop firings
        // for any tracepoint being reset, otherwise stale entries
        // would surface on the next correlation lookup.
        let cleared_table_ids: std::collections::HashSet<SingleTableId> =
            tracepoint_id_list.iter().map(|id| SingleTableId(id + 1)).collect();
        self.firings_by_source_location.retain(|_, firings| {
            firings.retain(|f| !cleared_table_ids.contains(&f.single_table_id));
            !firings.is_empty()
        });
        for tracepoint_id in tracepoint_id_list {
            self.clear_single_table(SingleTableId(tracepoint_id + 1));
            self.refresh_global();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task::{SearchValue, StopType, TableArgs, UpdateTableArgs};

    fn event(kind: EventLogKind, content: &str, rr_ticks: i64, rr_event_id: usize) -> ProgramEvent {
        ProgramEvent {
            kind,
            content: content.to_string(),
            rr_event_id,
            high_level_path: "src/main.nr".to_string(),
            high_level_line: 42,
            direct_location_rr_ticks: rr_ticks,
            ..ProgramEvent::default()
        }
    }

    fn table_args() -> UpdateTableArgs {
        UpdateTableArgs {
            table_args: TableArgs {
                draw: 1,
                length: 10,
                search: SearchValue {
                    value: String::new(),
                    regex: false,
                },
                ..TableArgs::default()
            },
            selected_kinds: [true; EVENT_KINDS_COUNT],
            is_trace: false,
            event_slot: 0,
        }
    }

    #[test]
    fn global_event_log_orders_tracepoint_rows_before_record_rows_on_same_rr_tick()
    -> Result<(), Box<dyn std::error::Error>> {
        let mut db = EventDb::new();

        db.replace_record_events(&[event(EventLogKind::Write, "recorded write", 1, 10)]);
        db.register_tracepoint_results(&[Stop::new(
            "src/main.nr".to_string(),
            42,
            vec![],
            1,
            0,
            0,
            StopType::Trace,
        )]);

        let (update, _) = db.update_table(table_args())?;
        let rows = update.data.data;

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].kind, EventLogKind::TraceLogEvent);
        assert_eq!(rows[0].direct_location_rr_ticks, 1);
        assert_eq!(rows[1].kind, EventLogKind::Write);
        assert_eq!(rows[1].content, "recorded write");
        assert_eq!(rows[1].direct_location_rr_ticks, 1);
        Ok(())
    }
}

#[cfg(test)]
mod event_order_tests {
    //! PLAT-50 — the event log's order (its header click): the key, the
    //! direction applied to the key alone, the recorded order as the tie
    //! break whichever way, and the recorded order untouched by its own key.
    use super::*;

    fn event(ticks: i64, id: usize, content: &str, line: i64) -> ProgramEvent {
        ProgramEvent {
            direct_location_rr_ticks: ticks,
            rr_event_id: id,
            content: content.to_string(),
            high_level_path: "/p/main.py".to_string(),
            high_level_line: line,
            ..Default::default()
        }
    }

    fn order(key: EventOrderKey, ascending: bool) -> EventOrder {
        EventOrder { key, ascending }
    }

    #[test]
    fn a_column_orders_the_log_and_ties_keep_the_recorded_order() {
        let events = [
            event(38, 0, "2 + 3 = 5", 111),
            event(68, 1, "10 - 4 + 1 = 7", 111),
            event(88, 2, "6 * 7 = 42", 111),
            event(170, 3, "checksum = 73", 118),
            event(90, 4, "6 * 7 = 42", 111),
        ];
        let at = |i: usize| &events[i];
        // The recorded order is the identity, without sorting.
        assert!(order(EventOrderKey::Tick, true).is_recorded());
        assert_eq!(
            ordered_event_positions(events.len(), at, order(EventOrderKey::Tick, true)),
            vec![0, 1, 2, 3, 4]
        );
        // By output, ascending: the two equal outputs keep their recorded order.
        assert_eq!(
            ordered_event_positions(events.len(), at, order(EventOrderKey::Output, true)),
            vec![1, 0, 2, 4, 3]
        );
        // Descending reverses the KEY only: the equal pair is still 2 then 4.
        assert_eq!(
            ordered_event_positions(events.len(), at, order(EventOrderKey::Output, false)),
            vec![3, 2, 4, 0, 1]
        );
        // The tick column clicked: the recorded order reversed.
        assert_eq!(
            ordered_event_positions(events.len(), at, order(EventOrderKey::Tick, false)),
            vec![3, 4, 2, 1, 0]
        );
        // By location: the line, then the recorded order.
        assert_eq!(
            ordered_event_positions(events.len(), at, order(EventOrderKey::Location, false)),
            vec![3, 0, 1, 2, 4]
        );
    }

    #[test]
    fn column_names_select_their_keys() {
        for (name, key) in [
            ("tick", EventOrderKey::Tick),
            ("directLocationRRTicks", EventOrderKey::Tick),
            ("#", EventOrderKey::Index),
            ("rrEventId", EventOrderKey::Index),
            ("location", EventOrderKey::Location),
            ("fullPath", EventOrderKey::Location),
            ("kind", EventOrderKey::Kind),
            ("output", EventOrderKey::Output),
            ("content", EventOrderKey::Output),
        ] {
            assert_eq!(EventOrderKey::from_column_name(name), Some(key), "{name}");
        }
        assert_eq!(EventOrderKey::from_column_name("nonsense"), None);
    }
}
