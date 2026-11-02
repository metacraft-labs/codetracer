/* eslint-disable @typescript-eslint/no-magic-numbers */

import type { Locator, Page } from "@playwright/test";
import { CodetracerTestError } from "../lib/fixtures";
import { retry } from "../lib/retry-helpers";

export interface SimpleLocation {
  path: string;
  line: number;
}

/**
 * Parse the status bar's location text, `<path>:<line>#<rest>`, or return
 * `null` when it holds no location (empty, or still loading).
 */
export function parseStatusLocation(raw: string): SimpleLocation | null {
  const tokens = raw.split("#");
  if (tokens.length < 2) return null;
  const pathAndLine = tokens[0];
  // Split on the LAST colon: the location text is
  // ``<path>:<line>`` and on Windows ``<path>`` itself contains
  // a drive-letter colon (e.g. ``D:\repo\src\main.nr:17``).  A
  // naive ``split(":")[0/1]`` would yield ``"D"`` / the rest of
  // the path and never parse the line number.
  const lastColon = pathAndLine.lastIndexOf(":");
  if (lastColon <= 0) return null;
  const line = parseInt(pathAndLine.slice(lastColon + 1), 10);
  if (isNaN(line)) return null;
  return { path: pathAndLine.slice(0, lastColon), line };
}

export class StatusBar {
  readonly page: Page;
  readonly base: Locator;
  readonly locationBox: Locator;

  public constructor(page: Page, base: Locator) {
    this.page = page;
    this.base = base;
    this.locationBox = base.locator(".location-path");
  }

  async rawLocation(): Promise<string> {
    const count = await this.locationBox.count();
    if (count === 0) return "";
    try {
      return (await this.locationBox.textContent({ timeout: 5_000 })) ?? "";
    } catch {
      return "";
    }
  }

  /**
   * The text of every notification toast the status bar shows right now
   * (`#active-notifications`, rendered by `isonim_status_view.nim`).
   *
   * Toasts without an action dismiss themselves after
   * `activeNotificationDuration` (3 s), so a caller that needs one must poll
   * this rather than read it once. The backend's launch failures reach the
   * user here: `send_launch_failure_notification` in
   * `src/db-backend/src/dap_server.rs` sends them as `ct/notification`.
   */
  async activeNotificationTexts(): Promise<string[]> {
    return this.page
      .locator("#active-notifications .status-notification .notification-message")
      .allInnerTexts();
  }

  async location(): Promise<SimpleLocation> {
    let result: SimpleLocation | null = null;
    await retry(
      async () => {
        result = parseStatusLocation(await this.rawLocation());
        return result !== null;
      },
      { maxAttempts: 20, delayMs: 300 },
    );
    if (!result) {
      throw new CodetracerTestError("couldn't parse status location after retries");
    }
    return result;
  }
}
