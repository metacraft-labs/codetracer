// Simple JavaScript program for flow/omniscience integration testing.
// This program tests that local variables inside functions can be loaded
// and that function calls (console.log, calculate_sum) are filtered out
// from variable lists.
//
// The computation matches the Nim, Rust, Go, Python, and Ruby flow test programs:
//   a=10, b=32, sum_val=42, doubled=84, final_result=94

function calculate_sum(a, b) {
  // Local variables inside a function -- these should be extracted
  var sum_val = a + b;
  var doubled = sum_val * 2;
  var final_result = doubled + 10;
  console.log("Sum:", sum_val);
  console.log("Doubled:", doubled);
  console.log("Final:", final_result);
  return final_result;
}

// Local variables in main scope
var x = 10;
var y = 32;
var result = calculate_sum(x, y);
console.log("Result:", result);
