/* parameter_pass — C */
#include <stdio.h>

static void receive(int p) {
    int local = p;
    printf("%d\n", local);
}

int main(void) {
    int value = 7;
    receive(value);
    return 0;
}
