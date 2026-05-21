#include "hcr_fixture.h"

enum {
  ReprobuildHcrGenerationOneBias = 77
};

REPROBUILD_HCR_PATCHABLE int reprobuild_hcr_patchable_value(int iteration) {
  int generation_one_bias = ReprobuildHcrGenerationOneBias; /* REPROBUILD_HCR_GEN1_BREAKPOINT */
  int step_state = iteration + generation_one_bias; /* REPROBUILD_HCR_GEN1_STEP_START */
  step_state = step_state + 0; /* REPROBUILD_HCR_GEN1_STEP_NEXT */
  return step_state;
}
