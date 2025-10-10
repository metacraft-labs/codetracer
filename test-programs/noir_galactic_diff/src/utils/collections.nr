pub fn fold_sum8(values: [Field; 8]) -> Field {
    let mut sum = 0;
    for i in 0..values.len() {
        sum += values[i];
    }
    sum
}

pub fn fold_sum4(values: [Field; 4]) -> Field {
    let mut sum = 0;
    for i in 0..values.len() {
        sum += values[i];
    }
    sum
}

pub fn fold_sum(values: [Field; 8]) -> Field {
    fold_sum8(values)
}

pub fn fold_sum_small(values: [Field; 4]) -> Field {
    fold_sum4(values)
}

pub fn slice_max4(values: [Field; 4]) -> Field {
    let mut best = values[0];
    let mut best_i32 = best as i32;
    for i in 0..values.len() {
        let candidate_i32 = values[i] as i32;
        if candidate_i32 > best_i32 {
            best = values[i];
            best_i32 = candidate_i32;
        }
    }
    best
}

pub fn slice_max8(values: [Field; 8]) -> Field {
    let mut best = values[0];
    let mut best_i32 = best as i32;
    for i in 0..values.len() {
        let candidate_i32 = values[i] as i32;
        if candidate_i32 > best_i32 {
            best = values[i];
            best_i32 = candidate_i32;
        }
    }
    best
}

pub fn slice_max(values: [Field; 4]) -> Field {
    slice_max4(values)
}

pub fn slice_max_large(values: [Field; 8]) -> Field {
    slice_max8(values)
}

pub fn slice_min(values: [Field; 4]) -> Field {
    let mut best = values[0];
    let mut best_i32 = best as i32;
    for i in 0..values.len() {
        let candidate_i32 = values[i] as i32;
        if candidate_i32 < best_i32 {
            best = values[i];
            best_i32 = candidate_i32;
        }
    }
    best
}

