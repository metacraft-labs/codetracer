use crate::utils::collections::fold_sum;

pub fn weighted_course(weights: [Field; 8], hazards: [Field; 8]) -> Field {
    let mut total = 0;
    for i in 0..weights.len() {
        let mut weight = weights[i] * (i + 1) as Field;
        let weight_i32 = weight as i32;
        let hazard_i32 = hazards[i] as i32;
        let diff_i32 = if weight_i32 < hazard_i32 { hazard_i32 - weight_i32 } else { weight_i32 - hazard_i32 };
        weight = diff_i32 as Field;
        total += weight;
    }
    total + fold_sum(weights)
}

pub fn detour_cost(segments: [Field; 4]) -> Field {
    let mut cost = 0;
    for segment in 0..segments.len() {
        if segment % 2 == 0 {
            cost += segments[segment];
        } else {
            cost += segments[segment] * 2;
        }
    }
    cost
}
