/* simple_trivial_chain — C
 *
 * int a = 10; int b = a; int c = b — terminates at Literal.
 */
#include <stdio.h>

int main(void) {
    int a = 10;
    int b = a;
    int c = b;
    printf("%d\n", c);
    return 0;
}
