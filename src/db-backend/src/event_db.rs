use std::cmp::min;
use std::collections::HashMap;
use std::error::Error;

use log::{error, info};
use runtime_tracing::{EventLogKind, StepId, TypeKind};

use crate::task::{
    DbEventKind, ProgramEvent, Stop, StringAndValueTuple, TableData, TableRow, TableUpdate, TraceValues,
    UpdateTableArgs, EVENT_KINDS_COUNT,
};

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

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct SingleTableId(pub usize);

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct IndexInSingleTable(pub usize);

#[derive(Debug, Default, Clone)]
pub struct EventDb {
    pub single_tables: Vec<SingleTable>,
    pub disabled_tables: Vec<SingleTableId>,
    pub global_table: Vec<(StepId, SingleTableId, IndexInSingleTable)>,
    // trace_id => [(name: , value: ..)]
    // trace_id => [index => [multiple expressions with values possibly]]
    // register_(id, from_start, group_of_results);
    // and update eventdb/send updates?
    pub tracepoint_values: HashMap<usize, Vec<Vec<StringAndValueTuple>>>,
    pub tracepoint_errors: HashMap<usize, String>,
    pub visible_rows: Vec<usize>,
    pub selected_kinds: [bool; EVENT_KINDS_COUNT],
    pub trace_list: Vec<SingleTableId>,
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
        }
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
        self.global_table.sort_by_key(|&(step_id, _, _)| step_id)
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

    fn update_single_table(&mut self, kind: DbEventKind, events: &[ProgramEvent], trace_id: usize) {
        if trace_id < self.single_tables.len() {
            self.single_tables[trace_id] = SingleTable {
                kind,
                events: events.to_vec(),
            };
        } else {
            error!(
                "wrong index: single tables len {}, trace_id {}",
                self.single_tables.len(),
                trace_id
            );
        }
    }

    fn insert_in_single_table(&mut self, event: ProgramEvent, trace_id: usize) {
        if self.single_tables.len() <= trace_id {
            self.single_tables
                .resize(trace_id + 1, SingleTable::new(DbEventKind::Trace));
        }
        self.single_tables[trace_id].events.push(event);
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
        }
    }

    pub fn register_tracepoint_results(&mut self, results: &[Stop]) {
        for result in results {
            let table_id = self.make_single_table_id(result.tracepoint_id);
            if !self.trace_list.contains(&table_id) {
                self.trace_list.push(table_id);
            }
            let event = self.convert_stop_to_program_event(result);
            info!("----- WANT TO CHECK THE REGISTERED TRACEPOINT Event {:?}", event);
            self.register_in_global_table(&[event.clone()], table_id);
            // sort global?
            self.insert_in_single_table(event, table_id.0);

            self.tracepoint_values.entry(result.tracepoint_id).or_default();
            self.tracepoint_values
                .entry(result.tracepoint_id)
                .and_modify(|e| e.push(result.locals.clone()));
            info!("----- CHECK THE TRACEPOINT_VALUES {:?}", self.tracepoint_values);
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

    fn get_program_event(&self, table_id: &SingleTableId, event_index: &IndexInSingleTable) -> &ProgramEvent {
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
        if !args.is_trace && args.trace_id == 0 {
            if self.selected_kinds != args.selected_kinds {
                self.selected_kinds = args.selected_kinds;
                self.update_visible();
            }
            // Table update without search
            if args.table_args.search.value.is_empty() {
                let mut start = args.table_args.start;
                if self.single_tables.len() > 0
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
        } else if args.table_args.search.value.is_empty() && args.trace_id < self.single_tables.len() - 1 {
            let table: &SingleTable = &self.single_tables[min(self.single_tables.len() - 1, args.trace_id + 1)];
            let mut trace_locals: Vec<Vec<StringAndValueTuple>> = vec![vec![]];
            if args.table_args.start < table.events.len() {
                for (i, event) in table.events[args.table_args.start..].iter().enumerate() {
                    table_data.push(TableRow::new(event));
                    if let Some(value) = self.tracepoint_values.get(&args.trace_id) {
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
                id: args.trace_id,
                locals: trace_locals,
            };
            trace_values_option = Some(tv);
        } else {
            let mut trace_locals: Vec<Vec<StringAndValueTuple>> = vec![vec![]];
            let mut searched_table: Vec<TableRow> = vec![];
            // Search through all values
            if self.single_tables.len() > args.trace_id + 1 {
                let table: &SingleTable = &self.single_tables[args.trace_id + 1];
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
                    if let Some(value) = self.tracepoint_values.get(&args.trace_id) {
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
                id: args.trace_id,
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
            trace_id: args.trace_id,
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
        for tracepoint_id in tracepoint_id_list {
            self.clear_single_table(SingleTableId(tracepoint_id + 1));
            self.refresh_global();
        }
    }
}
