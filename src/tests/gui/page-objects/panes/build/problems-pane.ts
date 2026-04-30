import type { Locator, Page } from "@playwright/test";

/**
 * Page object for the Problems panel (BP-M4).
 *
 * Wraps the `.problems-panel` DOM element and provides helpers to query
 * individual problem rows, filter controls, and severity counts.
 */
export class ProblemsPane {
  readonly page: Page;
  readonly root: Locator;

  constructor(page: Page) {
    this.page = page;
    this.root = page.locator(".problems-panel");
  }

  /** All problem rows visible in the panel. */
  rows(): Locator {
    return this.root.locator(".problems-row");
  }

  /** Problem rows with error severity. */
  errorRows(): Locator {
    return this.root.locator(".problems-severity-error");
  }

  /** Problem rows with warning severity. */
  warningRows(): Locator {
    return this.root.locator(".problems-severity-warning");
  }

  /** The "No problems detected." empty-state message. */
  emptyMessage(): Locator {
    return this.root.locator(".problems-empty");
  }

  /** Filter button by label text (e.g. "All", "Errors", "Warnings"). */
  filterButton(label: string): Locator {
    return this.root.locator(".problems-filter-btn", { hasText: label });
  }

  /** The "Group by File" toggle button. */
  groupByFileButton(): Locator {
    return this.filterButton("Group by File");
  }

  /** File group headers (visible when grouped by file). */
  fileGroupHeaders(): Locator {
    return this.root.locator(".problems-file-header");
  }

  /** Whether the problems panel root is present in the DOM. */
  async isPresent(): Promise<boolean> {
    return (await this.root.count()) > 0;
  }

  /** Whether the problems panel root is visible. */
  async isVisible(): Promise<boolean> {
    if (!(await this.isPresent())) {
      return false;
    }
    return this.root.first().isVisible();
  }
}
