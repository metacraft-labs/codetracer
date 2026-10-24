//! Real CTFS writers and readers exercise reload annotations in the execution
//! index space. No mocks: the fixture has leading, consecutive and trailing
//! markers, and ct-print independently identifies every source step.
#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

mod test_harness;

use codetracer_trace_types::{EventLogKind, Line, StepId, TypeKind, ValueRecord};
use codetracer_trace_writer::{
    ctfs_writer::CtfsTraceWriter, step_stream::SourceReloadChange, trace_writer::TraceWriter,
};
use db_backend::{
    ctfs_trace_reader::CTFSTraceReader, db::MaterializedReplaySession, in_memory_trace_reader::InMemoryTraceReader,
    replay::ReplaySession, task::Action, trace_reader::TraceReader,
};
use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
    process::Command,
    sync::Arc,
};

fn fixture(dir: &Path, column_aware: bool) -> PathBuf {
    let path = dir.join(if column_aware { "columns" } else { "reloads" });
    let mut writer = CtfsTraceWriter::new("reloads", &[]);
    if column_aware {
        writer.enable_column_aware_steps();
    } else {
        writer.enable_line_count_table().unwrap();
    }
    writer.begin_writing_trace_events(&path).unwrap();
    writer.declare_source_reload().unwrap();
    // The column writer's public API registers new path IDs for distinct
    // files; the reload tag has the same semantics for those transitions.
    let source_at = |generation| {
        PathBuf::from(if column_aware {
            format!("/test/reloads_v{generation}.py")
        } else {
            "/test/reloads.py".to_string()
        })
    };
    let register = |writer: &mut CtfsTraceWriter, source: &Path| {
        if column_aware {
            writer.register_path_with_line_lengths(source, &[40; 100])
        } else {
            writer.register_path_version(source, 100).unwrap()
        }
    };
    let mut source = source_at(1);
    let mut old = register(&mut writer, &source);
    let mut generation = 1;
    let mut reload = |writer: &mut CtfsTraceWriter| {
        generation += 1;
        let source = source_at(generation);
        let new = register(writer, &source);
        writer
            .register_source_reload(
                &[SourceReloadChange {
                    old_path_id: old.0 as u64,
                    new_path_id: new.0 as u64,
                    generation,
                }],
                0,
            )
            .unwrap();
        old = new;
        source
    };
    source = reload(&mut writer);
    writer.register_special_event(EventLogKind::Write, "", "before entry\n");
    writer.start(&source, Line(1));
    let ty = writer.ensure_type_id(TypeKind::Int, "int");
    for _ in 0..2 {
        writer.register_step(&source, Line(10));
        writer.register_variable_with_full_value("value", ValueRecord::Int { i: 10, type_id: ty });
    }
    let _ = reload(&mut writer);
    source = reload(&mut writer);
    writer.register_step(&source, Line(20));
    writer.register_variable_with_full_value("value", ValueRecord::Int { i: 20, type_id: ty });
    let _ = reload(&mut writer);
    writer.register_special_event(EventLogKind::Write, "", "after last step\n");
    writer.finish_writing_trace_events().unwrap();
    path.with_extension("ct")
}

/// Every source step and every reload marker, as `ct-print` reads them: the
/// independent reader (not the db-backend's) the assertions are checked
/// against. `test_harness::find_ct_print` builds or refreshes the workspace's
/// codetracer-trace-format-nim/ct-print, or takes `CODETRACER_CT_PRINT`, and
/// panics naming the sibling when it can do neither.
fn independent_indices(path: &Path) -> (BTreeSet<StepId>, BTreeSet<StepId>) {
    let binary = test_harness::find_ct_print();
    let output = Command::new(&binary)
        .arg("--events")
        .arg(path)
        .output()
        .unwrap_or_else(|e| panic!("could not run {}: {e}", binary.display()));
    assert!(
        output.status.success(),
        "ct-print: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let rows: Vec<serde_json::Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let counts = &rows[0]["counts"];
    assert_eq!(
        rows.len() as u64,
        1 + counts["steps"].as_u64().unwrap()
            + 2 * counts["calls"].as_u64().unwrap()
            + counts["io_events"].as_u64().unwrap()
            + counts["source_reloads"].as_u64().unwrap()
    );
    let indices = |kind| {
        rows.iter()
            .filter(|row| row["kind"] == kind)
            .map(|row| StepId(row["step_index"].as_i64().unwrap()))
            .collect()
    };
    (indices("step"), indices("source_reload"))
}

fn assert_view(
    reader: Arc<dyn TraceReader>,
    expected: &BTreeSet<StepId>,
    markers: &BTreeSet<StepId>,
    check_values: bool,
) {
    let actual: BTreeSet<_> = (0..reader.step_count())
        .map(|i| StepId(i as i64))
        .filter(|id| reader.step(*id).is_some())
        .collect();
    assert_eq!(
        &actual, expected,
        "source step IDs stay unchanged, and every annotation is absent"
    );
    assert!(markers.iter().all(|id| reader.step(*id).is_none()));
    assert_eq!(
        reader
            .steps_from(StepId(0))
            .iter()
            .map(|step| step.step_id)
            .collect::<BTreeSet<_>>(),
        *expected
    );
    for id in expected {
        let mut forward = Vec::new();
        reader.scan_steps_from(*id, true, &mut |step| {
            forward.push(step.step_id);
            true
        });
        assert_eq!(
            forward,
            expected.iter().copied().filter(|next| next > id).collect::<Vec<_>>()
        );
        let mut backward = Vec::new();
        reader.scan_steps_from(*id, false, &mut |step| {
            backward.push(step.step_id);
            true
        });
        assert_eq!(
            backward,
            expected
                .iter()
                .rev()
                .copied()
                .filter(|next| next < id)
                .collect::<Vec<_>>()
        );
        let step = reader.step(*id).unwrap();
        assert!(
            reader
                .steps_on_line(step.path_id, step.line.0 as usize)
                .unwrap()
                .iter()
                .all(|row| expected.contains(&row.step_id))
        );
        if check_values && (step.line == Line(10) || step.line == Line(20)) {
            let values = reader.variables_at(*id).unwrap();
            assert!(
                values
                    .iter()
                    .any(|value| matches!(value.value, ValueRecord::Int { i, .. } if i == step.line.0)),
                "values must retain their execution IDs across the marker gaps"
            );
        }
    }
    let mut session = MaterializedReplaySession::new(reader);
    if check_values {
        let events = session.load_events().unwrap();
        assert_eq!(events.events.len(), 2);
        assert!(
            events
                .events
                .iter()
                .all(|event| event.high_level_path == db_backend::task::NO_PATH)
        );
    }
    for marker in markers {
        let before = session.current_step_id();
        assert!(
            session.jump_to(*marker).is_err(),
            "an explicit jump must reject a reload annotation"
        );
        assert_eq!(session.current_step_id(), before);
    }
    assert_eq!(
        session.current_step_id(),
        *expected.first().unwrap(),
        "startup cannot select a leading annotation"
    );
    session.run_to_entry().unwrap();
    assert!(expected.contains(&session.current_step_id()));
    session.jump_to(*expected.first().unwrap()).unwrap();
    for next in expected.iter().skip(1) {
        session.step(Action::StepIn, true).unwrap();
        assert_eq!(session.current_step_id(), *next);
    }
    session.step(Action::Continue, true).unwrap();
    assert_eq!(
        session.current_step_id(),
        *expected.last().unwrap(),
        "trailing marker is not a destination"
    );
    for previous in expected.iter().rev().skip(1) {
        session.step(Action::StepIn, false).unwrap();
        assert_eq!(session.current_step_id(), *previous);
    }
    session.step(Action::Continue, false).unwrap();
    assert_eq!(
        session.current_step_id(),
        *expected.first().unwrap(),
        "leading marker is not a destination"
    );
}

#[test]
fn reload_annotations_are_absent_from_lazy_and_materialized_views_and_navigation() {
    let dir = tempfile::tempdir().unwrap();
    for column_aware in [false, true] {
        let path = fixture(dir.path(), column_aware);
        let (expected, markers) = independent_indices(&path);
        assert!(!expected.is_empty());
        assert_eq!(markers.len(), 4);
        assert!(markers.first().unwrap() < expected.first().unwrap());
        assert!(markers.last().unwrap() > expected.last().unwrap());
        assert!(markers.iter().any(|id| markers.contains(&StepId(id.0 + 1))));
        let reader = CTFSTraceReader::open(&path).unwrap();
        let takes_lazy_path = reader.lazy_steps_populated().is_some();
        let materialized = reader.materialized_db();
        assert_view(Arc::new(reader), &expected, &markers, true);
        assert_eq!(
            takes_lazy_path, !column_aware,
            "exercise both the lazy and eager production paths"
        );

        assert_view(
            Arc::new(InMemoryTraceReader::new(materialized)),
            &expected,
            &markers,
            true,
        );
    }
}

#[test]
fn genuine_godot_reload_annotations_are_absent_from_lazy_and_materialized_views() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/gdscript/gdh7_reloaded/gdscript_trace.ct");
    let (expected, markers) = independent_indices(&path);
    assert!(!expected.is_empty());
    assert_eq!(markers.len(), 2, "genuine three-version recording");
    let reader = CTFSTraceReader::open(&path).unwrap();
    let takes_lazy_path = reader.lazy_steps_populated().is_some();
    let materialized = reader.materialized_db();
    assert_view(Arc::new(reader), &expected, &markers, false);
    assert!(takes_lazy_path, "exercise genuine production steps");

    assert_view(
        Arc::new(InMemoryTraceReader::new(materialized)),
        &expected,
        &markers,
        false,
    );
}

#[test]
fn annotation_only_trace_has_no_source_location_or_navigation_destination() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("annotation_only");
    let source = Path::new("/test/no_steps.py");
    let mut writer = CtfsTraceWriter::new("annotation_only", &[]);
    writer.enable_line_count_table().unwrap();
    writer.begin_writing_trace_events(&path).unwrap();
    writer.declare_source_reload().unwrap();
    let old = writer.register_path_version(source, 100).unwrap();
    let new = writer.register_path_version(source, 100).unwrap();
    writer
        .register_source_reload(
            &[SourceReloadChange {
                old_path_id: old.0 as u64,
                new_path_id: new.0 as u64,
                generation: 2,
            }],
            0,
        )
        .unwrap();
    writer.finish_writing_trace_events().unwrap();
    let path = path.with_extension("ct");
    let (steps, markers) = independent_indices(&path);
    assert!(steps.is_empty());
    assert_eq!(markers.len(), 1);
    let reader = CTFSTraceReader::open(&path).unwrap();
    let materialized = reader.materialized_db();
    let views: Vec<Arc<dyn TraceReader>> = vec![Arc::new(reader), Arc::new(InMemoryTraceReader::new(materialized))];
    for view in views {
        assert_eq!(view.step_count(), 1, "the annotation keeps its execution ID");
        assert!(view.step(StepId(0)).is_none());
        assert!(view.steps_from(StepId(0)).is_empty());
        assert!(view.first_step_id().is_none());
        assert!(view.last_step_id().is_none());
        let mut session = MaterializedReplaySession::new(view);
        session.run_to_entry().unwrap();
        let mut loader = db_backend::expr_loader::ExprLoader::new(db_backend::task::CoreTrace::default());
        assert_eq!(
            session.load_location(&mut loader).unwrap(),
            db_backend::task::Location::default()
        );
        assert!(!session.step(Action::StepIn, true).unwrap());
        assert!(!session.step(Action::StepIn, false).unwrap());
        assert!(!session.step(Action::Continue, true).unwrap());
        assert!(session.jump_to(StepId(0)).is_err());
    }
}
