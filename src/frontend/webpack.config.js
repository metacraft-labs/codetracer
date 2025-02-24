const path = require('path');

module.exports = {
  entry: 'public/jquery.js',
  output: {
    path: path.resolve(__dirname, 'dist'),
    filename: 'bundle.js'
  }
};
