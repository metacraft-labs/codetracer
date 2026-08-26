const MonacoWebpackPlugin = require('monaco-editor-webpack-plugin');
const path = require('path');

const monacoVscodeApiRoot = path.dirname(
  require.resolve('@codingame/monaco-vscode-extension-api/localExtensionHost')
);

module.exports = {
  mode: 'development',
  resolve: {
    alias: {
      // Provide the VS Code API shim expected by monaco-languageclient.
      // Alias the package root so nested imports (e.g. vscode/localExtensionHost) resolve.
      vscode: monacoVscodeApiRoot
    },
    // mainFields: ['browser', 'module', 'main']
  },

  // Startup cost, measured.  `mode: 'development'` defaults `devtool` to
  // `'eval'`, which wraps every one of the bundle's ~3.5k modules in an
  // `eval("...")` of its source text.  That defeats V8's lazy function
  // pre-parsing: instead of one script the engine can skim and compile
  // on demand, the renderer gets ~3.5k independent, eagerly compiled
  // scripts.  Measured on a 32-core host at matched load average, median
  // of 5 launches of the same trace:
  //
  //   devtool: 'eval'              6915 ms  synchronous script phase
  //   devtool: 'cheap-source-map'  4966 ms  (-28%)
  //
  // `'cheap-source-map'` and NOT `false`, deliberately.  Webpack emits a
  // byte-for-byte identical bundle body for the two — the files differ only
  // by the trailing 44-byte `//# sourceMappingURL=` comment (verified by
  // sha256 over the common prefix) — so the whole -28% is kept, while the
  // separate `frontend_bundle.js.map` gives the debugger back what `'eval'`
  // never provided:
  //
  //   'eval'              3563 named `webpack://` scripts, NO source map;
  //                       DevTools shows webpack's rewritten module text
  //   false               one anonymous 48 MB script, no names, no map
  //   'cheap-source-map'  one script + a 36 MB map carrying all 3568
  //                       sources WITH `sourcesContent`, so DevTools shows
  //                       the original pre-webpack source
  //
  // The map costs ~9 s of the ~80 s build (+11%) and is not read at runtime
  // — Chromium fetches it only when DevTools is open — so it is off the
  // startup path.  It is gitignored, and packaging copies only
  // `frontend_bundle.js` (appimage-scripts/build_appimage.sh,
  // nix/packages/default.nix), so releases do not carry it.
  //
  // Line-level, not column-level: `'cheap-*'` omits column mappings.  For
  // this bundle that costs nothing readable — the only loaders configured
  // are the CSS pair, so for JavaScript the mapped source IS the original
  // file.  `'source-map'` / `'cheap-module-source-map'` also work but emit
  // a ~660 KB larger bundle body, which is the one thing worth not
  // perturbing here.
  //
  // Do not restore an `eval*` devtool, and do not "simplify" this to
  // `false`, without re-measuring
  // `tests/benchmarks/frontend-startup-budget.spec.ts`: the first costs
  // seconds of renderer startup, the second costs the frontend's
  // debuggability for no gain at all.
  devtool: 'cheap-source-map',
  entry: "./src/frontend/frontend_imports.js",
  output: {
    globalObject: 'window',
    path: path.resolve(__dirname, 'src/public/dist'),
    filename: "frontend_bundle.js"
  },
  module: {
    rules: [
      {
        test: /\.css$/,
        use: ['style-loader', 'css-loader']
      },
      // {
      //   test: /\.ttf$/,
      //   type: 'asset/resource'
      // }
    ]
  },
  plugins: [new MonacoWebpackPlugin()]
};
