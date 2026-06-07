// omniscient-db-size / cairo / short_loop
//
// Cairo fixture set — minimal compute loop adapted for the
// Cairo 2.x flow. The codetracer-cairo-recorder isn't on PATH in
// the campaign's headless dev shell, so the bench surfaces this
// fixture as SKIPPED with a narrow sentinel; once the recorder is
// shipped this fixture matches the short_loop profile.
use core::debug::PrintTrait;

fn main() -> felt252 {
    let mut total: felt252 = 0;
    let mut i: felt252 = 0;
    loop {
        if i == 100 {
            break;
        }
        total = total + i * 2;
        i = i + 1;
    };
    total
}
