// menu_and_context_menu_probe.mjs — drives a real tab against an assembled
// web bundle and reports, as JSON, what a user would see when they open the
// main menu and when they right-click the editor.
//
// It MEASURES and does not judge; `menu-and-context-menu-in-browser.sh` owns
// the assertions, so the same probe can be run against the baseline tree and
// the patched one and the two reports compared.
//
// Usage: node menu_and_context_menu_probe.mjs <url> [--shots <dir>]
import { chromium } from "playwright";

const url = process.argv[2];
const shotsIdx = process.argv.indexOf("--shots");
const shots = shotsIdx > 0 ? process.argv[shotsIdx + 1] : null;
if (!url) {
  console.error("usage: menu_and_context_menu_probe.mjs <url> [--shots dir]");
  process.exit(2);
}

const report = { url, faults: [] };
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1500, height: 950 } });
page.on("pageerror", (e) => report.faults.push(String(e).slice(0, 200)));

try {
  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 90000 });

  // ---- non-vacuity: did the product mount at all? -------------------------
  await page
    .waitForFunction(() => !!document.getElementById("navigation-menu"), null, {
      timeout: 90000,
    })
    .catch(() => {});
  await page.waitForTimeout(6000);

  report.mounted = await page.evaluate(() => ({
    navigationMenu: !!document.getElementById("navigation-menu"),
    menuRoot: !!document.getElementById("menu-root"),
    monaco: !!document.querySelector(".monaco-editor"),
  }));

  // =======================================================================
  // PART A — the main menu
  // =======================================================================
  await page.evaluate(() => {
    const w = window;
    w.__probe = { reveals: 0, minOpacity: 1, opacitySamples: 0, rebuilds: 0 };
    document.addEventListener(
      "animationstart",
      (e) => {
        if (e.animationName === "ct-dropdown-reveal") {
          const t = e.target;
          if (
            t.id === "menu-main" ||
            (t.classList && t.classList.contains("menu-nested-elements"))
          ) {
            w.__probe.reveals++;
          }
        }
      },
      true,
    );
    // Count full shell teardowns: #navigation-menu leaving the document.
    const host = document.getElementById("menu");
    if (host) {
      new MutationObserver((recs) => {
        for (const r of recs) {
          for (const n of r.removedNodes) {
            if (n.nodeType === 1 && n.id === "navigation-menu") w.__probe.rebuilds++;
          }
        }
      }).observe(host, { childList: true, subtree: true });
    }
  });

  const rootBox = await page.evaluate(() => {
    const r = document.getElementById("menu-root");
    if (!r) return null;
    const b = r.getBoundingClientRect();
    return { x: Math.round(b.x + b.width / 2), y: Math.round(b.y + b.height / 2) };
  });
  report.menu = { rootBox };

  if (rootBox) {
    await page.mouse.click(rootBox.x, rootBox.y);
    await page.waitForTimeout(700);

    const items = await page.evaluate(() =>
      [...document.querySelectorAll("#menu-elements .ct-menu-item")].map((i) => {
        const b = i.getBoundingClientRect();
        return {
          label: i.textContent.trim().slice(0, 24),
          folder: i.classList.contains("menu-folder"),
          x: Math.round(b.x + b.width / 2),
          y: Math.round(b.y + b.height / 2),
        };
      }),
    );
    report.menu.rootItems = items.map((i) => i.label);
    report.menu.folders = items.filter((i) => i.folder).length;

    // ---- the clip: what does the submenu's own ancestry do to it? --------
    const folder = items.find((i) => i.folder) || items[0];
    report.menu.folderUsed = folder ? folder.label : null;

    if (folder) {
      // HOVER opens it.
      await page.mouse.move(folder.x, folder.y);
      await page.waitForTimeout(150);
      await page.mouse.move(folder.x + 3, folder.y);
      await page.waitForTimeout(600);
      if (shots) await page.screenshot({ path: `${shots}/menu-hover.png` });

      report.menu.hover = await page.evaluate(() => {
        const n = document.getElementById("menu-nested-elements-1");
        const main = document.getElementById("menu-main");
        const out = {
          submenuInDom: !!n,
          menuMainOverflow: main ? getComputedStyle(main).overflow : null,
          rows: n ? n.querySelectorAll(".ct-menu-item").length : 0,
        };
        if (n) {
          const it = n.querySelector(".ct-menu-item");
          if (it) {
            const b = it.getBoundingClientRect();
            const cx = Math.round(b.x + b.width / 2);
            const cy = Math.round(b.y + b.height / 2);
            const top = document.elementFromPoint(cx, cy);
            // Walk UP from the hit-tested element to the submenu.  `contains()`
            // from the other direction passes vacuously on document.body.
            let w = top,
              reached = false,
              d = 0;
            while (w && d < 60) {
              if (w === n) {
                reached = true;
                break;
              }
              w = w.parentElement;
              d++;
            }
            out.rowCentre = { x: cx, y: cy };
            out.hitElement = top
              ? `${top.tagName}#${top.id}.${typeof top.className === "string" ? top.className : ""}`
              : null;
            out.rowIsHitTestable = reached;
            out.rowLabel = it.textContent.trim().slice(0, 24);
          }
        }
        return out;
      });

      // ---- THE MIXIN'S PRECONDITION, as a standing check ------------------
      // `dropdown-surface()` carries `overflow: hidden`, which clips EVERY
      // descendant and not just the rows.  That is what deleted the submenus.
      // This asks the general question of every dropdown surface currently on
      // screen — does any of them clip an absolutely-positioned child? — so a
      // future caller that acquires such a child is caught by this gate rather
      // than by a user.
      //
      // It cannot be asked of the stylesheet: a static pass over the compiled
      // CSS reports ZERO escaping children even for `#menu-main`, because
      // `.menu-nested-elements` is a sibling RULE and a child only in the DOM.
      report.menu.clipCheck = await page.evaluate((SURFACES) => {
        const containers = [];
        const escapes = [];
        for (const sel of SURFACES) {
          for (const c of document.querySelectorAll(sel)) {
            const cs = getComputedStyle(c);
            const cr = c.getBoundingClientRect();
            if (cr.width === 0 || cr.height === 0) continue;
            const abs = [...c.querySelectorAll("*")].filter((d) => {
              const p = getComputedStyle(d).position;
              return p === "absolute" || p === "fixed";
            });
            containers.push({
              sel,
              overflow: `${cs.overflowX}/${cs.overflowY}`,
              absDescendants: abs.length,
            });
            const clipX = cs.overflowX !== "visible";
            const clipY = cs.overflowY !== "visible";
            for (const d of abs) {
              const dr = d.getBoundingClientRect();
              if (dr.width === 0 || dr.height === 0) continue;
              const outX = clipX && (dr.right <= cr.left + 1 || dr.left >= cr.right - 1);
              const outY = clipY && (dr.bottom <= cr.top + 1 || dr.top >= cr.bottom - 1);
              if (outX || outY) {
                escapes.push({
                  container: sel,
                  child: `${d.tagName}#${d.id}.${typeof d.className === "string" ? d.className.slice(0, 40) : ""}`,
                  axis: outX ? "x" : "y",
                  childRect: { x: Math.round(dr.x), y: Math.round(dr.y), w: Math.round(dr.width), h: Math.round(dr.height) },
                  containerRect: { x: Math.round(cr.x), y: Math.round(cr.y), w: Math.round(cr.width), h: Math.round(cr.height) },
                });
              }
            }
          }
        }
        return {
          containersExamined: containers.length,
          // NON-VACUITY: at least one of them must actually HOLD an
          // absolutely-positioned child, or "nothing escaped" is a statement
          // about an empty set.
          withAbsoluteChildren: containers.filter((c) => c.absDescendants > 0).length,
          containers,
          escapes,
        };
      }, [
        "#menu-main",
        ".menu-nested-elements",
        "#context-menu-container",
        ".command-results",
        ".layout-dropdown",
        ".ct-picker-dropdown",
        ".session-tab-overflow-menu",
        ".vcs-branch-dropdown",
      ]);

      // ---- the flicker: sample the menu's opacity across a pointer sweep --
      const others = items.filter((i) => i.label !== folder.label);
      await page.evaluate(() => {
        const w = window;
        w.__probe.reveals = 0;
        w.__probe.minOpacity = 1;
        w.__probe.opacitySamples = 0;
        w.__probe.rebuilds = 0;
        const tick = () => {
          const m = document.getElementById("menu-main");
          if (m) {
            const o = parseFloat(getComputedStyle(m).opacity);
            if (!Number.isNaN(o)) {
              w.__probe.opacitySamples++;
              if (o < w.__probe.minOpacity) w.__probe.minOpacity = o;
            }
          }
          if (w.__probe.sampling) requestAnimationFrame(tick);
        };
        w.__probe.sampling = true;
        requestAnimationFrame(tick);
      });
      for (const it of others) {
        await page.mouse.move(it.x, it.y);
        await page.waitForTimeout(150);
      }
      await page.evaluate(() => {
        window.__probe.sampling = false;
      });
      await page.waitForTimeout(200);
      report.menu.sweep = await page.evaluate(() => ({
        transitions: null,
        revealAnimations: window.__probe.reveals,
        shellRebuilds: window.__probe.rebuilds,
        minMenuOpacity: window.__probe.minOpacity,
        opacitySamples: window.__probe.opacitySamples,
      }));
      report.menu.sweep.transitions = others.length;

      // ---- CLICK, not hover, must also reach a hit-testable submenu ------
      await page.keyboard.press("Escape").catch(() => {});
      await page.mouse.move(900, 700);
      await page.waitForTimeout(300);
      const stillOpen = await page.evaluate(() => !!document.getElementById("menu-main"));
      if (!stillOpen) {
        await page.mouse.click(rootBox.x, rootBox.y);
        await page.waitForTimeout(500);
      }
      await page.mouse.click(folder.x, folder.y);
      await page.waitForTimeout(600);
      if (shots) await page.screenshot({ path: `${shots}/menu-click.png` });
      report.menu.click = await page.evaluate(() => {
        const n = document.getElementById("menu-nested-elements-1");
        if (!n) return { submenuInDom: false, rowIsHitTestable: false };
        const it = n.querySelector(".ct-menu-item");
        if (!it) return { submenuInDom: true, rows: 0, rowIsHitTestable: false };
        const b = it.getBoundingClientRect();
        const cx = Math.round(b.x + b.width / 2);
        const cy = Math.round(b.y + b.height / 2);
        const top = document.elementFromPoint(cx, cy);
        let w = top,
          reached = false,
          d = 0;
        while (w && d < 60) {
          if (w === n) {
            reached = true;
            break;
          }
          w = w.parentElement;
          d++;
        }
        return {
          submenuInDom: true,
          rows: n.querySelectorAll(".ct-menu-item").length,
          rowIsHitTestable: reached,
          hitElement: top ? `${top.tagName}#${top.id}` : null,
        };
      });
    }

    // Close the menu before the context-menu part.
    await page.mouse.click(1200, 800);
    await page.waitForTimeout(400);
  }

  // =======================================================================
  // PART B — the context menu
  // =======================================================================
  // A document-level BUBBLE listener runs after the surface handlers, so
  // `defaultPrevented` here is the fact that decides whether the browser draws
  // its own menu on top of ours.  The native menu itself is browser chrome and
  // is suppressed under automation in every engine, so it cannot be counted
  // from the page; this is the observable that determines it.
  await page.evaluate(() => {
    window.__ctx = { events: [] };
    document.addEventListener(
      "contextmenu",
      (e) => {
        window.__ctx.events.push({
          defaultPrevented: e.defaultPrevented,
          shiftKey: e.shiftKey,
          target: `${e.target.tagName}.${typeof e.target.className === "string" ? e.target.className.slice(0, 60) : ""}`,
        });
      },
      false,
    );
  });

  const readMenu = () =>
    page.evaluate(() => {
      const c = document.getElementById("context-menu-container");
      const visible = !!c && getComputedStyle(c).display !== "none";
      const hint = document.getElementById("context-menu-browser-hint");
      let hintInfo = null;
      if (hint) {
        const cs = getComputedStyle(hint);
        const b = hint.getBoundingClientRect();
        const cx = Math.round(b.x + b.width / 2);
        const cy = Math.round(b.y + b.height / 2);
        const before = document.activeElement;
        try {
          hint.focus();
        } catch (_) {}
        const focusable = document.activeElement === hint;
        try {
          if (before && before.focus) before.focus();
        } catch (_) {}
        hintInfo = {
          text: hint.textContent.trim(),
          classes: hint.className,
          // Size, so "you cannot click it" cannot pass by the row being a
          // zero-area node nobody could see either.
          rect: { w: Math.round(b.width), h: Math.round(b.height) },
          painted: b.width > 0 && b.height > 0 && cs.visibility !== "hidden",
          count: document.querySelectorAll(".context-menu-hint").length,
          hasTabIndexAttr: hint.hasAttribute("tabindex"),
          role: hint.getAttribute("role"),
          ariaHidden: hint.getAttribute("aria-hidden"),
          pointerEvents: cs.pointerEvents,
          cursor: cs.cursor,
          focusable,
          // A click at its own centre must not land on it.
          hitTargetIsHint: document.elementFromPoint(cx, cy) === hint,
          isDeclaredMenuItem:
            hint.classList.contains("context-menu-item") ||
            hint.classList.contains("ct-menu-item"),
        };
      }
      return {
        ourMenuVisible: visible,
        ourMenuCount: visible ? 1 : 0,
        itemCount: c ? c.querySelectorAll(".context-menu-item").length : 0,
        // Everything in the document that reads as an open menu surface.
        visibleMenuSurfaces: [
          ...document.querySelectorAll(
            "#context-menu-container, #menu-main, .menu-nested-elements, .monaco-menu",
          ),
        ].filter((e) => {
          const s = getComputedStyle(e);
          const r = e.getBoundingClientRect();
          return s.display !== "none" && s.visibility !== "hidden" && r.width > 0 && r.height > 0;
        }).length,
        hint: hintInfo,
      };
    });

  const hideMenu = () =>
    page.evaluate(() => {
      const c = document.getElementById("context-menu-container");
      if (c) c.style.display = "none";
      window.__ctx.events.length = 0;
    });

  const textTarget = await page.evaluate(() => {
    const lines = document.querySelector(".monaco-editor .view-lines");
    if (!lines) return null;
    const b = lines.getBoundingClientRect();
    return { x: Math.round(b.x + 60), y: Math.round(b.y + 20) };
  });
  const gutterTarget = await page.evaluate(() => {
    const g =
      document.querySelector(".monaco-editor .margin .line-numbers") ||
      document.querySelector(".monaco-editor .margin");
    if (!g) return null;
    const b = g.getBoundingClientRect();
    return { x: Math.round(b.x + b.width / 2), y: Math.round(b.y + 20) };
  });
  report.context = { textTarget, gutterTarget };

  if (textTarget) {
    await hideMenu();
    await page.mouse.click(textTarget.x, textTarget.y);
    await page.waitForTimeout(200);
    await hideMenu();
    await page.mouse.click(textTarget.x, textTarget.y, { button: "right" });
    await page.waitForTimeout(600);
    if (shots) await page.screenshot({ path: `${shots}/ctx-text.png` });
    report.context.text = {
      ...(await readMenu()),
      events: await page.evaluate(() => window.__ctx.events),
    };

    // Shift+right-click: our handler must stand down entirely.
    await hideMenu();
    await page.keyboard.down("Shift");
    await page.mouse.click(textTarget.x, textTarget.y, { button: "right" });
    await page.keyboard.up("Shift");
    await page.waitForTimeout(600);
    report.context.textShift = {
      ...(await readMenu()),
      events: await page.evaluate(() => window.__ctx.events),
    };
  }

  if (gutterTarget) {
    await hideMenu();
    await page.mouse.click(gutterTarget.x, gutterTarget.y, { button: "right" });
    await page.waitForTimeout(600);
    if (shots) await page.screenshot({ path: `${shots}/ctx-gutter.png` });
    report.context.gutter = {
      ...(await readMenu()),
      events: await page.evaluate(() => window.__ctx.events),
    };
  }
  // =======================================================================
  // PART C — the gutter: one lane, one owner, and no second effect
  // =======================================================================
  // The reported symptom was "clicking the gutter to place a breakpoint also
  // collapses the function".  It does not reproduce — but a test that checked
  // each control WORKS would have passed on the defect as reported, so what is
  // measured here is the ABSENCE of the other effect in each direction.
  await page.evaluate(() => {
    const c = document.getElementById("context-menu-container");
    if (c) c.style.display = "none";
    window.__gut = () => ({
      lines: [...document.querySelectorAll(".margin-view-overlays .gutter-line")].length,
      breakpoints: [...document.querySelectorAll(".margin-view-overlays .gutter")]
        .filter((g) => g.querySelector('[class*="gutter-breakpoint-"]'))
        .map((g) => g.getAttribute("data-line")),
      collapsed: document.querySelectorAll(".codicon-folding-collapsed").length,
    });
  });

  const gutterGeom = await page.evaluate(() => {
    const chev = document.querySelector(".codicon-folding-expanded");
    if (!chev) return null;
    const cr = chev.getBoundingClientRect();
    const rows = [...document.querySelectorAll(".margin-view-overlays > div")];
    const row = rows.find((r) => {
      const rr = r.getBoundingClientRect();
      return cr.top >= rr.top - 1 && cr.bottom <= rr.bottom + 1;
    });
    const gut = row && row.querySelector(".gutter");
    if (!gut) return null;
    const zoneSel = {
      lineNumber: ".gutter-line",
      breakpoint: '[class*="gutter-no-breakpoint"], [class*="gutter-breakpoint-"]',
      tracepoint: '[class*="gutter-no-trace"], [class*="gutter-trace"], [class*="gutter-disabled-trace"]',
    };
    const zones = {};
    for (const [name, sel] of Object.entries(zoneSel)) {
      const el = gut.querySelector(sel);
      if (!el) continue;
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      const cx = Math.round(r.x + r.width / 2);
      const cy = Math.round(r.y + r.height / 2);
      const hit = document.elementFromPoint(cx, cy);
      zones[name] = {
        rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) },
        centre: { x: cx, y: cy },
        // The lane's owner is the element the hit test finds at the lane's own
        // centre. Anything else means two lanes share a hit area.
        ownedBySelf: hit === el || el.contains(hit),
        hitElement: hit ? `${hit.tagName}.${typeof hit.className === "string" ? hit.className.slice(0, 40) : ""}` : null,
      };
    }
    // Pairwise horizontal overlap between the lanes.
    const names = Object.keys(zones);
    const overlaps = [];
    for (let i = 0; i < names.length; i++) {
      for (let j = i + 1; j < names.length; j++) {
        const a = zones[names[i]].rect, b = zones[names[j]].rect;
        const ov = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
        if (ov > 0) overlaps.push({ a: names[i], b: names[j], px: Math.round(ov) });
      }
    }
    const ln = gut.querySelector(".gutter-line");
    return {
      line: gut.getAttribute("data-line"),
      gutter: (r => ({ x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) }))(gut.getBoundingClientRect()),
      chevron: { x: Math.round(cr.x), y: Math.round(cr.y), w: Math.round(cr.width), h: Math.round(cr.height) },
      zones,
      overlaps,
      // The marker lane was widened to separate the two markers; this is what
      // says the line number did not lose room it needed.
      lineNumberClipped: ln ? ln.scrollWidth > ln.clientWidth + 1 : null,
    };
  });
  report.gutter = { geom: gutterGeom };

  if (gutterGeom) {
    const clickAndWatch = async (pt) => {
      const before = await page.evaluate(() => window.__gut());
      await page.mouse.click(pt.x, pt.y);
      await page.waitForTimeout(800);
      const after = await page.evaluate(() => window.__gut());
      return {
        breakpointChanged: JSON.stringify(before.breakpoints) !== JSON.stringify(after.breakpoints),
        folded: after.collapsed !== before.collapsed || after.lines !== before.lines,
        before, after,
      };
    };

    // A gutter click must set a breakpoint AND NOT FOLD.
    report.gutter.clickGutter = await clickAndWatch(gutterGeom.zones.breakpoint.centre);
    // Put it back.
    await page.mouse.click(gutterGeom.zones.breakpoint.centre.x, gutterGeom.zones.breakpoint.centre.y);
    await page.waitForTimeout(600);

    // The dedicated control must fold AND NOT touch breakpoints.
    report.gutter.clickChevron = await clickAndWatch({
      x: Math.round(gutterGeom.chevron.x + gutterGeom.chevron.w / 2),
      y: Math.round(gutterGeom.chevron.y + gutterGeom.chevron.h / 2),
    });
    await page.screenshot({ path: shots ? `${shots}/gutter.png` : "/dev/null", clip: { x: 300, y: 60, width: 340, height: 300 } }).catch(() => {});
  }
} catch (e) {
  report.error = String(e).slice(0, 400);
} finally {
  await browser.close();
}

console.log(JSON.stringify(report, null, 2));
