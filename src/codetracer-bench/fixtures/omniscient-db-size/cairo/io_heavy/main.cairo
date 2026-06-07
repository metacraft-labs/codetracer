// omniscient-db-size / cairo / io_heavy
//
// Cairo programs don't expose host I/O syscalls the way conventional
// languages do — Cairo execution happens inside a deterministic VM
// with hint-supplied I/O. This fixture stands in for "io heavy" by
// exercising hint-driven array fills + reads, which are the
// closest analogue the Cairo recorder will surface.
use core::array::ArrayTrait;

fn main() -> felt252 {
    let mut buf: Array<felt252> = ArrayTrait::new();
    let mut i: felt252 = 0;
    loop {
        if i == 64 {
            break;
        }
        buf.append(i);
        i = i + 1;
    };
    let mut sum: felt252 = 0;
    let mut j: u32 = 0;
    let len: u32 = buf.len();
    loop {
        if j == len {
            break;
        }
        sum = sum + *buf.at(j);
        j = j + 1;
    };
    sum
}
