const MonacoWebpackPlugin = require('monaco-editor-webpack-plugin');
const path = require('path');

module.exports = {
  mode: 'development',
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
