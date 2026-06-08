// Simple D program for MCR flow/omniscience DAP integration testing.
//
// Mirrors the C/Nim/Rust flow tests:
//   a = 10, b = 32, sum = 42, doubled = 84, final_result = 94
//
// Breakpoint is set at the `return final_result;` line inside
// `calculate_sum`; the DAP test verifies that the listed locals
// are reported with the expected values.

import std.stdio;

int calculate_sum(int a, int b) {
    int sum = a + b;
    int doubled = sum * 2;
    int final_result = doubled + 10;
    writeln("Sum: ", sum);
    writeln("Doubled: ", doubled);
    writeln("Final: ", final_result);
    return final_result;
}

void main() {
    int x = 10;
    int y = 32;
    int result = calculate_sum(x, y);
    writeln("Result: ", result);
}
