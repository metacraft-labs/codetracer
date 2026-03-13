/* eslint-disable @typescript-eslint/no-magic-numbers */

import type { Locator, Page } from "@playwright/test";
import { CodetracerTestError } from "../lib/fixtures";
import { retry } from "../lib/retry-helpers";

interface SimpleLocation {
  path: string;
  line: number;
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

  async location(): Promise<SimpleLocation> {
    let result: SimpleLocation | null = null;
    await retry(
      async () => {
        const raw = await this.rawLocation();
        const tokens = raw.split("#");
        if (tokens.length > 1) {
          const pathAndLine = tokens[0];
          const pathAndLineTokens = pathAndLine.split(":");
          if (pathAndLineTokens.length > 1) {
            const path = pathAndLineTokens[0];
            const line = parseInt(pathAndLineTokens[1], 10);
            if (!isNaN(line)) {
              result = { path, line };
              return true;
            }
          }
        }
        return false;
      },
      { maxAttempts: 20, delayMs: 300 },
    );
    if (!result) {
      throw new CodetracerTestError("couldn't parse status location after retries");
    }
    return result;
  }
}
