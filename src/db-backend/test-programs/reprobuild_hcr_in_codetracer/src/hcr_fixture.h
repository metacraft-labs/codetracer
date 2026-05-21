#ifndef CODETRACER_REPROBUILD_HCR_FIXTURE_H
#define CODETRACER_REPROBUILD_HCR_FIXTURE_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__APPLE__) && defined(__aarch64__)
#define REPROBUILD_HCR_PATCHABLE __attribute__((noinline, used, visibility("default"), section("__HCR,__text")))
#else
#define REPROBUILD_HCR_PATCHABLE __attribute__((noinline, used))
#endif

int reprobuild_hcr_patchable_value(int iteration);

#ifdef __cplusplus
}
#endif

#endif
