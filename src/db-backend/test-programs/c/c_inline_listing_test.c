#include <stdio.h>

static volatile int sink;

static __attribute__((always_inline)) inline int inline_sum(int a, int b) {
    int sum = a + b;
    sink = sum;
    return sum + 1;
}

static __attribute__((noinline)) int calculate(int value) {
    int result = inline_sum(value, 20);
    return result * 2;
}

int main(void) {
    printf("result %d\n", calculate(10));
    return 0;
}
