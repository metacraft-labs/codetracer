const { join } = require('path');
const fs = require('fs');

const packageJson = JSON.parse(fs.readFileSync('./package.json'));
const {
  build: { productName },
} = packageJson;

process.env.TEST = true;

const config = {
  maxInstances: 1,
  services: [
    [
      'electron',
      {
        // appPath: 'node_modules/.bin/', // join(__dirname, 'src/build-debug/build/dist'),
        // appName: 'electron',
        binaryPath: join(__dirname, 'node_modules', '.bin', 'electron'),
        appArgs: ['app=src/build-debug/build'],
        chromedriver: {
          port: 9519,
          logFileName: 'wdio-chromedriver.log',
        },
      },
    ],
  ],
  capabilities: [{
    browserName: 'electron'
    // alwaysMatch: {'browserName': 'electron'}
  }],
  port: 9519,
  waitforTimeout: 5000,
  connectionRetryCount: 10,
  connectionRetryTimeout: 30000,
  logLevel: 'debug',
  runner: 'local',
  outputDir: 'wdio-logs',
  specs: ['./src/build-debug/build/tests/dom_test.js'],

  // framework: 'mocha',
  // mochaOpts: {
  //   ui: 'bdd',
  //   timeout: 30000,
  // },
};

module.exports = { config };
