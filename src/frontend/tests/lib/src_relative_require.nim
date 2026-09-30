## src_relative_require.nim
##
## FINDS THE PRODUCT'S OWN `src/*.js` SIBLINGS WHEN A SUITE IS NOT IN `src/`.
##
## `index/config.nim` runs `require("./helpers")` at module load, and node
## resolves that relative to the FILE doing the requiring. In the shipped
## build that file is `src/index.js`, sitting beside `src/helpers.js`. A test
## lane compiles its suite into a nimcache directory instead, so the same
## require has nothing beside it and the module fails to load before a single
## case runs.
##
## This installs a LAST-RESORT fallback on node's resolver: a relative request
## that cannot be resolved is retried against the repository's real `src/`. It
## substitutes nothing — `src/helpers.js` is the file the product loads, and a
## request that resolves normally never reaches the fallback. The repository
## root is taken from `process.cwd()`, which the lane runner sets to the
## checkout root.
##
## Import it BEFORE the module whose load-time require needs it. Nim emits an
## imported module's top-level code in import order, so the patch is in place
## by the time `config.nim`'s body runs.

{.emit: """
(function () {
  var Module = require('module');
  var path = require('path');
  var fs = require('fs');
  var srcDir = path.join(process.cwd(), 'src');
  var original = Module._resolveFilename;
  Module._resolveFilename = function (request, parent, isMain, options) {
    try {
      return original.call(this, request, parent, isMain, options);
    } catch (err) {
      if (request.charAt(0) === '.') {
        var candidate = path.join(srcDir, request.replace(/^\.\/?/, ''));
        for (var i = 0; i < 2; i++) {
          var p = i === 0 ? candidate : candidate + '.js';
          if (fs.existsSync(p) && fs.statSync(p).isFile()) {
            return original.call(this, p, parent, isMain, options);
          }
        }
      }
      throw err;
    }
  };
})();
""".}
