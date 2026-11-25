// web_core_library.js — the imports `web_core.nim` makes of its host, for
// Emscripten's `--js-library`. The host installs `globalThis.ctwHostPost`
// (web_core_host.js) before the core sends anything.
addToLibrary({
  ctwHostPost__deps: ['$UTF8ToString'],
  // Each core's own host, on its Module: a page can run one core per tab.
  ctwHostPost: function (ptr) {
    (Module['ctwHostPost'] || globalThis.ctwHostPost)(UTF8ToString(ptr));
  },
  ctwHostAction__deps: ['$UTF8ToString'],
  ctwHostAction: function (ptr) {
    const f = Module['ctwHostAction'] || globalThis.ctwHostAction;
    if (f) f(UTF8ToString(ptr));
  },
});
