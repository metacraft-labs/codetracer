/* omniscient-db-size / c / short_loop */
#include <stdio.h>

int main(void) {
    long total = 0;
    for (int i = 0; i < 100; ++i) {
        total = total + i * 2;
    }
    printf("%ld\n", total);
    return 0;
}
