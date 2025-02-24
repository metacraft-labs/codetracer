/* eslint-disable @typescript-eslint/no-magic-numbers */

import type { Locator, Page } from "@playwright/test";
import { CodetracerTestError } from "../lib/ct_helpers";

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
    const raw = await this.page.$eval(".location-path", (el) => el.textContent);
    return raw ?? "";
  }

  async location(): Promise<SimpleLocation> {
    const raw = await this.rawLocation();
    const tokens = raw.split("#");
    if (tokens.length > 1) {
      const pathAndLine = tokens[0];
      const pathAndLineTokens = pathAndLine.split(":");
      if (pathAndLineTokens.length > 1) {
        const path = pathAndLineTokens[0];
        const line = parseInt(pathAndLineTokens[1], 10);
        return { path, line };
      }
    }
    throw new CodetracerTestError("couldn't parse status location");
  }
}
