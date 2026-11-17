/**
 * Waiting for a debugger operation to finish, read from the status bar.
 *
 * `#stable-status` is drawn ONLY WHILE AN OPERATION IS IN FLIGHT: since
 * `74caaa788b` the status view renders it under `if model.base.stableBusy`
 * (`viewmodel/views/isonim_status_view.nim`), and an idle bar has none. A wait
 * for it to carry `ready-status` therefore never ends: when the operation is
 * over the element is gone, not "ready". That is the same staleness the
 * footer guards had (codetracer-pm
 * `issues/2026-10-20-footer-visibility-guard-red-after-ui-design-work.md`).
 *
 * "Not busy" alone cannot tell "finished" from "not started yet": the busy
 * flag reaches the bar asynchronously after the button press. A move is
 * therefore awaited by what it does — the recording's position changes — and
 * only then by the bar going idle.
 */
import type { Page } from "@playwright/test";
import { expect } from "@playwright/test";

/**
 * The status bar's position readout, `<path>:<line>#<ticks>`. The readout is
 * hidden on purpose (`status_bar.styl`, D-05 in `docs/UI-Design-Decisions.md`)
 * but still rendered and kept current, so its text is the recording's
 * position. "" while there is none.
 */
export async function statusLocation(page: Page): Promise<string> {
  const box = page.locator("#status-base .location-path").first();
  if ((await box.count()) === 0) return "";
  return ((await box.textContent()) ?? "").trim();
}

/** True while the bar shows an operation in flight. */
export async function statusBusy(page: Page): Promise<boolean> {
  const status = page.locator("#stable-status");
  if ((await status.count()) === 0) return false;
  const className = (await status.first().getAttribute("class")) ?? "";
  return !className.includes("ready-status");
}

/** Wait until no operation is in flight. */
export async function waitForNotBusy(page: Page, timeoutMs = 30_000): Promise<void> {
  await expect
    .poll(() => statusBusy(page), {
      message: "the status bar still shows an operation in flight",
      timeout: timeoutMs,
    })
    .toBe(false);
}

/**
 * Run `action` — a debugger move (Next, Continue, a jump) — and wait until
 * the recording's position differs from where it was before, then until the
 * bar is idle. Returns the new position. Fails, naming the position, when
 * the move never moves: a step that is silently a no-op must not read as a
 * step.
 */
export async function moveAndSettle(
  page: Page,
  action: () => Promise<void>,
  timeoutMs = 30_000,
): Promise<string> {
  const before = await statusLocation(page);
  await action();
  await expect
    .poll(() => statusLocation(page), {
      message: `the position did not move from "${before}"`,
      timeout: timeoutMs,
    })
    .not.toBe(before);
  await waitForNotBusy(page, timeoutMs);
  return statusLocation(page);
}

/**
 * Run `action` — a step that may legitimately leave the position where it
 * was (a micro-step the backend reports at the same line and tick) — and
 * wait for it to settle. Returns whether the position moved.
 *
 * A move is recognised as in `moveAndSettle`. When the position has not
 * moved within `stayWindowMs`, the step is taken to have stayed, and only the
 * bar going idle is awaited. Use `moveAndSettle` wherever the step must move:
 * this helper is for callers that check the movement themselves and have a
 * deliberate answer for a step that stays.
 */
export async function moveOrStayAndSettle(
  page: Page,
  action: () => Promise<void>,
  stayWindowMs = 5_000,
  timeoutMs = 30_000,
): Promise<boolean> {
  const before = await statusLocation(page);
  await action();
  let moved = false;
  try {
    await expect
      .poll(() => statusLocation(page), { timeout: stayWindowMs })
      .not.toBe(before);
    moved = true;
  } catch {
    moved = false;
  }
  await waitForNotBusy(page, timeoutMs);
  return moved;
}
