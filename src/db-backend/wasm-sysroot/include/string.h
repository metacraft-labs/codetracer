#ifndef TSWASM_STRING_H
#define TSWASM_STRING_H

#include <stddef.h> /* size_t, NULL */
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int memcmp(const void *lhs, const void *rhs, size_t count);

void *memcpy(void *restrict dst, const void *restrict src, size_t size);

void *memmove(void *dst, const void *src, size_t count);

void *memset(void *dst, int value, size_t count);

int strncmp(const char *left, const char *right, size_t n);

int strcmp(const char *left, const char *right);

size_t strlen(const char *s);

char *strncpy(char *restrict dst, const char *restrict src, size_t n);

char *strerror(int errnum);

/* Internal implementations (no exported symbols).
 * These are stub-only: they satisfy the compiler but are never called
 * in practice (tree-sitter grammars are used for tracepoint parsing,
 * which is not exercised in the WASM replay path). */
static inline void *tsw_memchr(const void *s, int c, size_t n) {
    (void)s; (void)c; (void)n;
    return NULL;
}

static inline char *tsw_strchr(const char *s, int c) {
    (void)s; (void)c;
    return NULL;
}

/* Map the standard names to our internal ones in this TU only. */
#define memchr tsw_memchr
#define strchr tsw_strchr

#ifdef __cplusplus
}
#endif
#endif /* TSWASM_STRING_H */
