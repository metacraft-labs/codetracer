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

#endif // CODETRACER_WASM_MATH_H_
