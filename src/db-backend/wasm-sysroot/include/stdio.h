#ifndef TREE_SITTER_WASM_STDIO_H_
#define TREE_SITTER_WASM_STDIO_H_

#include <stdbool.h>
#include <stdint.h>

typedef struct FILE FILE;

typedef __builtin_va_list va_list;
#define va_start(ap, last) __builtin_va_start(ap, last)
#define va_end(ap) __builtin_va_end(ap)
#define va_arg(ap, type) __builtin_va_arg(ap, type)

#define stdout ((FILE *)0)

#define stderr ((FILE *)1)

#define stdin ((FILE *)2)

#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2

void clearerr(FILE *stream);

int fclose(FILE *stream);

FILE *fdopen(int fd, const char *mode);

int ferror(FILE *stream);

int fflush(FILE *stream);

FILE *fopen(const char *restrict filename, const char *restrict mode);

int fputc(int c, FILE *stream);

int fputs(const char *restrict s, FILE *restrict stream);

size_t fread(void *restrict buffer, size_t size, size_t nmemb,
             FILE *restrict stream);

size_t fwrite(const void *restrict buffer, size_t size, size_t nmemb,
              FILE *restrict stream);

int fseeko(FILE *stream, long long offset, int whence);

long long ftello(FILE *stream);

int fprintf(FILE *restrict stream, const char *restrict format, ...);

int snprintf(char *restrict buffer, size_t buffsz, const char *restrict format,
             ...);

int vsnprintf(char *restrict buffer, size_t buffsz, const char *restrict format,
              va_list vlist);

int setvbuf(FILE *restrict stream, char *restrict buffer, int mode, size_t size);

#endif // TREE_SITTER_WASM_STDIO_H_
