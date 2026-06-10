module calculator;

int add(int a, int b) {
    return a + b;
}

int doubleValue(int value) {
    return value * 2;
}

unittest {
    assert(add(2, 3) == 5);
}

unittest {
    assert(doubleValue(4) == 8);
}
