// omniscient-db-size / c_plus_plus / short_loop
//
// Profile: a small fixed loop doing trivial integer arithmetic.
// Models a CLI helper whose recording is tiny.
#include <cstdio>

int main() {
    long total = 0;
    for (int i = 0; i < 100; ++i) {
        total = total + i * 2;
    }
    std::printf("%ld\n", total);
    return 0;
}
