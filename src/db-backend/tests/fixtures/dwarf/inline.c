/* Optimized native-listing fixture. `bump` has DWARF inline frames but
 * deliberately no standalone machine-code symbol. Rebuild via rebuild.sh. */
volatile int input;
__attribute__((always_inline)) static inline int bump(int value) {
    return value * value + input;
}
__attribute__((noinline)) int outer(int value) {
    int result = bump(value);
    return result + input;
}
