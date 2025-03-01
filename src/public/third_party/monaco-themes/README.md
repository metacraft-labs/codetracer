## monaco-themes

See extended demo at [https://editor.bitwiser.in](https://editor.bitwiser.in)

A list of theme definitions to be used with [monaco-editor](https://microsoft.github.io/monaco-editor/) in browser. See [minimal demo]('https://bitwiser.in/monaco-themes/')

### Usage

```sh
npm install monaco-themes
```

#### API

##### Using `<script>`

```html
<script type="text/javascript" src="https://unpkg.com/monaco-themes/dist/monaco-themes.js"></script>
<script type="text/javascript">
    var tmThemeString = /* read using FileReader */
    var themeData = MonacoThemes.parseTmTheme(tmThemeString);
    monaco.editor.defineTheme('mytheme', themeData);
    monaco.editor.setTheme('mytheme');
</script>
```

##### Using webpack/node

```js
const parseTmTheme = require('monaco-themes').parseTmTheme;
```

#### Directly using themes

##### With webpack

```js
const monaco = /* require monaco */

import('monaco-themes/themes/Monokai.json')
  .then(data => {
      monaco.editor.defineTheme('monokai', data);
  })
```

##### Independently

Download this [repository](https://github.com/brijeshb42/monaco-themes/archive/master.zip) and extract and save `themes` directory in your project.

```js
/* load monaco */

fetch('/themes/Monokai.json')
  .then(data => data.json())
  .then(data => {
    monaco.editor.defineTheme('monokai', data);
    monaco.editor.setTheme('monokai');
  })
```
