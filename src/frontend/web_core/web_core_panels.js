// web_core_panels.js — the WebAssembly panes in the desktop renderer and the
// web build (`-d:ctWasmPanes`).
//
// `ui/panel_host.nim` calls `ctwPanels.mount(pane, hostElement)` where the
// `nim js` build would render the variables pane, Call Trace or the event
// log. The first call boots ONE wasm core (`web_core.nim`) over the tab's own
// connection to the engine (`globalThis.ctwRendererTransport`, installed by
// `web_core/renderer_transport.nim`) and attaches it to the session the page
// already opened; each pane the core draws is then moved into its host
// element. The core keeps drawing into the moved node: the applier holds
// nodes, not their places.
//
// Needs, loaded before it: IsoNim's `frame_applier.js`, `web_core_host.js`,
// `decorations.js` and the core's Emscripten glue (`ctwModule`).

'use strict';

(function (root) {
  let host = null;
  let booting = null;

  async function boot() {
    if (!root.ctwRendererTransport) {
      throw new Error('ctwPanels: no renderer transport — the renderer was not built with -d:ctWasmPanes');
    }
    const Module = await root.ctwModule();
    const mount = document.createElement('div');
    mount.id = 'ctw-panes-staging';
    mount.style.display = 'none';
    document.body.appendChild(mount);
    host = root.CtWebCoreHost.startWebCore({
      core: Module, mount, transport: root.ctwRendererTransport, paneRoot: document,
    });
    host.attach('renderer-session');
    root.ctwPanelsHost = host;
    return host;
  }

  const BUILT_IN = ['state', 'calltrace', 'event-log'];
  function place(name, el) {
    if (!BUILT_IN.includes(name)) host.mountPane(name);
    const p = host.paneElement(name);
    if (!p) { setTimeout(() => place(name, el), 16); return; }
    if (p.parentNode !== el) {
      while (el.firstChild) el.removeChild(el.firstChild);
      el.appendChild(p);
      p.style.height = '100%';
    }
  }

  root.ctwPanels = {
    mount(name, el) {
      booting = booting || boot();
      booting.then(() => place(name, el)).catch((e) => {
        root.ctwPanelsError = String(e && e.stack || e);
        console.error(root.ctwPanelsError);
      });
    },
  };
})(typeof globalThis !== 'undefined' ? globalThis : this);
