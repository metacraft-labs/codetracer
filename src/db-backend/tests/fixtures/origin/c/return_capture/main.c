/* return_capture — C */
#include <stdio.h>

static int compute(void) {
    int a = 3;
    int b = 4;
    return a + b;
}

int main(void) {
    int captured = compute();
    printf("%d\n", captured);
    return 0;
}
