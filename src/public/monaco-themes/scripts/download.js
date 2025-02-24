const fs = require('fs');
const path = require('path');
const http = require('follow-redirects').https;

const themeMap = {
  'Active4D': 'https://github.com/ajaxorg/ace/raw/master/tool/tmthemes/Active4D.tmTheme',
  'All Hallows Eve': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/All%20Hallow\'s%20Eve.tmTheme',
  'Amy': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/Amy.tmTheme',
  'Blackboard': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/Blackboard.tmTheme',
  'Birds of Paradise': 'https://github.com/filmgirl/TextMate-Themes/raw/master/Birds%20of%20Paradise.tmTheme',
  'Brilliance Black': 'https://raw.githubusercontent.com/ajaxorg/ace/master/tool/tmthemes/Brilliance%20Black.tmTheme',
  'Brilliance Dull': 'https://raw.githubusercontent.com/ajaxorg/ace/master/tool/tmthemes/Brilliance%20Dull.tmTheme',
  'Chrome DevTools': 'https://raw.githubusercontent.com/ajaxorg/ace/master/tool/tmthemes/Chrome%20DevTools.tmTheme',
  'Clouds Midnight': 'https://raw.githubusercontent.com/ajaxorg/ace/master/tool/tmthemes/Clouds%20Midnight.tmTheme',
  'Clouds': 'https://raw.githubusercontent.com/ajaxorg/ace/master/tool/tmthemes/Clouds.tmTheme',
  'Cobalt': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/Cobalt.tmTheme',
  // 'Cobalt2': 'https://github.com/wesbos/cobalt2/raw/master/cobalt2.tmTheme',
  'Dawn': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/Dawn.tmTheme',
  'Dreamweaver': 'https://github.com/ajaxorg/ace/raw/master/tool/tmthemes/Dreamweaver.tmTheme',
  'Eiffel': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/Eiffel.tmTheme',
  'Espresso Libre': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/Espresso%20Libre.tmTheme',
  'GitHub': 'https://github.com/ajaxorg/ace/raw/master/tool/tmthemes/GitHub.tmTheme',
  'IDLE': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/IDLE.tmTheme',
  'Katzenmilch': 'https://github.com/ajaxorg/ace/raw/master/tool/tmthemes/Kuroir%20Theme.tmTheme',
  'Kuroir Theme': 'https://github.com/ajaxorg/ace/raw/master/tool/tmthemes/Kuroir%20Theme.tmTheme',
  'LAZY': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/LAZY.tmTheme',
  'MagicWB (Amiga)': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/MagicWB%20(Amiga).tmTheme',
  'Merbivore Soft': 'https://github.com/ajaxorg/ace/raw/master/tool/tmthemes/Merbivore.tmTheme',
  'Merbivore': 'https://github.com/ajaxorg/ace/raw/master/tool/tmthemes/Merbivore.tmTheme',
  'Monokai': 'https://github.com/cj/sublime/raw/master/Color%20Scheme%20-%20Default/Monokai.tmTheme',
  'Monokai Bright': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/Monokai%20Bright.tmTheme',
  'Night Owl': 'https://github.com/batpigandme/night-owlish/raw/master/tmTheme/night-owlish.tmTheme',
  'Oceanic Next': 'https://github.com/voronianski/oceanic-next-color-scheme/raw/master/Oceanic%20Next.tmTheme',
  'Pastels on Dark': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/Pastels%20on%20Dark.tmTheme',
  'Slush and Poppies': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/Slush%20%26%20Poppies.tmTheme',
  'Solarized-dark': 'https://github.com/deplorableword/textmate-solarized/raw/master/Solarized%20(dark).tmTheme',
  'Solarized-light': 'https://github.com/deplorableword/textmate-solarized/raw/master/Solarized%20(light).tmTheme',
  'SpaceCadet': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/SpaceCadet.tmTheme',
  'Sunburst': 'https://github.com/filmgirl/TextMate-Themes/raw/master/Sunburst.tmTheme',
  'Textmate (Mac Classic)': 'https://github.com/textmate/themes.tmbundle/raw/master/Themes/Mac%20Classic.tmTheme',
  'Tomorrow-Night-Blue': 'https://github.com/chriskempson/tomorrow-theme/raw/master/textmate2/Tomorrow%20Theme.tmbundle/Themes/Tomorrow-Night-Blue.tmTheme',
  'Tomorrow-Night-Bright': 'https://github.com/chriskempson/tomorrow-theme/raw/master/textmate2/Tomorrow%20Theme.tmbundle/Themes/Tomorrow-Night-Bright.tmTheme',
  'Tomorrow-Night-Eighties': 'https://github.com/chriskempson/tomorrow-theme/raw/master/textmate2/Tomorrow%20Theme.tmbundle/Themes/Tomorrow-Night-Eighties.tmTheme',
  'Tomorrow-Night': 'https://github.com/chriskempson/tomorrow-theme/raw/master/textmate2/Tomorrow%20Theme.tmbundle/Themes/Tomorrow-Night.tmTheme',
  'Tomorrow': 'https://github.com/chriskempson/tomorrow-theme/raw/master/textmate2/Tomorrow%20Theme.tmbundle/Themes/Tomorrow.tmTheme',
  'Twilight': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/Twilight.tmTheme',
  'Upstream Sunburst': 'https://github.com/filmgirl/TextMate-Themes/raw/master/Upstream%20Sunburst.tmTheme',
  'Vibrant Ink': 'https://github.com/filmgirl/TextMate-Themes/raw/master/Vibrant%20Ink.tmTheme',
  'Xcode_default': 'https://github.com/ajaxorg/ace/raw/master/tool/tmthemes/Xcode_default.tmTheme',
  'Zenburnesque': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/Zenburnesque.tmTheme',
  'iPlastic': 'https://github.com/JetBrains/colorSchemeTool/raw/master/tmThemes/iPlastic.tmTheme',
  'idleFingers': 'https://github.com/ajaxorg/ace/raw/master/tool/tmthemes/idleFingers.tmTheme',
  'krTheme': 'https://github.com/ajaxorg/ace/raw/master/tool/tmthemes/krTheme.tmTheme',
  'monoindustrial': 'https://github.com/bryanjswift/tmthemes/raw/master/monoindustrial.tmTheme'
};

const themePath = path.join(process.cwd(), 'tmthemes');

function downloadTheme(name, url) {
  const dest = path.join(themePath, `${name}.tmTheme`);

  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);

    const request = http.get(url, function(resp) {
      resp.pipe(file);

      file.on('finish', function() {
        file.close();
        resolve();
      });
    });
  });
}

function startDownload() {
  const promises = Object.keys(themeMap).map(name => {
    console.log(`Downloading ${name}`);
    downloadTheme(name, themeMap[name])
      .then(() => console.log(`Downloaded ${name}`))
      .catch(() => console.log(`Could not download ${name}`));
  });
}

startDownload();
