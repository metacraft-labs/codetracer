pub fn bubble_sort(mut items: [Field; 8]) -> [Field; 8] {
    for i in 0..items.len() {
        for j in 0..items.len() {
            if j + 1 < items.len() {
                let left = items[j] as i32;
                let right = items[j + 1] as i32;
                if left > right {
                    let tmp = items[j];
                    items[j] = items[j + 1];
                    items[j + 1] = tmp;
                }
            }
        }
    }
    items
}

pub fn selection_sort(mut items: [Field; 8]) -> [Field; 8] {
    for i in 0..items.len() {
        let mut min_idx = i;
        for j in i..items.len() {
            let candidate = items[j] as i32;
            let current = items[min_idx] as i32;
            if candidate < current {
                min_idx = j;
            }
        }
        let tmp = items[i];
        items[i] = items[min_idx];
        items[min_idx] = tmp;
    }
    items
}

pub fn merge_pairs(left: [Field; 4], right: [Field; 4]) -> [Field; 8] {
    let mut merged: [Field; 8] = [0; 8];
    let mut li = 0;
    let mut ri = 0;
    for i in 0..8 {
        if li >= 4 {
            merged[i] = right[ri];
            ri += 1;
        } else if ri >= 4 {
            merged[i] = left[li];
            li += 1;
        } else {
            let left_val = left[li] as i32;
            let right_val = right[ri] as i32;
            if left_val <= right_val {
                merged[i] = left[li];
                li += 1;
            } else {
                merged[i] = right[ri];
                ri += 1;
            }
        }
    }
    merged
}
