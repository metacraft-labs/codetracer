use crate::utils::collections::fold_sum8;

pub fn recovery_boost(regen_rate: Field, hazards: [Field; 8]) -> Field {
    let total = fold_sum8(hazards);
    let mut boost_i32 = (regen_rate + total) as i32;
    if boost_i32 % 2 == 0 {
        boost_i32 = boost_i32 + 7;
    }
    boost_i32 as Field
}

pub fn checksum(values: [Field; 6]) -> Field {
    let mut sum = 0;
    for i in 0..values.len() {
        let weight = (i + 1) as Field;
        sum += values[i] * weight;
    }
    sum
}
