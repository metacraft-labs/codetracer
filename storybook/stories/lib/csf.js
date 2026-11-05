// The StoryBook side of a CodeTracer story: a CSF story object over
// `./surfaces.js`. The generated story files (`../generated/`, written from
// `src/frontend/stories/codetracer_stories.nim` by
// `tools/stories/emit_storybook_stories.nim`) call `story` once per declared
// story; nothing else creates one.
import { expect } from "@storybook/test";
import { ensureComponentsLoaded, renderSurface, tick } from "./surfaces.js";
import { plays } from "./plays.js";

/**
 * A CSF story for one declared CodeTracer story.
 *
 * `check` names an extra play check in `./plays.js`, run after the default
 * one (the surface mounted). An unknown name fails the story, so a
 * declaration cannot point at a check that does not exist and pass anyway.
 * `frameTitle` is the panel's own name for its golden-layout tab, where the
 * story's name says which state it shows; null: the story's name.
 */
export function story(kind, name, fixture = "populated", storyName = null, check = "", frameTitle = null) {
  const extra = check ? plays[check] : null;
  return {
    name: storyName ?? name,
    render: () => renderSurface(kind, name, fixture, frameTitle ?? storyName),
    play: async (context) => {
      if (check && typeof extra !== "function") {
        throw new Error(`story ${storyName ?? name}: no play check named "${check}" in lib/plays.js`);
      }
      const { canvasElement } = context;
      await ensureComponentsLoaded();
      await tick();
      const surface = canvasElement.querySelector(".lm_goldenlayout, .ct-storybook-frame > *");
      expect(surface).toBeTruthy();
      if (extra) await extra(context);
    },
  };
}
