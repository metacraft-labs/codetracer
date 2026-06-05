// simple_trivial_chain — C++
//
// int a = 10; int b = a; int c = b — terminates at Literal.
//
// Canonical M11 fixture. The expected chain for `c` is:
//
//   hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
//   hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
//   hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(int, value=10)
#include <cstdio>

int main() {
    int a = 10;
    int b = a;
    int c = b;
    std::printf("%d\n", c);
    return 0;
}
