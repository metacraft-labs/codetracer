use crate::utils::collections::{fold_sum, slice_max};

pub fn compute_galactic_path(weights: [Field; 8], hazards: [Field; 8]) -> Field {
    let mut adjacency: [[Field; 8]; 8] = [[0; 8]; 8];
    for i in 0..8 {
        for j in 0..8 {
            let raw = (weights[i] + hazards[j]) * (i + j + 1) as Field;
            let raw_i32 = raw as i32;
            let normalized = if i == j {
                0
            } else if raw_i32 % 2 == 0 {
                (raw_i32 / 2) as Field
            } else {
                raw
            };
            adjacency[i][j] = normalized;
        }
    }

    let mut accumulator = 0;
    for i in 0..8 {
        let best = dijkstra_step(adjacency, i as u32);
        accumulator += best;
        let best_i32 = best as i32;
        if best_i32 > 5000 {
            accumulator += iterative_relaxation(best, hazards);
        }
    }

    accumulator + recursive_probe(0, weights, hazards, 0)
}

fn dijkstra_step(adjacency: [[Field; 8]; 8], source: u32) -> Field {
    let mut distances: [Field; 8] = [100000; 8];
    let mut visited: [bool; 8] = [false, false, false, false, false, false, false, false];
    distances[source] = 0;

    for _ in 0..8 {
        let idx = select_next(distances, visited);
        visited[idx] = true;

        for neighbor in 0..8 {
            if !visited[neighbor] {
                let tentative = distances[idx] + adjacency[idx][neighbor];
                let tentative_i32 = tentative as i32;
                let current_i32 = distances[neighbor] as i32;
                if tentative_i32 < current_i32 {
                    distances[neighbor] = tentative;
                }
            }
        }
    }

    fold_sum(distances)
}

fn select_next(distances: [Field; 8], visited: [bool; 8]) -> u32 {
    let mut best_index = 0;
    let mut best_value_i32 = 300000;
    for i in 0..8 {
        if !visited[i] {
            let candidate_i32 = distances[i] as i32;
            if candidate_i32 < best_value_i32 {
                best_value_i32 = candidate_i32;
                best_index = i;
            }
        }
    }
    best_index
}

fn iterative_relaxation(seed: Field, hazards: [Field; 8]) -> Field {
    let mut cursor = seed;
    for i in 0..hazards.len() {
        cursor = cursor + hazards[i] * (i + 1) as Field;
    }
    cursor
}

fn recursive_probe(depth: u32, weights: [Field; 8], hazards: [Field; 8], acc: Field) -> Field {
    if depth == 3 {
        let base = acc + slice_max([weights[depth], hazards[depth], acc, 0]);
        base
    } else {
        let combined = weights[depth] + hazards[depth] + acc;
        recursive_probe(depth + 1, weights, hazards, combined) + combined
    }
}
