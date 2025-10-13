use crate::utils::collections::{fold_sum_small, slice_min, slice_max};

pub fn weighted_average(values: [Field; 4], weights: [Field; 4]) -> Field {
    let mut numerator = 0;
    let mut denominator = 0;
    for i in 0..values.len() {
        numerator += values[i] * weights[i];
        denominator += weights[i];
    }
    let denom_i32 = denominator as i32;
    if denom_i32 == 0 {
        0
    } else {
        numerator / denominator
    }
}

pub fn normalize_morale(values: [Field; 4]) -> Field {
    let total = fold_sum_small(values);
    let min_val = slice_min(values);
    let max_val = slice_max(values);
    (total - min_val - max_val) / 2
}

pub fn trend_direction(values: [Field; 4]) -> Field {
    let mut direction = 0;
    for i in 0..values.len() {
        if i + 1 < values.len() {
            direction += values[i + 1] - values[i];
        }
    }
    direction
}
