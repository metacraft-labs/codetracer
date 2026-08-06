#ifndef CODETRACER_WASM_MATH_H_
#define CODETRACER_WASM_MATH_H_

#define HUGE_VAL (__builtin_huge_val())
#define HUGE_VALF (__builtin_huge_valf())
#define INFINITY (__builtin_inff())
#define NAN (__builtin_nanf(""))

double fabs(double);
float fabsf(float);
double floor(double);
float floorf(float);
double ceil(double);
float ceilf(float);
double trunc(double);
float truncf(float);
double sqrt(double);
float sqrtf(float);
double pow(double, double);
double fmod(double, double);

/*
 * Fused multiply-add and round-to-nearest-integer.  Declared here so the
 * ct_emulator FMA/rounding shim (fma_shim.c) compiles under clang 21's strict
 * -Wimplicit-function-declaration=error on wasm32-unknown-unknown.  Prototypes
 * MUST be correct: an implicit declaration would assume `int` return/args,
 * which is ABI-wrong for these double/float routines.
 *
 * On wasm, clang lowers rint/rintf to the native `f64.nearest` / `f32.nearest`
 * instructions (round-to-nearest-even), so no runtime symbol is required.
 * fma/fmaf have no wasm instruction and are provided by compiler-rt's libm.
 */
double fma(double, double, double);
float fmaf(float, float, float);
double rint(double);
float rintf(float);

#endif // CODETRACER_WASM_MATH_H_
