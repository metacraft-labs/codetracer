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

  // devtool: "source-map",
  entry: "./src/frontend/frontend_imports.js",
  output: {
    globalObject: 'window',
    path: path.resolve(__dirname, 'src/public/dist'),
    filename: "frontend_imports.js",
    publicPath: path.resolve(__dirname, 'src/public/dist')
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
