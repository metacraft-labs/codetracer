use crate::utils::collections::{fold_sum, slice_max};

pub fn collect_streams(
    shield_state: Field,
    stability: Field,
    routes: [Field; 8],
    path_score: Field
) -> Field {
    let mut total = shield_state + stability + path_score;
    for i in 0..routes.len() {
        total += routes[i] + (i as Field);
    }

    total + slice_max([shield_state, stability, fold_sum(routes), path_score])
}

pub fn summarize_payload(payload: [Field; 4]) -> Field {
    let mut summary = 0;
    for item in 0..payload.len() {
        summary += payload[item] * (item + 2) as Field;
    }
    summary
}
