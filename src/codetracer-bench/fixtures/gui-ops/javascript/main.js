// P4 GUI-ops latency fixture (JavaScript).  Mirrors fixtures/gui-ops/python/main.py.
function fold(x, y) { return x * 31 + y; }

const a = 1;
const b = a + 2;
const c = b * 3;
const d = c + 10;
const e = fold(d, 7);
console.log(e);
