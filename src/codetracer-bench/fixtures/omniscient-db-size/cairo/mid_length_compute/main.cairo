// omniscient-db-size / cairo / mid_length_compute
//
// Single-loop variant — the original nested-loop version (200 × 64
// iterations + a `fold` helper) tripped the Sierra `GasBuiltin`
// requirement, which `tracer.rs`'s `run_function_with_starknet_context`
// invocation doesn't supply.  An inlined single-loop body of ~1000
// iterations stays gas-free while still producing a "mid length"
// trace (the working `short_loop` fixture iterates 100 times; this
// one does 10× that with the same arithmetic shape).
fn main() -> felt252 {
    let mut state: felt252 = 0;
    let mut i: felt252 = 0;
    loop {
        if i == 1000 {
            break;
        }
        state = state * 31 + i * 7;
        i = i + 1;
    };
    state
}
