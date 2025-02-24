const path = require('path');
const webpack = require('webpack');

const pkg = require('./package.json');

const banner = [
  pkg.name,
  'Version - ' + pkg.version,
  'Author - ' + pkg.author,
].join('\n');

module.exports = {
  mode: 'production',
  entry: {
    'monaco-themes': './src/index.js',
  },
  output: {
    path: path.resolve(__dirname, 'dist'),
    library: 'MonacoThemes',
    libraryTarget: 'umd',
    filename: '[name].js',
    globalObject: 'self',
  },
  plugins: [
    new webpack.BannerPlugin(banner),
  ]
};
