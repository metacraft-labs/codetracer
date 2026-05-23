import type { Locator, Page } from "@playwright/test";

export class TimelinePane {
  readonly page: Page;
  readonly root: Locator;
  readonly tabButtonText: string;

  constructor(page: Page, root: Locator, tabButtonText: string) {
    this.page = page;
    this.root = root;
    this.tabButtonText = tabButtonText;
  }

  tabButton(): Locator {
    return this.page.locator(".lm_title", { hasText: this.tabButtonText }).first();
  }

  async clickTab(): Promise<void> {
    try {
      await this.tabButton().click({ timeout: 5_000 });
    } catch {
      await this.tabButton().dispatchEvent("click");
    }
  }

  track(): Locator {
    return this.root.locator(".timeline-track").first();
  }

  async minTicks(): Promise<number> {
    return this.requiredIntegerAttr("data-min-rr-ticks");
  }

  async maxTicks(): Promise<number> {
    return this.requiredIntegerAttr("data-max-rr-ticks");
  }

  async currentTicks(): Promise<number> {
    return this.requiredIntegerAttr("data-current-rr-ticks");
  }

  async clickTick(tick: number): Promise<void> {
    const min = await this.minTicks();
    const max = await this.maxTicks();
    if (max <= min) {
      throw new Error(`timeline has no seekable range: min=${min}, max=${max}`);
    }
    const box = await this.track().boundingBox();
    if (box === null || box.width <= 0 || box.height <= 0) {
      throw new Error("timeline track is not laid out");
    }
    const fraction = Math.max(0, Math.min(1, (tick - min) / (max - min)));
    await this.track().click({
      position: {
        x: Math.max(0, Math.min(box.width, box.width * fraction)),
        y: box.height / 2,
      },
    });
  }

  private async requiredIntegerAttr(attrName: string): Promise<number> {
    const raw = await this.track().getAttribute(attrName);
    const parsed = Number(raw);
    if (!Number.isInteger(parsed)) {
      throw new Error(`timeline track missing integer ${attrName}: ${raw}`);
    }
    return parsed;
  }
}
