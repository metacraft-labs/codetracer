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

  /**
   * The empty-state note, shown in place of the track when the recording's
   * extent is not known yet. Added for issue #693 — before it, a recording
   * with no known extent still drew a track whose min and max were both 0.
   */
  emptyState(): Locator {
    return this.root.locator(".timeline-empty").first();
  }

  /** Every event marker on the track: calls, returns and errors. */
  markers(): Locator {
    return this.root.locator(".timeline-marker");
  }

  /** Event markers of one kind — "call", "return" or "exception". */
  markersOfKind(kind: "call" | "return" | "exception"): Locator {
    return this.root.locator(`.timeline-marker[data-marker-kind="${kind}"]`);
  }

  /** The numbers written along the track at the current zoom level. */
  tickLabels(): Locator {
    return this.root.locator(".timeline-tick-label");
  }

  /**
   * How many marks the ViewModel produced, which is NOT always how many are
   * in the DOM: the view caps the rendered set, and reports the real total
   * here so the truncation is visible.
   */
  async markerCount(): Promise<number> {
    return this.requiredIntegerAttr("data-marker-count");
  }

  /**
   * Drag the playhead from one tick to another, which is what
   * `Front-Ends/Electron-GUI.md:156` ("Drag to seek") asks for and what a
   * plain `click` does not exercise.
   */
  async dragFromTickToTick(fromTick: number, toTick: number): Promise<void> {
    const min = await this.minTicks();
    const max = await this.maxTicks();
    if (max <= min) {
      throw new Error(`timeline has no seekable range: min=${min}, max=${max}`);
    }
    const box = await this.track().boundingBox();
    if (box === null || box.width <= 0 || box.height <= 0) {
      throw new Error("timeline track is not laid out");
    }
    const xFor = (tick: number): number => {
      const fraction = Math.max(0, Math.min(1, (tick - min) / (max - min)));
      return box.x + Math.max(0, Math.min(box.width, box.width * fraction));
    };
    const y = box.y + box.height / 2;
    await this.page.mouse.move(xFor(fromTick), y);
    await this.page.mouse.down();
    // An intermediate move, so the drag is a drag rather than a press and a
    // release at two coordinates.
    await this.page.mouse.move((xFor(fromTick) + xFor(toTick)) / 2, y);
    await this.page.mouse.move(xFor(toTick), y);
    await this.page.mouse.up();
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
    const position = {
      x: Math.max(0, Math.min(box.width, box.width * fraction)),
      y: box.height / 2,
    };
    const track = this.track();
    try {
      await track.click({ position, timeout: 5_000 });
    } catch {
      await track.evaluate((element, fallbackPosition) => {
        const rect = element.getBoundingClientRect();
        element.dispatchEvent(
          new MouseEvent("click", {
            bubbles: true,
            cancelable: true,
            view: window,
            clientX: rect.left + fallbackPosition.x,
            clientY: rect.top + fallbackPosition.y,
          }),
        );
      }, position);
    }
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
