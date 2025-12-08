#include <stdio.h>

int bug(int* a) {
    int original = *a;
    int* a_address = a;
    int* a_1_address = &a[1];
    // in the scenario the author here thinks he is changing
    // a[0]
    a[1] = -50000;
    int new_value = *a;

}

int usage(int *value) {
    int my_result = *value + 10;
    printf("my result is %d", my_result);
}

void change(int* arg) {
    int original = *arg;
    *arg += 1;
    int value = *arg;
}

int processing() {
    int arg = 20;
    int value = 10;
    int* value_address = &value;
    int* arg_address = &arg;

    printf("value %d\n", value);
    printf("arg %d\n", arg);

    change(&arg);
    change(&arg);

    bug(&value);

    usage(&arg);

    return 0;
}

int main() {
    // static char buffer[BUFSIZ] = { 0 };
    setbuf(stdout, NULL); // workaround for flushing and tests copied online resources/people in rr-backend/tests

    // setvbuf(stdout, buffer, _IOFBF, 10);
    return processing();
}