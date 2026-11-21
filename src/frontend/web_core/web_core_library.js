// web_core_library.js — the imports `web_core.nim` makes of its host, for
// Emscripten's `--js-library`. The host installs `globalThis.ctwHostPost`
// (web_core_host.js) before the core sends anything.
addToLibrary({
  ctwHostPost__deps: ['$UTF8ToString'],
  ctwHostPost: function (ptr) {
    globalThis.ctwHostPost(UTF8ToString(ptr));
  },
});
