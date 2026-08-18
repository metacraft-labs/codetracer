// Fixture for the JavaScript per-step locals contract (issue #602 / M37).
//
// Exercises all three JS declaration forms in one frame — `const`, `let`
// and `var` — plus a reassignment, so a replay test can assert both
// that the names are recorded AND that each step carries the value the
// binding held at that point:
//
//   line 8  (`let scaled  = …`) — base = 42
//   line 9  (`var offset  = …`) — scaled = 84
//   line 10 (`scaled = scaled + offset`) — offset = 10, scaled still 84
//   line 11 (`return scaled`)  — scaled = 94
//
// The `return` line is the one that matters: before M37 the recorder
// only emitted a value on the step that *wrote* a binding, so stopping
// on `return` produced an empty State panel.
function compute(a, b) {
  const base = a + b;        // const declaration
  let scaled = base * 2;     // let declaration
  var offset = 10;           // var declaration
  scaled = scaled + offset;  // reassignment
  return scaled;
}
compute(10, 32);
