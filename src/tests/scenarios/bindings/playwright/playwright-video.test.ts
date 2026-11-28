// The desktop binding asks Playwright for a video of the pages it opens only
// when the arm does not record them itself.
//
// DemoVideoScript-Playwright's arm records every page while a recording runs
// and says so with `ctx.recordsPages`; a second, Playwright, recording of the
// same window would only cost CPU on a loaded host. An older arm (the one the
// CI lanes pin) copies the page's Playwright video into the run as its
// recording, which the lanes upload with a failed run, so the binding still
// asks for it there. The context here is the arm's own context object as the
// binding receives it, reduced to the one field the choice reads; no stand-in
// replaces any behaviour.
//
// Run: node src/tests/scenarios/bindings/playwright/playwright-video.test.ts

import { playwrightVideo } from "./codetracer-binding.ts";

let failures = 0;
const check = (ok: boolean, what: string) => {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${what}`);
  if (!ok) failures++;
};

const size = { width: 1600, height: 1000 };

// an arm that records the pages itself: no second recording
const own = playwrightVideo({ recordsPages: true }, "/runs/video", size);
check(!("recordVideo" in own), "an arm that records pages itself gets no recordVideo option");

// an arm that copies Playwright's video (the CI lanes' pin): the video stays
const ci = playwrightVideo({ videoDir: "/runs/video" }, "/runs/video", size);
check(ci.recordVideo?.dir === "/runs/video", "an older arm's run keeps Playwright's video, in the run's video directory");
check(ci.recordVideo?.size.width === 1600 && ci.recordVideo?.size.height === 1000,
      "at the window's size");

// anything but an explicit `true` is an older arm
check("recordVideo" in playwrightVideo({ recordsPages: "yes" }, "/v", size), "only recordsPages === true skips it");

if (failures) {
  console.log(`${failures} failure(s)`);
  process.exit(1);
}
console.log("playwright-video: ok");
