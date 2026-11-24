// web_core_panels.js — the WebAssembly panes in the desktop renderer and the
// web build (`-d:ctWasmPanes`).
//
// `ui/panel_host.nim` calls `ctwPanels.mount(pane, hostElement, session)`
// where the `nim js` build would render the variables pane, Call Trace, the
// event log or another panel-host pane. `session` is the tab's
// `SessionViewModel`, carrying that tab's transport (`ctwTransport`, set by
// `web_core/renderer_transport.nim` over the tab's own connection to the
// engine). The first mount for a tab boots ONE wasm core (`web_core.nim`)
// for it and attaches it to the session the page already opened; each pane
// that core draws is then moved into its host element. The core keeps
// drawing into the moved node: the applier holds nodes, not their places.
// So two tabs are two cores, each over its own tab's replay.
//
// `ctwPanels.press(op, element)` routes a press on a pane to the core that
// draws it; `ctwPanels.owns(element)` says whether one does.
//
// Needs, loaded before it: IsoNim's `frame_applier.js`, `web_core_host.js`,
// `decorations.js` and the core's Emscripten glue (`ctwModule`).

'use strict';

(function (root) {
  // One core per tab, keyed by the tab's SessionViewModel; a mount that
  // names no session uses the first tab's transport (`ctwRendererTransport`).
  const hosts = new WeakMap();
  const noSession = {};

  async function boot(session) {
    const transport = (session && session.ctwTransport) || root.ctwRendererTransport;
    if (!transport) {
      throw new Error('ctwPanels: no renderer transport — the renderer was not built with -d:ctWasmPanes');
    }
    const Module = await root.ctwModule();
    const mount = document.createElement('div');
    mount.className = 'ctw-panes-staging';
    mount.style.display = 'none';
    document.body.appendChild(mount);
    const host = root.CtWebCoreHost.startWebCore({
      core: Module, mount, transport, paneRoot: document,
      // The panel host measures each pane as it measures its own.
      pageMeasures: true,
      // The shell does what this tab's core asks of the page
      // (`ui/panel_host`'s `ctwShellAction`).
      onAction: (json) => { if (root.ctwShellAction) root.ctwShellAction(json, session || null); },
    });
    host.attach('renderer-session');
    // The first tab's host, for a caller that knows of one core only.
    if (!root.ctwPanelsHost) root.ctwPanelsHost = host;
    return host;
  }

  const BUILT_IN = ['state', 'calltrace', 'event-log'];
  function place(host, name, el) {
    if (!BUILT_IN.includes(name)) host.mountPane(name);
    const p = host.paneElement(name);
    if (!p) { setTimeout(() => place(host, name, el), 16); return; }
    p.__ctwHost = host;
    if (p.parentNode !== el) {
      while (el.firstChild) el.removeChild(el.firstChild);
      el.appendChild(p);
      p.style.height = '100%';
    }
  }

  function hostOf(el) {
    // The core pane `el` is in — or, for the page's pane host element, the
    // one placed inside it.
    const pane = !el ? null
      : (el.closest && el.closest('.ct-web-core-pane'))
        || (el.querySelector && el.querySelector('.ct-web-core-pane'));
    return pane && pane.__ctwHost ? pane.__ctwHost : null;
  }

  root.ctwPanels = {
    mount(name, el, session) {
      const key = session || noSession;
      let booting = hosts.get(key);
      if (!booting) { booting = boot(session); hosts.set(key, booting); }
      booting.then((host) => place(host, name, el)).catch((e) => {
        root.ctwPanelsError = String(e && e.stack || e);
        console.error(root.ctwPanelsError);
      });
    },
    owns(el) { return !!hostOf(el); },
    press(op, el) {
      const host = hostOf(el);
      return host ? host.press(op, el) : false;
    },
    // The right-click menu of `el` in `pane`, from the core that draws it:
    // `[{label, hint, enabled, choose()}]`; choose() performs the entry and
    // answers what the shell must still do (JSON, or "").
    // The panel host's measurement of the pane `el` is in (`ctwMeasured`).
    measured(el, pane, rows, cols, firstRow, rowPx) {
      const host = hostOf(el);
      if (host) host.measured(pane, rows, cols, firstRow, rowPx);
    },
    // The event log's whole length and row pitch, for its scroll extent.
    eventLogExtent(el) {
      const host = hostOf(el);
      return host ? [host.eventLogTotal(), host.eventLogRowPx()] : [0, 0];
    },
    // The tab's Event Log state, mirrored into its core's once that is up.
    shellMirror(session, json) {
      const key = session || noSession;
      let booting = hosts.get(key);
      if (!booting) { booting = boot(session); hosts.set(key, booting); }
      booting.then((host) => host.shellMirror(json)).catch(() => {});
    },
    menu(pane, el) {
      const host = hostOf(el);
      if (!host || !host.menu) return [];
      return host.menu(pane, el).map((e, i) => Object.assign(e, { choose: () => host.menuChoose(i) }));
    },
  };
})(typeof globalThis !== 'undefined' ? globalThis : this);
