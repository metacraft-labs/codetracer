use crate::utils::collections::{fold_sum, slice_max};

pub fn evaluate_matrix(initial: Field, regen_rate: Field, hazards: [Field; 8]) -> Field {
    let mut shield = initial;
    for i in 0..hazards.len() {
        let intensity = hazards[i] * (i + 1) as Field;
        shield = shield - intensity;
        let shield_i32 = shield as i32;
        if shield_i32 < 0 {
            shield = (shield_i32 * -1) as Field;
        }
        if shield_i32 % 3 == 0 {
            shield = shield + regen_rate;
        }
        let ripples = micro_ripples(shield, intensity);
        shield = shield + ripples - (i as Field);
    }
    let buffer = slice_max([initial, regen_rate, fold_sum(hazards), shield]);
    shield + buffer
}

fn micro_ripples(shield: Field, intensity: Field) -> Field {
    let shield_i32 = shield as i32;
    let intensity_i32 = intensity as i32;
    let mut ripple_i32 = (shield_i32 % 11) + (intensity_i32 % 7);
    if ripple_i32 > 500 {
        ripple_i32 = ripple_i32 / 2;
    }
    ripple_i32 as Field
}
