#ifdef CALLTRACE_SEARCH_LIBRARY
int later_loaded(int value) {
    volatile int result = value + 7;
    return result;
}
#else
#include <dlfcn.h>
#include <stdio.h>

#ifndef CALLTRACE_LIBRARY_PATH
#define CALLTRACE_LIBRARY_PATH "./libsearch_calls.so"
#endif

static volatile int initialized;
__attribute__((constructor)) static void before_main(void) {
    initialized = 123;
}

int main(void) {
    void *library = dlopen(CALLTRACE_LIBRARY_PATH, RTLD_NOW);
    if (!library) return 2;
    int (*function)(int) = (int (*)(int))dlsym(library, "later_loaded");
    if (!function) return 3;
    int result = function(11);
    printf("%d %d\n", initialized, result);
    return 0; /* search after both calls returned */
}
#endif
