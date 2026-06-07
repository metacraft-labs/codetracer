// omniscient-db-size / cairo / mid_length_compute
fn fold(state: felt252, chunk: felt252) -> felt252 {
    state * 31 + chunk * 7
}

fn main() -> felt252 {
    let mut state: felt252 = 0;
    let mut round_idx: felt252 = 0;
    loop {
        if round_idx == 200 {
            break;
        }
        let mut c: felt252 = 0;
        loop {
            if c == 64 {
                break;
            }
            state = fold(state, c);
            c = c + 1;
        };
        round_idx = round_idx + 1;
    };
    state
}
