// Simple C program for flow/omniscience integration testing.
// Tests that local variables in functions can be loaded without
// trying to evaluate function names, type names, or macros.
//
// This program exercises several C constructs that produce
// `identifier` nodes in the tree-sitter AST:
//   - local variables (should be evaluated)
//   - function calls like printf (should be filtered out)
//   - macro constants like MAX_SIZE (should be filtered out)
//   - struct field access (field_identifier — already distinct)
//   - enum values (should be filtered out)

#include <stdio.h>

#define MAX_SIZE 10

enum Color { RED, GREEN, BLUE };

struct Point {
    int x;
    int y;
};

int calculate_sum(int a, int b) {
    int sum = a + b;
    int doubled = sum * 2;
    int final_result = doubled + MAX_SIZE;
    printf("Sum: %d\n", sum);
    printf("Doubled: %d\n", doubled);
    printf("Final: %d\n", final_result);
    return final_result;
}

void with_loops(int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        sum += i;
    }
    printf("for sum: %d\n", sum);

    sum = 0;
    int j = 0;
    while (j < n) {
        sum += j;
        j++;
    }
    printf("while sum: %d\n", sum);

    sum = 0;
    int k = 0;
    do {
        sum += k;
        k++;
    } while (k < n);
    printf("do-while sum: %d\n", sum);
}

int main(void) {
    int x = 10;
    int y = 32;
    int result = calculate_sum(x, y);
    printf("Result: %d\n", result);

    struct Point p;
    p.x = x;
    p.y = y;
    printf("Point: (%d, %d)\n", p.x, p.y);

    enum Color c = GREEN;
    printf("Color: %d\n", c);

    with_loops(x);
    return 0;
}
