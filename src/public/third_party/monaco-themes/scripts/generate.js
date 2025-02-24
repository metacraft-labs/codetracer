const fs = require('fs');
const path = require('path');
const parseTmTheme = require('../src/index').parseTmTheme;

function ext(themeName) {
  const lpath = path.join(process.cwd(), 'tmthemes', `${themeName}.tmTheme`);
  const fileData = fs.readFileSync(lpath, 'utf8');
  const theme =  parseTmTheme(fileData);
  // Support minimap background color. 
  // @see https://github.com/microsoft/monaco-editor/issues/908
  theme.rules.unshift({
    "background": theme.colors["editor.background"].replace('#',''),
    "token": ""
  })
  return theme;
}

function snakeCase(fname) {
  return fname.toLowerCase().replace(/[_() ]/g, '-');
}

function generate(themePath) {
  const files = fs.readdirSync(themePath);
  const gen = {};

  files.forEach(file => {
    let fname = file.split('.');
    fname.pop()
    if (!fname.length || !fname[0]) {
      return;
    }
    fname = fname.join('.');
    fs.writeFileSync(path.join(process.cwd(), 'themes', fname + '.json'), JSON.stringify(ext(fname), null, 2), 'utf8');
    gen[snakeCase(fname)] = fname;
  });

  fs.writeFileSync(path.join(process.cwd(), 'themes', 'themelist.json'), JSON.stringify(gen, null, 2), 'utf8');
}

generate(path.join(process.cwd(), 'tmthemes'));
