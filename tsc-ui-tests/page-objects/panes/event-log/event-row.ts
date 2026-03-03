import type { Locator } from "@playwright/test";
import { debugLogger } from "../../../lib/debug-logger";

export enum EventElementType {
  NotSet = "NotSet",
  EventLog = "EventLog",
  TracePointEditor = "TracePointEditor",
}

/**
 * Represents a single row within the event log.
 *
 * Port of ui-tests/PageObjects/Panes/EventLog/EventRow.cs
 */
export class EventRow {
  readonly root: Locator;
  readonly elementType: EventElementType;

  constructor(root: Locator, elementType: EventElementType) {
    this.root = root;
    this.elementType = elementType;
  }

  async tickCount(): Promise<number> {
    const text = await this.root.locator(".rr-ticks-time").textContent();
    return text ? parseInt(text, 10) || 0 : 0;
  }

  async index(): Promise<number> {
    const text = await this.root.locator(".eventLog-index").textContent();
    return text ? parseInt(text, 10) || 0 : 0;
  }

  async consoleOutput(): Promise<string> {
    const selector =
      this.elementType === EventElementType.TracePointEditor
        ? ".trace-values"
        : ".eventLog-text";
    return (await this.root.locator(selector).textContent()) ?? "";
  }

  async isHighlighted(): Promise<boolean> {
    const classes = (await this.root.getAttribute("class")) ?? "";
    if (
      classes.includes("eventLog-selected") ||
      classes.includes("event-selected") ||
      classes.includes("active") ||
      classes.includes("selected")
    ) {
      return true;
    }

    const ariaSelected = (await this.root.getAttribute("aria-selected")) ?? "";
    return ariaSelected.toLowerCase() === "true";
  }

  async click(): Promise<void> {
    const idx = await this.index();
    debugLogger.log(`EventRow: clicking row index ${idx}`);
    await this.root.click();
    debugLogger.log(`EventRow: click completed for row index ${idx}`);
  }
}
