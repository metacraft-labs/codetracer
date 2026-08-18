/**
 * The negative half of the entry-readiness contract.
 *
 * `readyOnEntryTest` (`lib/fixtures.ts`) is the readiness gate every Electron
 * spec goes through, and its budget has now been argued about three times.
 * Each round of that argument turned on the same claim — "nothing was
 * weakened, an app that never reaches an entry location still fails" — and
 * each round asserted it rather than testing it.  This file tests it, so the
 * next change to that budget has to keep it true instead of restating it.
 *
 * Two ways a launch can fail to become ready, both of which must still be
 * failures and neither of which any positive spec can distinguish from a slow
 * pass:
 *
 *   1. `.location-path` never appears at all — the app did not reach an entry
 *      location.  This is what a wedged launch looks like.
 *   2. `.location-path` is in the DOM with the right text but has no box.
 *      This is the shape of the b27da3947 status-bar regression, where a
 *      blanket `display: none !important` on `#status-base` children hid the
 *      location readout suite-wide.  It is the reason the wait is a
 *      *visibility* wait rather than an attachment wait, and it is the case a
 *      relaxation to `state: "attached"` would silently let through.
 *
 * Both run against a synthetic page rather than the real app, deliberately:
 * the property under test belongs to the wait, and reproducing a genuinely
 * wedged CodeTracer launch on demand is neither possible nor necessary.  This
 * is the one place in the suite where mocking the page is the point — every
 * other spec drives the real Electron app.
 *
 * Each test costs one full budget of wall clock, which is the price of
 * asserting that the budget is really spent before the wait gives up.
 */
import {
  READY_ON_ENTRY_BUDGET_MS,
  readyOnEntryTest as readyOnEntry,
  test,
  expect,
} from "../../lib/fixtures";

test.setTimeout(180_000);

/** Run `readyOnEntryTest` against `html` and return [failure message, ms]. */
async function readinessFailure(
  page: import("@playwright/test").Page,
  html: string,
): Promise<{ message: string; elapsedMs: number }> {
  await page.setContent(html);
  const started = Date.now();
  let message = "";
  try {
    await readyOnEntry(page);
  } catch (failure) {
    message = (failure as Error).message;
  }
  return { message, elapsedMs: Date.now() - started };
}

test("ready_on_entry_fails_when_the_location_readout_never_appears", async ({
  page,
}) => {
  const { message, elapsedMs } = await readinessFailure(
    page,
    "<html><body><div id='not-a-status-bar'></div></body></html>",
  );
  expect(
    message,
    "readyOnEntryTest must still fail when .location-path never appears",
  ).not.toBe("");
  // The whole budget must be spent before giving up — a wait that bails early
  // would turn slow launches back into failures.
  expect(elapsedMs).toBeGreaterThanOrEqual(READY_ON_ENTRY_BUDGET_MS - 500);
  // ...and the message must say which budget was spent and what it saw, or
  // the next person to hit this has a bare timeout again.
  expect(message).toContain(`Timeout ${READY_ON_ENTRY_BUDGET_MS}ms exceeded`);
  expect(message).toContain("readyOnEntry diagnosis:");
  expect(message).toContain(".location-path matches=0");
  expect(message).toContain("the element is absent from this page");
});

test("ready_on_entry_fails_when_the_location_readout_is_present_but_hidden", async ({
  page,
}) => {
  const { message, elapsedMs } = await readinessFailure(
    page,
    "<html><body>" +
      "<div class='location-path' style='display:none'>main.c:12#3</div>" +
      "</body></html>",
  );
  expect(
    message,
    "an attached-but-invisible .location-path must not count as ready",
  ).not.toBe("");
  expect(elapsedMs).toBeGreaterThanOrEqual(READY_ON_ENTRY_BUDGET_MS - 500);
  expect(message).toContain(`Timeout ${READY_ON_ENTRY_BUDGET_MS}ms exceeded`);
  // The element was found on every poll, so Playwright's call log must carry
  // the `locator resolved to hidden` lines.  Their ABSENCE in the test above
  // is what makes a bare "no `locator resolved to`" observation meaningless
  // as evidence about the poll.
  expect(message).toContain("locator resolved to hidden");
  expect(message).toContain(".location-path matches=1");
  // The diagnosis must name this as a boxless element rather than filing it
  // under a harness oddity.
  expect(message).toContain("IS in the DOM but has no box");
});
