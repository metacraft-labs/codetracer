#include "hcr_fixture.h"
#include "repro_hcr_agent.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void write_ready_file(void) {
  const char *ready_path = getenv("RB_HCR_FIXTURE_READY_FILE");
  if (ready_path == NULL || ready_path[0] == '\0') {
    return;
  }

  FILE *ready = fopen(ready_path, "w");
  if (ready == NULL) {
    fprintf(stderr, "failed to open ready file %s: %s\n", ready_path, strerror(errno));
    return;
  }
  fputs("ready\n", ready);
  fclose(ready);
}

static void start_hcr_agent_if_configured(void) {
  static const repro_hcr_agent_symbol symbols[] = {
      {"reprobuild_hcr_patchable_value", (void *)&reprobuild_hcr_patchable_value},
  };
  int rc = repro_hcr_agent_start_polling_from_env(
      "macos-arm64-direct-hcr-in-codetracer-v1", symbols,
      sizeof(symbols) / sizeof(symbols[0]));
  if (rc != 0) {
    fprintf(stderr, "failed to start Reprobuild HCR agent: %d\n", rc);
  }
}

static int loop_limit(void) {
  const char *raw = getenv("RB_HCR_FIXTURE_ITERATIONS");
  if (raw == NULL || raw[0] == '\0') {
    return 4000;
  }

  char *end = NULL;
  long parsed = strtol(raw, &end, 10);
  if (end == raw || parsed <= 0 || parsed > 1000000) {
    return 4000;
  }
  return (int)parsed;
}

__attribute__((noinline)) static int retained_old_frame_anchor(int observed) {
  int retained_identity = observed + 1000; /* REPROBUILD_HCR_RETAINED_OLD_FRAME */
  usleep(1000);
  return retained_identity;
}

int main(void) {
  start_hcr_agent_if_configured();
  write_ready_file();

  int last_value = 0;
  int last_generation = -1;
  int old_frame_identity = 0;
  int iterations = loop_limit();

  for (int iteration = 0; iteration < iterations; iteration++) {
    int value = reprobuild_hcr_patchable_value(iteration);
    int observable_value = value; /* REPROBUILD_HCR_OBSERVED_VALUE */
    int generation = (observable_value - iteration == 77) ? 1 : 0;

    if (generation == 0) {
      old_frame_identity = retained_old_frame_anchor(observable_value);
    }

    printf("{\"iteration\":%d,\"generation\":%d,\"value\":%d,\"oldFrameIdentity\":%d}\n",
           iteration, generation, observable_value, old_frame_identity);
    fflush(stdout);
    (void)repro_hcr_agent_poll();

    last_value = observable_value;
    last_generation = generation;
    usleep(10000);
  }

  fprintf(stderr, "completed hcr fixture: generation=%d value=%d\n", last_generation, last_value);
  return 0;
}
