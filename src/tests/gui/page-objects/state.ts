/* eslint-disable @typescript-eslint/no-magic-numbers */

import type { Locator, Page } from "@playwright/test";
// import { wait, CodetracerTestError } from "../lib/ct_helpers";

export interface StatePanelNamedValue {
  text: string;
  typeText: string;
}

// TODO: work with specific state panel?
// for now this is assuming a single state panel and
// using global locators
export class StatePanel {
  readonly page: Page;

  public constructor(page: Page) {
    this.page = page;
  }

  codeStateLine(): Locator {
    // TODO: specific state panel? this is a global selector
    return this.page.locator("#code-state-line-0");
  }

  async values(): Promise<Record<string, StatePanelNamedValue>> {
    // TODO: what about non-atom/non-expanded?
    const valueLocators = await this.page
      .locator(".value-expanded-atom-parent")
      .all();

    const values: Record<string, StatePanelNamedValue> = {};
    for (const valueLocator of valueLocators) {
      const rawExpr =
        (await valueLocator.locator(".value-name").textContent()) ?? "";

      const expr = rawExpr.endsWith(": ")
        ? rawExpr.slice(0, rawExpr.length - 2)
        : "";

      if (expr.length > 0) {
        values[expr] = {
          text:
            (await valueLocator
              .locator(".value-expanded-text")
              .textContent()) ?? "",
          typeText:
            (await valueLocator.locator(".value-type").textContent()) ?? "",
        };
      }
    }

    return values;
  }
}
