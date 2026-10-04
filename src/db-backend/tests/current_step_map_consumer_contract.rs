//! Current STMP consumer boundary controls use the actual production encoder.
//! Corrupted counts/keys/frames and oversized IDs are explicit fault inputs,
//! not recorder mocks or manufactured qualified recordings. Existing real Nim
//! browser/range/lazy-step gates independently qualify recorder integration.
#![allow(clippy::expect_used, clippy::unwrap_used)]
use codetracer_trace_types::{PathId, StepId};
use codetracer_trace_writer::step_map::StepMapBuilder;
use db_backend::ctfs_trace_reader::step_map_namespace::{StepMapError, StepMapNamespace};

#[test]
fn empty_current_index_is_built_and_covers_only_zero_steps() {
    let bytes = StepMapBuilder::new().serialize().unwrap();
    assert_eq!(u16::from_le_bytes(bytes[4..6].try_into().unwrap()), 2);
    let ui = StepMapNamespace::parse(&bytes).unwrap();
    assert_eq!(ui.entry_count(), 0);
    assert!(ui.covers_all_steps(0));
    assert!(!ui.covers_all_steps(1));
}

#[test]
fn genuine_multi_chunk_lists_and_complete_range_match_registered_coordinates() {
    let mut producer = StepMapBuilder::new();
    for id in 0..40_000u64 {
        producer.record_step(id % 2, (id / 2 + 1) as i64, id);
    }
    let bytes = producer.serialize().unwrap();
    assert!(u32::from_le_bytes(bytes[6..10].try_into().unwrap()) > 1);
    let ui = StepMapNamespace::parse(&bytes).unwrap();
    assert_eq!(ui.entry_count(), 40_000);
    assert_eq!(ui.total_step_ids(), 40_000);
    assert!(ui.covers_all_steps(40_000));
    assert!(!ui.covers_all_steps(40_001));
    assert_eq!(ui.max_line_in_step_range(StepId(100), StepId(150)), 75);
    for id in 0..40_000u64 {
        assert_eq!(
            ui.step_ids_on_line(PathId((id % 2) as usize), (id / 2 + 1) as usize)
                .map(Vec::as_slice),
            Some(&[StepId(id as i64)][..])
        );
    }
}

#[test]
fn actual_current_decoder_refuses_count_key_frame_and_truncation_faults() {
    let mut producer = StepMapBuilder::new();
    producer.record_step(0, 1, 0);
    let good = producer.serialize().unwrap();
    let mut wrong_count = good.clone();
    wrong_count[18..26].copy_from_slice(&2u64.to_le_bytes());
    let mut wrong_key = good.clone();
    wrong_key[42..46].copy_from_slice(&2u32.to_le_bytes());
    let mut wrong_frame = good.clone();
    wrong_frame[46] ^= 1;
    let truncated = good[..good.len() - 1].to_vec();
    for bad in [wrong_count, wrong_key, wrong_frame, truncated] {
        assert!(matches!(
            StepMapNamespace::parse(&bad),
            Err(StepMapError::CurrentFormat(_))
        ));
    }
    assert!(StepMapNamespace::parse(&good).unwrap().covers_all_steps(1));
}

#[test]
fn current_unsigned_step_id_cannot_wrap_into_signed_ui_step_id() {
    let mut producer = StepMapBuilder::new();
    producer.record_step(0, 1, i64::MAX as u64 + 1);
    let bytes = producer.serialize().unwrap();
    assert!(
        matches!(StepMapNamespace::parse(&bytes), Err(StepMapError::CurrentFormat(message)) if message.contains("step id exceeds i64"))
    );
}
