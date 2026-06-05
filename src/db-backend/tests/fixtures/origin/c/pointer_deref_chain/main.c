/* pointer_deref_chain — C
 *
 * int a = 10; int *p = &a; int b = *p — terminates at Literal via two
 * IndexAccess hops (the pointer dereference + the pointer initialisation).
 *
 * Expected chain for `b` queried at the printf line:
 *
 *   hop 0: target=b   rhs=*p     OriginKind=IndexAccess   source_variable=p
 *   hop 1: target=p   rhs=&a     OriginKind=IndexAccess   source_variable=a
 *   hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(int, value=10)
 */
#include <stdio.h>

int main(void) {
    int a = 10;
    int *p = &a;
    int b = *p;
    printf("%d\n", b);
    return 0;
}
