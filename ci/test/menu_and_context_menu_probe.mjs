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
} catch (e) {
  report.error = String(e).slice(0, 400);
} finally {
  await browser.close();
}

console.log(JSON.stringify(report, null, 2));
