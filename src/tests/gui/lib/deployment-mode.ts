/**
 * How a GUI test reaches CodeTracer, and the run-wide switch that picks it.
 *
 * `"electron"` launches the real Electron app through the `ct` binary;
 * `"web"` starts `ct host` and drives it from Chromium. A spec chooses with
 * `test.use({ deploymentMode: "web" })`. A spec that does not choose gets the
 * default this module computes from `CODETRACER_TEST_IN_BROWSER`, so a whole
 * run can be moved to web mode without editing any spec.
 *
 * Kept free of other imports so that both `fixtures.ts` and the harness
 * self-test (`tests/harness/deployment-mode-env.spec.ts`) can load it without
 * pulling in the launch machinery.
 */

/** Electron app (`ct` launching Electron) or web (`ct host` + Chromium). */
export type DeploymentMode = "electron" | "web";

/** The environment variable that sets the run-wide default deployment mode. */
export const TEST_IN_BROWSER_ENV = "CODETRACER_TEST_IN_BROWSER";

/**
 * The default deployment mode for a run, read from
 * `CODETRACER_TEST_IN_BROWSER`:
 *
 * - `"1"` selects `"web"`;
 * - unset, `""` or `"0"` select `"electron"`.
 *
 * Any other value throws. The variable once silently did nothing, so a run
 * that asked for web mode quietly ran Electron instead; a typo such as
 * `true` or `yes` falling back to Electron would be the same defect again,
 * so it fails loudly and names the accepted values instead.
 *
 * A per-spec `test.use({ deploymentMode })` overrides this default.
 *
 * @param env the environment to read; `process.env` by default.
 * @throws Error when the variable holds a value other than `""`, `"0"`, `"1"`.
 */
export function deploymentModeFromEnv(
  env: Record<string, string | undefined> = process.env,
): DeploymentMode {
  const value = env[TEST_IN_BROWSER_ENV];
  if (value === undefined || value === "" || value === "0") return "electron";
  if (value === "1") return "web";
  throw new Error(
    `${TEST_IN_BROWSER_ENV}=${JSON.stringify(value)} is not a valid value: ` +
      `use "1" to run tests in web mode, or "0", "" or unset for Electron`,
  );
}
