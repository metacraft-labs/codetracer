# W3C ARIA Authoring Practices Guide — reference keyboard implementations

These five scripts are copied **verbatim**, byte for byte, from the W3C
ARIA Authoring Practices Guide repository. They are a test oracle: the
`renderer-chromium` suite `src/frontend/tests/keyboard_panes_chromium_test.nim`
runs them in headless Chromium beside CodeTracer's own web binding and asks
them what each key should do. They are not shipped in any product build.

- Repository: https://github.com/w3c/aria-practices
- Commit: `f14b2490a6728cda85fd7feafbd148b3c3eaf038` (`main`, fetched 2026-11-21)
- Licence: W3C Software and Document License,
  https://www.w3.org/Consortium/Legal/2015/copyright-software-and-document
  (see `LICENSE.md` beside this file and each script's own header)

| File here | Path in the repository |
| --- | --- |
| `listbox.js` | `content/patterns/listbox/examples/js/listbox.js` |
| `tree.js` | `content/patterns/treeview/examples/js/tree.js` |
| `treeitem.js` | `content/patterns/treeview/examples/js/treeitem.js` |
| `dataGrid.js` | `content/patterns/grid/examples/js/dataGrid.js` |
| `utils.js` | `content/shared/js/utils.js` |

Do not edit these files. A change of behaviour is taken by copying a newer
commit of the upstream files and recording it here; the suite's header says
which keys the oracle agrees on and which divergences it pins.
