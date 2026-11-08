// monaco_word_oracle.mjs — the bundled Monaco's own word and line selection,
// for test_plat70g_word_oracle.nim. Not a re-implementation: it imports
// WordOperations and CursorMoveCommands from monaco-editor's ESM and answers
// the queries in the JSON file named by argv[3].
//
// node monaco_word_oracle.mjs <monaco-editor dir> <queries.json>
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const base = process.argv[2];
const load = (p) => import(pathToFileURL(`${base}/esm/vs/editor/common/${p}`));
const { WordOperations } = await load('cursor/cursorWordOperations.js');
const { CursorMoveCommands } = await load('cursor/cursorMoveCommands.js');
const { SingleCursorState } = await load('cursorCommon.js');
const { Position } = await load('core/position.js');
const { Range } = await load('core/range.js');

const q = JSON.parse(readFileSync(process.argv[3], 'utf8'));
const lines = q.lines;
const model = {
  getLineContent: (n) => lines[n - 1],
  getLineMaxColumn: (n) => lines[n - 1].length + 1,
  getLineCount: () => lines.length,
  validatePosition: (p) => p,
};
const identity = {
  validateViewPosition: (p) => p,
  convertModelPositionToViewPosition: (p) => p,
};
const viewModel = {
  model,
  coordinatesConverter: identity,
  getLineCount: () => lines.length,
  getLineMaxColumn: (n) => model.getLineMaxColumn(n),
};
const config = { wordSeparators: q.separators, wordSegmenterLocales: [] };
const caret = new SingleCursorState(new Range(1, 1, 1, 1), 0, 0, new Position(1, 1), 0);
const stateOf = (s) => [
  s.selection.selectionStartLineNumber, s.selection.selectionStartColumn,
  s.selection.positionLineNumber, s.selection.positionColumn];

const out = { word: [], extendWord: [], extendLine: [] };
for (const [line, column] of q.word) {
  const r = WordOperations.word(config, model, caret, false, new Position(line, column));
  out.word.push([r.selectionStart.startColumn, r.selectionStart.endColumn]);
}
for (const [aLine, aFirst, aLast, line, column] of q.extendWord) {
  const anchor = new Range(aLine, aFirst, aLine, aLast);
  const cursor = new SingleCursorState(anchor, 1, 0, new Position(aLine, aLast), 0);
  out.extendWord.push(stateOf(WordOperations.word(config, model, cursor, true, new Position(line, column))));
}
for (const [aLine, line, column] of q.extendLine) {
  const entering = CursorMoveCommands.line(viewModel,
    { modelState: caret, viewState: caret }, false, new Position(aLine, 1), null);
  const cursor = { modelState: entering.modelState, viewState: entering.modelState };
  const r = CursorMoveCommands.line(viewModel, cursor, true, new Position(line, column), null);
  out.extendLine.push(stateOf(r.modelState ?? r.viewState));
}
console.log(JSON.stringify(out));
