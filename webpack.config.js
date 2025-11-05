const MonacoWebpackPlugin = require('monaco-editor-webpack-plugin');
const path = require('path');

module.exports = {
  mode: 'development',
  resolve: {
    alias: {
      // Provide the VS Code API shim expected by monaco-languageclient
      vscode: require.resolve('@codingame/monaco-vscode-extension-api')
    },
    // mainFields: ['browser', 'module', 'main']
  },

  // devtool: "source-map",
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
