/* destructuring_or_index — C
 *
 * C does not have tuple destructuring; we use struct field access
 * (the language-appropriate analogue) plus array index access.
 */
#include <stdio.h>

struct Pair {
    int first;
    int second;
};

int main(void) {
    struct Pair pair = { 11, 22 };
    int first = pair.first;        /* field access */
    int indexed = ((int[]){11, 22})[1];  /* literal array index */
    printf("%d %d\n", first, indexed);
    return 0;
}
