/*
 * A C sample: a block comment across lines.
 */
#include <stdio.h>
#include "local.h"
#define MAX(a, b) ((a) > (b) ? (a) : (b))

typedef struct {
    int x;
    unsigned long y;
} pair_t;

static const char *names[] = {"zero", "one", "two\n"};

// Sum an array.
int sum(const int *xs, size_t n) {
    int total = 0;
    for (size_t i = 0; i < n; ++i) {
        total += xs[i];
    }
    return total;
}

int main(int argc, char **argv) {
    int values[4] = {1, 0x1F, 077, 'a'};
    double ratio = 1.5e3f;
    pair_t p = { .x = 3, .y = 4UL };
    if (argc > 1 && argv[1][0] == '-') {
        printf("%s %d %f\n", names[1], sum(values, 4), ratio);
    } else {
        printf("%lu\n", p.y);
    }
    return MAX(p.x, 0);
}
