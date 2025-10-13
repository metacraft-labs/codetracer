use crate::utils::collections::slice_max;

pub fn recursive_probe(depth: u32, weights: [Field; 8], hazards: [Field; 8], acc: Field) -> Field {
    if depth == 3 {
        let base = acc + slice_max([weights[depth], hazards[depth], acc, 0]);
        base
    } else {
        let combined = weights[depth] + hazards[depth] + acc;
        recursive_probe(depth + 1, weights, hazards, combined) + combined
    }
}
