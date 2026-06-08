// Simple C++ program for MCR flow/omniscience DAP integration testing.
//
// Mirrors the C/Nim/Rust flow tests:
//   a = 10, b = 32, sum = 42, doubled = 84, final_result = 94
//
// Breakpoint is set at the `return final_result;` line inside
// `calculate_sum`; the DAP test verifies that the listed locals
// are reported with the expected values.

#include <iostream>

int calculate_sum(int a, int b) {
    int sum = a + b;
    int doubled = sum * 2;
    int final_result = doubled + 10;
    std::cout << "Sum: " << sum << std::endl;
    std::cout << "Doubled: " << doubled << std::endl;
    std::cout << "Final: " << final_result << std::endl;
    return final_result;
}

int main() {
    int x = 10;
    int y = 32;
    int result = calculate_sum(x, y);
    std::cout << "Result: " << result << std::endl;
    return 0;
}
