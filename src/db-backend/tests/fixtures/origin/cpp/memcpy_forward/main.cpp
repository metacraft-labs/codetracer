// memcpy_forward — C++
//
// Pure C-style `memcpy(dst, src, n)` reuse: the classifier treats the
// memcpy as a built-in forwarder, so the chain for `dst[0]` after the
// memcpy classifies as TrivialCopy with source_variable = src.
//
// Expected chain for `dst[0]` queried at the printf line:
//
//   hop 0: target=dst   rhs=memcpy(dst,src,4)   OriginKind=TrivialCopy   source_variable=src
//   hop 1: target=src   rhs=42                  OriginKind=Literal       terminator=Literal(int, value=42)
#include <cstdio>
#include <cstring>

int main() {
    int src = 42;
    int dst = 0;
    std::memcpy(&dst, &src, sizeof(int));
    std::printf("%d\n", dst);
    return 0;
}
