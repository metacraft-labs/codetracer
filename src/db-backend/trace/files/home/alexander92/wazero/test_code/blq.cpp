int wasm_test() {
    int wasm_test_x = 3;
    int wasm_test_y = 4;

    return wasm_test_x;
}
int main() {
    int x = 1;
    int y = 2;

    int z = wasm_test();

    return 0;
}
