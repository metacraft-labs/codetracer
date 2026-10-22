// Fixture for src/tests/gui/tests/flow/omniscience_eye_icon_dual.spec.ts.
// `readings` CHANGES on lines 8 and 9, so its flow chip there shows the value
// before and after the line (dual mode), and twelve elements render well past
// the 30-cell chip budget, so the chip carries the eye icon.
fn main(x: Field) {
    let mut readings: [Field; 12] = [0; 12];
    let offset: Field = 1000000;
    readings[3] = x + offset;
    readings[7] = x + offset + offset;
    assert(readings[3] != readings[7]);
}
