// pane_mount_probe.mjs — how many times is each auto-hide pane in the DOM?
//
// `ui/layout.nim`'s standalone auto-hide registration builds one wrapper per
// pane inside `#auto-hide-standalone-host`, a div parked at `left: -9999px` so
// mounts keep measurable dimensions while hidden (`layout.nim:1715-1721`). One
// copy there is by design. TWO elements carrying the same component id is not:
// `ui/errors.nim`'s `tryMountIsoNimErrorsPanel` resolves its container with
// `getElementById`, which returns the FIRST match, and `mountIsoNimErrors`
// (`views/isonim_errors_view.nim:289`) has no owner and no disposal — so a
// remount that resolves to a different node leaves the previous subtree live.
//
// The id is what this measures, because the id is what the mount resolves.

import { chromium } from 'playwright';

const url = process.argv[2];
const settleMs = Number(process.argv[3] || 9000);
if (!url) {
  console.error('usage: pane_mount_probe.mjs <url> [settleMs]');
  process.exit(2);
}

const browser = await chromium.launch({});
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
const pageErrors = [];
page.on('pageerror', (e) =>
  pageErrors.push(String((e && e.message) || e).slice(0, 300)));

// THE PRECONDITION THE DEFECT NEEDS, reconstructed rather than waited for.
//
// `layout.nim`'s standalone registration asks two questions in sequence:
//
//     if not glContainerDiv.isNil and not glContainerDiv.parentNode.isNil:
//       let component = data.ui.componentMapping[panelDef.content][0]
//       if not component.isNil and not component.layoutItem.isNil:
//         pinPanel(...); continue
//     # ... otherwise CREATE A SECOND div with the same id
//
// The `continue` sits under the INNER `if`, so the state "GoldenLayout has
// already emitted the container, but the component's `layoutItem` is not
// populated yet" falls through to the create branch and produces a duplicate
// id. That state is reachable on any layout saved with the pane docked —
// `layoutItem` is only assigned from GL's tab callback (`layout.nim:1013`,
// `:1174`) and the component itself is built inside a deferred
// `windowSetTimeout` (`layout.nim:1264`), while this loop runs on its own
// fixed 500 ms timer. Two independent timers deciding one mutually exclusive
// question.
//
// The web bundle's DEFAULT layout does not contain the pane, so GL never makes
// the container and the outer `if` is simply false — which is why the shipped
// `/noir` page shows one of each. Planting the container is how this gate
// measures the docked-layout case without shipping a second layout fixture:
// it supplies exactly the one fact the outer condition tests, and nothing
// else. `data.ui.componentMapping[...].layoutItem` stays nil on its own,
// because nothing here is a real GL tab.
const plant = process.env.CT_PLANT_GL_CONTAINER || '';
if (plant) {
  await page.addInitScript((id) => {
    const install = () => {
      if (document.getElementById(id)) return;
      const d = document.createElement('div');
      d.id = id;
      d.className = 'component-container';
      // Attached, because the outer condition also tests `parentNode`.
      (document.getElementById('root-container') || document.body)
        .appendChild(d);
    };
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', install);
    } else {
      install();
    }
  }, plant);
}

// A CHECK ON THE INSTRUMENT, and it is the reason the green arms above mean
// anything. Every assertion this probe feeds is of the form "count == 1", and
// a counter that could never return 2 would satisfy all of them over a page
// with any number of duplicates. This plants a genuine duplicate — two nodes,
// one id — so the gate can show the count going to 2 on demand. It is
// deliberately planted LATE (after settle) rather than at init, so it cannot
// perturb the product's own registration and be mistaken for the defect.
const dup = process.env.CT_PLANT_DUPLICATE_ID || '';

let loadError = '';
try {
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  await page.waitForTimeout(settleMs);
} catch (e) {
  loadError = String((e && e.message) || e).slice(0, 300);
}

if (dup) {
  await page.evaluate((id) => {
    const d = document.createElement('div');
    d.id = id;
    d.className = 'component-container ct-probe-planted-duplicate';
    document.body.appendChild(d);
  }, dup);
}

const report = await page.evaluate(() => {
  // The four panes `layout.nim`'s `standaloneAutoHidePanels` registers. All
  // four are measured, not just Problems: the fall-through that duplicates an
  // id is written once and runs for every entry, so a check on one of them
  // would under-report the defect it is looking for.
  const LABELS = [
    'buildComponent-0',
    'errorsComponent-0',
    'searchResultsComponent-0',
    'requestPanelComponent-0',
  ];
  const host = document.getElementById('auto-hide-standalone-host');
  return {
    hostPresent: !!host,
    hostLeft: host ? getComputedStyle(host).left : '',
    panes: LABELS.map((id) => {
      // `querySelectorAll` by id attribute, NOT getElementById — the whole
      // point is to count duplicates, and getElementById can only ever see
      // the first one.
      const all = Array.from(document.querySelectorAll(`[id="${id}"]`));
      return {
        id,
        count: all.length,
        // Where each copy lives, so "one in GoldenLayout and one parked
        // offscreen" is distinguishable from "two in the same place".
        placements: all.map((el) => ({
          inStandaloneHost: !!(host && host.contains(el)),
          inGoldenLayout: !!el.closest('.lm_item_container, .lm_content'),
          childElements: el.querySelectorAll('*').length,
          rectX: Math.round(el.getBoundingClientRect().x),
        })),
      };
    }),
    // The mounted view's own root class, counted independently of the
    // container id: two containers each holding a mounted panel is the
    // failure, and a count of containers alone could not say whether the
    // second one was ever mounted into.
    problemsPanels: document.querySelectorAll('.problems-panel').length,
  };
});

console.log(JSON.stringify({ url, loadError, pageErrors, report }, null, 2));
await browser.close();
