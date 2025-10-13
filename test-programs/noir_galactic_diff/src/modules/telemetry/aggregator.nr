use crate::modules::telemetry::aggregator_core;
use crate::utils::collections::{fold_sum, slice_max};

pub fn collect_streams(
    shield_state: Field,
    stability: Field,
    routes: [Field; 8],
    path_score: Field
) -> Field {
    let mut total = aggregator_core::base_total(shield_state, stability, path_score);
    total += aggregator_core::route_enrichment(routes);
    total + slice_max([shield_state, stability, fold_sum(routes), path_score])
}

pub fn summarize_payload(payload: [Field; 4]) -> Field {
    let mut summary = 0;
    for idx in 0..payload.len() {
        summary += payload[idx] * (idx + 2) as Field;
    }
    summary
}
