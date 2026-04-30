import type { Locator } from "@playwright/test";

/**
 * Wrapper around the omniscient loop control UI attached to editor lines.
 *
 * Port of ui-tests/PageObjects/Panes/Editor/OmniscientLoopControls.cs
 */
export class OmniscientLoopControls {
  readonly root: Locator;

  constructor(root: Locator) {
    this.root = root;
  }

  backwardButton(): Locator {
    return this.root.locator(".flow-loop-button.backward");
  }

  forwardButton(): Locator {
    return this.root.locator(".flow-loop-button.forward");
  }

  sliderContainer(): Locator {
    return this.root.locator(".flow-loop-slider-container");
  }

  slider(): Locator {
    return this.sliderContainer().locator(".flow-loop-slider");
  }

  stepContainer(): Locator {
    return this.root.locator(".flow-loop-step-container");
  }

  shrinkedIterationContainer(): Locator {
    return this.root.locator(".flow-loop-shrinked-iteration");
  }

  continuousIterationContainer(): Locator {
    return this.root.locator(".flow-loop-continuous-iteration");
  }
}
