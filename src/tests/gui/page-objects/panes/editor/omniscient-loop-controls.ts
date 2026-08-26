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

  /**
   * The element noUiSlider itself injects into `.flow-loop-slider`.
   *
   * Locating only the container (`slider()`) is NOT enough to tell whether a
   * slider exists: `.flow-loop-slider` is created by our own code before
   * noUiSlider runs, so it is present even when slider creation was skipped or
   * threw. Issue #562 was reported fixed three separate times on the strength
   * of assertions that only ever saw the container.
   *
   * `.noUi-base` exists only if `noUiSlider.create()` actually ran.
   */
  sliderBase(): Locator {
    return this.slider().locator(".noUi-base");
  }

  /**
   * Asserts the slider is not merely present but has a real on-screen box.
   *
   * The other half of #562: the slider used to be created while its Monaco view
   * zone had not been laid out, so it ended up 0 px wide at a negative offset —
   * in the DOM, invisible on screen. Returns the measured width.
   */
  async sliderWidth(): Promise<number> {
    const box = await this.slider().boundingBox();
    return box ? box.width : 0;
  }

  /**
   * The editable iteration number ("iteration [N] from M").
   */
  iterationValue(): Locator {
    return this.root.locator(".flow-loop-textarea");
  }

  /**
   * The total-iterations label ("from M").
   */
  iterationTotal(): Locator {
    return this.root.locator(".flow-parallel-loop-iteration-end");
  }

  /**
   * Current iteration as an integer, read from the textarea's live value.
   */
  async currentIteration(): Promise<number> {
    const raw = await this.iterationValue().inputValue();
    return Number.parseInt(raw, 10);
  }

  /**
   * Total iterations as an integer, parsed out of the "from M" label.
   */
  async totalIterations(): Promise<number> {
    const raw = (await this.iterationTotal().innerText()).trim();
    const match = /(-?\d+)/.exec(raw);
    if (!match) {
      throw new Error(`could not parse an iteration total out of "${raw}"`);
    }
    return Number.parseInt(match[1], 10);
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
