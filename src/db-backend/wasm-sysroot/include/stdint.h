#ifndef TREE_SITTER_WASM_STDINT_H_
#define TREE_SITTER_WASM_STDINT_H_

// https://github.com/llvm/llvm-project/blob/0c3cf200f5b918fb5c1114e9f1764c2d54d1779b/clang/test/Preprocessor/init.c#L1672

typedef signed char int8_t;

typedef short int16_t;

typedef int int32_t;

typedef long long int int64_t;

typedef unsigned char uint8_t;

typedef unsigned short uint16_t;

typedef unsigned int uint32_t;

typedef long long unsigned int uint64_t;

typedef long unsigned int size_t;

typedef long unsigned int uintptr_t;

#define INT8_MIN (-128)
#define INT8_MAX 127
#define UINT8_MAX 255

#define INT16_MIN (-32768)
#define INT16_MAX 32767
#define UINT16_MAX 65535

#define INT32_MIN (-2147483647 - 1)
#define INT32_MAX 2147483647
#define UINT32_MAX 4294967295U

#define INT64_MIN (-9223372036854775807LL - 1)
#define INT64_MAX 9223372036854775807LL
#define UINT64_MAX 18446744073709551615ULL

#define INT8_C(c) c
#define UINT8_C(c) c
#define INT16_C(c) c
#define UINT16_C(c) c
#define INT32_C(c) c
#define UINT32_C(c) c##U
#define INT64_C(c) c##LL
#define UINT64_C(c) c##ULL

#if defined(__wasm32__)

#define SIZE_MAX 4294967295UL

#elif defined(__wasm64__)

#define SIZE_MAX 18446744073709551615UL

#endif

#endif // TREE_SITTER_WASM_STDINT_H_
