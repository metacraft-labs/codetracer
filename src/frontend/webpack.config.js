const path = require('path');

module.exports = {
  entry: 'public/third_party/jquery.js',
  output: {
    path: path.resolve(__dirname, 'dist'),
    filename: 'bundle.js'
  }
};
