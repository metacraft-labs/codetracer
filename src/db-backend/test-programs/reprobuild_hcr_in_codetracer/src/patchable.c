#include "hcr_fixture.h"

int reprobuild_hcr_patchable_value(int iteration) {
  int generation_zero_bias = 11; /* REPROBUILD_HCR_GEN0_BREAKPOINT */
  int step_state = iteration + generation_zero_bias; /* REPROBUILD_HCR_GEN0_STEP_START */
  step_state = step_state + 0; /* REPROBUILD_HCR_GEN0_STEP_NEXT */
  return step_state;
}
