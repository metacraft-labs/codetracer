// A Noir circuit: the desktop opens `.nr` with the Rust tokenizer.
use dep::std;

struct Ship {
    x: Field,
    y: Field,
    fuel: u32,
}

/* Move the ship,
   checking the fuel. */
fn step(ship: Ship, dx: Field, dy: Field) -> Ship {
    assert(ship.fuel > 0, "out of fuel");
    Ship { x: ship.x + dx, y: ship.y + dy, fuel: ship.fuel - 1 }
}

fn main(x: Field, y: pub Field) {
    let mut ship = Ship { x, y, fuel: 10 };
    for i in 0..3 {
        ship = step(ship, i as Field, 1);
    }
    let hash = std::hash::pedersen_hash([ship.x, ship.y]);
    assert(hash != 0);
}

#[test]
fn test_main() {
    main(1, 2);
}
