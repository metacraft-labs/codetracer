// omniscient-db-size / c_plus_plus / mid_length_compute
//
// Profile: rolling-buffer compute kernel — repeatedly XORs 64-byte
// chunks into an accumulator and folds the result. Models a typical
// compute-bound user inner loop. P3 reuses this fixture.
#include <cstdint>
#include <cstdio>
#include <cstring>

static void fold(uint8_t* state, const uint8_t* chunk) {
    for (int i = 0; i < 32; ++i) {
        state[i] ^= chunk[i] + static_cast<uint8_t>(i);
        state[i] = static_cast<uint8_t>(state[i] * 31 + 7);
    }
}

int main() {
    uint8_t state[32];
    std::memset(state, 0, sizeof state);
    uint8_t chunks[64][64];
    for (int i = 0; i < 64; ++i) {
        for (int j = 0; j < 64; ++j) {
            chunks[i][j] = static_cast<uint8_t>((i + j) % 251);
        }
    }
    int accum = 0;
    for (int round_idx = 0; round_idx < 200; ++round_idx) {
        for (int c = 0; c < 64; ++c) {
            fold(state, chunks[c]);
            accum = (accum + state[0]) & 0xFFFF;
        }
    }
    std::printf("%d %zu\n", accum, sizeof state);
    return 0;
}
