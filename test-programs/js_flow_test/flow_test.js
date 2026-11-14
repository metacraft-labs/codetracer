// The flow program every language recorder's smoke scenario records: a few
// locals, one call, one line of output.
function compute() {
  const a = 10;
  const b = 32;
  const sum_val = a + b;
  const doubled = sum_val * 2;
  const final_result = doubled + a;
  console.log("final_result", final_result);
  return final_result;
}

compute();
