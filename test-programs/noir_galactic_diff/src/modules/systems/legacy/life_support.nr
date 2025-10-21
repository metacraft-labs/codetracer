use crate::utils::collections::{fold_sum_small, slice_min};

pub fn estimate_margin(grid: Field, morale: [Field; 4]) -> Field {
    let energy = grid + fold_sum_small(morale);
    let weakest = slice_min(morale);
    energy - weakest
}

pub fn recycle_capacity(cycles: [Field; 4], efficiency: Field) -> Field {
    if efficiency as i32 == 0 {
        return 0;
    }
    let mut capacity = 0;
    for i in 0..cycles.len() {
        let mut cycle = cycles[i] * efficiency;
        let cycle_i32 = cycle as i32;
        capacity += (cycle_i32 / 7 + cycle_i32) as Field;
    }
    capacity
}
