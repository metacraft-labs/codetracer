mod foo;
mod bar;

use crate::foo::foo;

fn main(x: Field, y: pub Field, z: Field) {
    let w = looper(x, y);
    assert(w == z, "expected w to equal z!");
}

fn looper(x: Field, y: Field) -> Field {
    let mut result = x;
    for i in 0..10 {
        for z in 0..10 {
            println(i + 1);
            println(i + z);
            if i % 3 == 0 {
                result = result + y + 2;
            }
        }
    }
    result
}

