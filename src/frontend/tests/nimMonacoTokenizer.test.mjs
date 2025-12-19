/**
 * Integration tests for Nim Monarch tokenizer using real Monaco
 *
 * These tests use Monaco's actual tokenizer API via a jsdom shim.
 *
 * Run with: node --experimental-loader ./src/frontend/tests/css-loader.mjs src/frontend/tests/nimMonacoTokenizer.test.mjs
 */

// Setup browser environment BEFORE importing Monaco
import './monaco-env.mjs';

// Now we can import Monaco from the root node_modules
// (symlinked by nix shell from node-modules-derivation)
import * as monaco from '../../../node_modules/monaco-editor/esm/vs/editor/editor.api.js';
import { nimConf, nimLanguage } from '../languages/nimLanguage.js';

// ===========================================================================
// Test Framework
// ===========================================================================

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`\x1b[32m✓\x1b[0m ${name}`);
  } catch (e) {
    failed++;
    console.log(`\x1b[31m✗\x1b[0m ${name}`);
    console.log(`   \x1b[31m${e.message}\x1b[0m`);
  }
}

function describe(name, fn) {
  console.log(`\n\x1b[1m${name}\x1b[0m`);
  fn();
}

function assert(condition, message) {
  if (!condition) throw new Error(message || 'Assertion failed');
}

function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    throw new Error(message || `Expected "${expected}" but got "${actual}"`);
  }
}

// ===========================================================================
// Setup Monaco with Nim language
// ===========================================================================

console.log('Registering Nim language with Monaco...');
monaco.languages.register({ id: 'nim' });
monaco.languages.setLanguageConfiguration('nim', nimConf);
monaco.languages.setMonarchTokensProvider('nim', nimLanguage);
console.log('Nim language registered.\n');

// ===========================================================================
// Helper Functions
// ===========================================================================

function tokenizeLine(line) {
  const result = monaco.editor.tokenize(line, 'nim');
  return result[0] ?? [];
}

function tokenizeCode(code) {
  const lines = code.split('\n');
  return lines.map((line) => ({
    line,
    tokens: monaco.editor.tokenize(line, 'nim')[0] ?? []
  }));
}

function getTokenAt(tokens, offset, line) {
  for (let i = 0; i < tokens.length; i++) {
    const start = tokens[i].offset;
    const end = tokens[i + 1]?.offset ?? line.length;
    if (offset >= start && offset < end) {
      return { ...tokens[i], text: line.substring(start, end) };
    }
  }
  return null;
}

// ===========================================================================
// Integration Tests
// ===========================================================================

describe('Basic keyword tokenization', () => {
  test('should tokenize proc as keyword', () => {
    const tokens = tokenizeLine('proc hello() =');
    const token = getTokenAt(tokens, 0, 'proc hello() =');
    assert(token, 'Should find token at position 0');
    assert(token.type.includes('keyword'), `proc should be keyword, got: ${token.type}`);
  });

  test('should tokenize var as keyword', () => {
    const tokens = tokenizeLine('var x = 1');
    const token = getTokenAt(tokens, 0, 'var x = 1');
    assert(token, 'Should find token at position 0');
    assert(token.type.includes('keyword'), `var should be keyword, got: ${token.type}`);
  });

  test('should tokenize type as keyword', () => {
    const tokens = tokenizeLine('type Foo = object');
    const token = getTokenAt(tokens, 0, 'type Foo = object');
    assert(token, 'Should find token at position 0');
    assert(token.type.includes('keyword'), `type should be keyword, got: ${token.type}`);
  });

  test('should tokenize if as keyword', () => {
    const tokens = tokenizeLine('if x > 0:');
    const token = getTokenAt(tokens, 0, 'if x > 0:');
    assert(token, 'Should find token at position 0');
    assert(token.type.includes('keyword'), `if should be keyword, got: ${token.type}`);
  });
});

describe('Import statements', () => {
  test('should tokenize import as keyword', () => {
    const tokens = tokenizeLine('import sets');
    const token = getTokenAt(tokens, 0, 'import sets');
    assert(token, 'Should find token at position 0');
    assert(token.type.includes('keyword'), `import should be keyword, got: ${token.type}`);
  });

  test('should tokenize module name as namespace', () => {
    const tokens = tokenizeLine('import sets');
    const token = getTokenAt(tokens, 7, 'import sets');
    assert(token, 'Should find token at position 7');
    assert(token.type.includes('namespace'), `sets should be namespace, got: ${token.type}`);
  });

  test('should tokenize std as namespace.std', () => {
    const tokens = tokenizeLine('import std/tables');
    const token = getTokenAt(tokens, 7, 'import std/tables');
    assert(token, 'Should find token at position 7');
    assert(token.type.includes('namespace'), `std should be namespace, got: ${token.type}`);
  });
});

describe('CRITICAL: Import followed by type block', () => {
  // This is the main regression test for the import state leak bug
  const code = `import sets, std/tables

type
    Week = enum Mon, Tue, Wed`;

  test('type keyword after import should be keyword NOT namespace', () => {
    const result = tokenizeCode(code);
    const typeLine = result[2]; // "type" line (index 2)
    assert(typeLine, 'Should have line 2');

    const typeToken = getTokenAt(typeLine.tokens, 0, typeLine.line);
    assert(typeToken, 'Should find token at position 0');

    // This is THE critical assertion - if this fails, we have an import state leak
    assert(!typeToken.type.includes('namespace'),
      `IMPORT STATE LEAK: type should NOT be namespace, got: ${typeToken.type}`);
    assert(typeToken.type.includes('keyword'),
      `type should be keyword, got: ${typeToken.type}`);
  });
});

describe('Strings', () => {
  test('should tokenize double-quoted string', () => {
    const tokens = tokenizeLine('let s = "hello"');
    const token = getTokenAt(tokens, 8, 'let s = "hello"');
    assert(token, 'Should find token at string position');
    assert(token.type.includes('string'), `"hello" should be string, got: ${token.type}`);
  });

  test('should tokenize raw string', () => {
    const tokens = tokenizeLine('let s = r"raw\\nstring"');
    const token = getTokenAt(tokens, 8, 'let s = r"raw\\nstring"');
    assert(token, 'Should find token at string position');
    assert(token.type.includes('string'), `r"..." should be string, got: ${token.type}`);
  });
});

describe('Comments', () => {
  test('should tokenize line comment', () => {
    const tokens = tokenizeLine('# this is a comment');
    const token = getTokenAt(tokens, 0, '# this is a comment');
    assert(token, 'Should find comment token');
    assert(token.type.includes('comment'), `# comment should be comment, got: ${token.type}`);
  });

  test('should tokenize doc comment', () => {
    const tokens = tokenizeLine('## documentation');
    const token = getTokenAt(tokens, 0, '## documentation');
    assert(token, 'Should find comment token');
    assert(token.type.includes('comment'), `## should be comment, got: ${token.type}`);
  });
});

describe('Numbers', () => {
  test('should tokenize decimal number', () => {
    const tokens = tokenizeLine('let x = 42');
    const token = getTokenAt(tokens, 8, 'let x = 42');
    assert(token, 'Should find number token');
    assert(token.type.includes('number'), `42 should be number, got: ${token.type}`);
  });

  test('should tokenize hex number', () => {
    const tokens = tokenizeLine('let x = 0xFF');
    const token = getTokenAt(tokens, 8, 'let x = 0xFF');
    assert(token, 'Should find number token');
    assert(token.type.includes('number'), `0xFF should be number, got: ${token.type}`);
  });

  test('should tokenize binary number', () => {
    const tokens = tokenizeLine('let x = 0b1010');
    const token = getTokenAt(tokens, 8, 'let x = 0b1010');
    assert(token, 'Should find number token');
    assert(token.type.includes('number'), `0b1010 should be number, got: ${token.type}`);
  });

  test('should tokenize float', () => {
    const tokens = tokenizeLine('let x = 3.14');
    const token = getTokenAt(tokens, 8, 'let x = 3.14');
    assert(token, 'Should find number token');
    assert(token.type.includes('number'), `3.14 should be number, got: ${token.type}`);
  });
});

describe('Special variables', () => {
  test('should tokenize result as variable.language', () => {
    const tokens = tokenizeLine('  result = true');
    const token = getTokenAt(tokens, 2, '  result = true');
    assert(token, 'Should find result token');
    assert(token.type.includes('variable'), `result should be variable, got: ${token.type}`);
  });
});

describe('Pragmas', () => {
  test('should tokenize pragma delimiters', () => {
    const tokens = tokenizeLine('{.inline.}');
    const token = getTokenAt(tokens, 0, '{.inline.}');
    assert(token, 'Should find pragma token');
    assert(token.type.includes('metatag') || token.type.includes('annotation'),
      `{. should be metatag/annotation, got: ${token.type}`);
  });
});

describe('Proc types in parameters (closure pattern)', () => {
  test('proc in type position should be keyword', () => {
    const line = 'proc setTimeout*(callback: proc() {.closure.}; delay: int): int';
    const tokens = tokenizeLine(line);
    // First proc at position 0
    const firstProc = getTokenAt(tokens, 0, line);
    assert(firstProc, 'Should find first proc token');
    assert(firstProc.type.includes('keyword'), `First proc should be keyword, got: ${firstProc.type}`);

    // Second proc (in type position) at position 27
    const secondProc = getTokenAt(tokens, 27, line);
    assert(secondProc, 'Should find second proc token');
    assert(secondProc.type.includes('keyword'), `Second proc (in type position) should be keyword, got: ${secondProc.type}`);
  });

  test('closure pragma inside proc type should be metatag', () => {
    const line = 'proc foo(handler: proc(x: int) {.closure.})';
    const tokens = tokenizeLine(line);
    // Find {. at position 31
    const pragmaStart = getTokenAt(tokens, 31, line);
    assert(pragmaStart, 'Should find pragma start');
    assert(pragmaStart.type.includes('metatag'), `{. should be metatag, got: ${pragmaStart.type}`);
  });
});

describe('CRITICAL: Proc after proc with result assignment', () => {
  // This tests the bug where a proc following another proc that uses result
  // doesn't get styled correctly
  const code = `proc myProcValue(a: int, b: int): int =
  result = a + b

proc myClosure() =
  echo "hello"`;

  test('second proc keyword after result usage should be keyword', () => {
    const result = tokenizeCode(code);
    // Line 3 (index 3): "proc myClosure() ="
    const procLine = result[3];
    assert(procLine, 'Should have line 3');
    console.log('Line 3:', JSON.stringify(procLine.line));
    console.log('Tokens:', JSON.stringify(procLine.tokens.map(t => ({ offset: t.offset, type: t.type }))));

    const procToken = getTokenAt(procLine.tokens, 0, procLine.line);
    assert(procToken, 'Should find token at position 0');
    assert(procToken.type.includes('keyword'),
      `PROC AFTER RESULT BUG: proc should be keyword, got: ${procToken.type}`);
  });

  test('second proc name should be entity.name.function', () => {
    const result = tokenizeCode(code);
    const procLine = result[3];
    // "proc myClosure" - myClosure starts at position 5
    const nameToken = getTokenAt(procLine.tokens, 5, procLine.line);
    assert(nameToken, 'Should find name token');
    assert(nameToken.type.includes('entity.name.function'),
      `myClosure should be entity.name.function, got: ${nameToken.type}`);
  });
});

describe('CRITICAL: Set literal closing brace', () => {
  // This tests the bug where a set literal {} causes issues with following fields
  const code = `type
  A = object
    mySet: set[char]
    intField: int
    stringField: string`;

  test('set keyword in type should be type.identifier', () => {
    const result = tokenizeCode(code);
    // Line 2: "    mySet: set[char]"
    const setLine = result[2];
    console.log('Set line:', JSON.stringify(setLine.line));
    console.log('Tokens:', JSON.stringify(setLine.tokens.map(t => ({ offset: t.offset, type: t.type }))));
    // Find 'set' - should be around position 11
    const setToken = getTokenAt(setLine.tokens, 11, setLine.line);
    assert(setToken, 'Should find set token');
    // set is a type keyword
    assert(setToken.type.includes('type'),
      `set should be type.identifier, got: ${setToken.type}`);
  });

  test('intField after set line should be identifier', () => {
    const result = tokenizeCode(code);
    // Line 3: "    intField: int"
    const fieldLine = result[3];
    console.log('Field line:', JSON.stringify(fieldLine.line));
    console.log('Tokens:', JSON.stringify(fieldLine.tokens.map(t => ({ offset: t.offset, type: t.type }))));
    // Find 'intField' - starts at position 4
    const fieldToken = getTokenAt(fieldLine.tokens, 4, fieldLine.line);
    assert(fieldToken, 'Should find field token');
    assert(!fieldToken.type.includes('metatag') && !fieldToken.type.includes('pragma'),
      `SET LITERAL BUG: intField should NOT be metatag/pragma, got: ${fieldToken.type}`);
  });
});

describe('CRITICAL: Character literals in set', () => {
  test('character literals should tokenize correctly', () => {
    const line = "{'0', '1', 'a'}";
    const tokens = tokenizeLine(line);
    console.log('\nCharacter literal test:');
    console.log('Line:', JSON.stringify(line));
    console.log('Tokens:', JSON.stringify(tokens.map(t => ({
      offset: t.offset,
      type: t.type,
      text: line.substring(t.offset, tokens[tokens.indexOf(t) + 1]?.offset ?? line.length)
    }))));

    // Each character literal should be properly closed
    // The comma between them should be delimiter, not string
    const comma1 = tokens.find(t => line.substring(t.offset, t.offset + 1) === ',' && t.offset === 4);
    if (comma1) {
      assert(!comma1.type.includes('string'),
        `Comma after '0' should NOT be string, got: ${comma1.type}`);
    }
  });
});

describe('CRITICAL: Empty set literal in type block', () => {
  // Test with actual empty set literal {} which might be confused with pragma
  const code = `type
  A = object
    mySet*: set[Week] = {}
    intField: int
    stringField: string`;

  test('closing brace of set literal should not affect next line', () => {
    const result = tokenizeCode(code);
    // Line 3: "    intField: int"
    const fieldLine = result[3];
    console.log('After set literal - Field line:', JSON.stringify(fieldLine.line));
    console.log('Tokens:', JSON.stringify(fieldLine.tokens.map(t => ({ offset: t.offset, type: t.type }))));
    const fieldToken = getTokenAt(fieldLine.tokens, 4, fieldLine.line);
    assert(fieldToken, 'Should find field token');
    // The field should be a normal identifier, not affected by set literal
    assert(!fieldToken.type.includes('metatag'),
      `EMPTY SET BUG: intField should NOT be metatag, got: ${fieldToken.type}`);
  });
});

describe('CRITICAL: Full complex type block with proc returning result', () => {
  // This is a more realistic test case that might trigger state machine issues
  const code = `import sets, std/tables

type
  Week = enum Mon, Tue, Wed

type
  A = object
    intField: int
    mySet: set[Week]
    stringField: string
    closureField: proc()

proc myProcValue(a: int, b: int): int =
  result = a + b

proc myClosure() =
  echo "hello"

when isMainModule:
  myClosure()`;

  test('proc myClosure keyword should be keyword', () => {
    const result = tokenizeCode(code);
    // Find the line with "proc myClosure"
    let procLineIdx = -1;
    for (let i = 0; i < result.length; i++) {
      if (result[i].line.includes('proc myClosure')) {
        procLineIdx = i;
        break;
      }
    }
    assert(procLineIdx >= 0, 'Should find proc myClosure line');
    const procLine = result[procLineIdx];
    console.log(`proc myClosure line (${procLineIdx}):`, JSON.stringify(procLine.line));
    console.log('Tokens:', JSON.stringify(procLine.tokens.map(t => ({ offset: t.offset, type: t.type, text: procLine.line.substring(t.offset, procLine.tokens[procLine.tokens.indexOf(t) + 1]?.offset ?? procLine.line.length) }))));

    const procToken = getTokenAt(procLine.tokens, 0, procLine.line);
    assert(procToken, 'Should find proc token');
    assert(procToken.type.includes('keyword'),
      `COMPLEX: proc should be keyword, got: ${procToken.type}`);
  });

  test('myClosure name should be entity.name.function', () => {
    const result = tokenizeCode(code);
    let procLineIdx = -1;
    for (let i = 0; i < result.length; i++) {
      if (result[i].line.includes('proc myClosure')) {
        procLineIdx = i;
        break;
      }
    }
    const procLine = result[procLineIdx];
    // "proc myClosure" - myClosure starts at position 5
    const nameToken = getTokenAt(procLine.tokens, 5, procLine.line);
    assert(nameToken, 'Should find name token');
    assert(nameToken.type.includes('entity.name.function'),
      `COMPLEX: myClosure should be entity.name.function, got: ${nameToken.type}`);
  });

  test('mySet closing brace should be delimiter', () => {
    const result = tokenizeCode(code);
    // Find the mySet line
    let setLineIdx = -1;
    for (let i = 0; i < result.length; i++) {
      if (result[i].line.includes('mySet:')) {
        setLineIdx = i;
        break;
      }
    }
    assert(setLineIdx >= 0, 'Should find mySet line');
    const setLine = result[setLineIdx];
    console.log(`mySet line (${setLineIdx}):`, JSON.stringify(setLine.line));
    console.log('Tokens:', JSON.stringify(setLine.tokens.map(t => ({ offset: t.offset, type: t.type }))));

    // Check the ] bracket at the end
    const lastToken = setLine.tokens[setLine.tokens.length - 1];
    assert(lastToken.type.includes('delimiter') || lastToken.type.includes('bracket'),
      `COMPLEX: closing ] should be delimiter/bracket, got: ${lastToken.type}`);
  });

  test('stringField after mySet should be identifier', () => {
    const result = tokenizeCode(code);
    // Find the stringField line
    let fieldLineIdx = -1;
    for (let i = 0; i < result.length; i++) {
      if (result[i].line.includes('stringField:')) {
        fieldLineIdx = i;
        break;
      }
    }
    assert(fieldLineIdx >= 0, 'Should find stringField line');
    const fieldLine = result[fieldLineIdx];
    console.log(`stringField line (${fieldLineIdx}):`, JSON.stringify(fieldLine.line));
    console.log('Tokens:', JSON.stringify(fieldLine.tokens.map(t => ({ offset: t.offset, type: t.type }))));

    // Find stringField token
    const fieldToken = getTokenAt(fieldLine.tokens, 4, fieldLine.line);
    assert(fieldToken, 'Should find stringField token');
    assert(fieldToken.type.includes('identifier') || fieldToken.type === '',
      `COMPLEX: stringField should be identifier, got: ${fieldToken.type}`);
  });
});

describe('Full rr_gdb.nim actual file', () => {
  // This is the actual content from codetracer-rr-backend/tests/programs/nim/rr_gdb/rr_gdb.nim
  const code = `import sets, std/tables

type
    Week = enum Mon, Tue, Wed, Thur, Fri, Sat, Sun

type
    Color = enum White, Black, Grey, Green

type
  A = object
    intField: int
    stringField: string
    boolField: bool

proc myProcValue(a: int, b: int): int =
  result = a + b

proc myClosure(base: string): proc(n: string, a: int): int =
  let myVariable = " test"
  let innerProc = proc(n: string, a: int): int =
    len(base & n & myVariable) + a # marker: INNER_FUNCTION_LINE
  return innerProc

type
  ShapeKind* = enum Circle, Square, Rhombus, Triangle

  Shape* = object
    case kind*: ShapeKind
    of Circle:
      radius: float
    of Square, Rhombus:
      sideLength: float
    of Triangle:
      base, height: float
    name: string

  IntContainer = object
    i: int

proc internal2(a: int, b: int): int =
    a + b

proc internal1(i: int) =
    echo internal2(i + 1, 1)

proc internal0() =
    var unused = 0
    internal1(1)
    var unused2 = 1

proc run() =
  var
    i: int = 0
    bigInt: int64 = 1152921504606846976
    floatValue: float = 2.0
    stringValue: string = "a nim string"
    cstringValue: cstring = "a cstring in nim"
    isTrue: bool = true
    isFalse: bool = false
    intSeq: seq[int]
    intArray: array[0..4, int]
    bIntArray: array[0..4, int]
    firstDay: Week = Mon
    lastDay: Week = Sun
    firstColor: Color = White
    lastColor: Color = Green
    objectField: A
    newObject: A
    myTuple: tuple = (10, 10, false)
    myRef: ref int
    mySet: set[char] = {'0', '1', '2', '3', 'a', 'b', 'c', 'd'}
    int8Set: set[int8]
    int16Set: set[int16]
    colorSet: set[Color] = {Color.White, Color.Black}
    myHashSet = initHashSet[string]()
    myOrderedSet = toOrderedSet([1, 2, 123, 234, 345, 0, 19, 29, 39, 49, 59, 69 ,79])
    myTable = {1: "one", 2: "two", 4: "four"}.toTable
    circleShape = Shape(kind: Circle, radius: 3.0, name: "circle")
    triangleShape = Shape(kind: Triangle, base: 4.0, height: 2.0, name: "triangle")
  myHashSet.incl("pi")

when isMainModule:
  run()`;

  test('first type keyword should be keyword (not namespace)', () => {
    const result = tokenizeCode(code);
    const typeLine = result[2];
    const token = getTokenAt(typeLine.tokens, 0, typeLine.line);
    assert(token, 'Should find type token');
    assert(!token.type.includes('namespace'),
      `First type should NOT be namespace (import leak), got: ${token.type}`);
    assert(token.type.includes('keyword'),
      `First type should be keyword, got: ${token.type}`);
  });

  // CRITICAL TEST: proc myClosure after proc myProcValue with result
  test('proc myClosure keyword should be keyword', () => {
    const result = tokenizeCode(code);
    // Find the myClosure line
    let lineIdx = -1;
    for (let i = 0; i < result.length; i++) {
      if (result[i].line.includes('proc myClosure')) {
        lineIdx = i;
        break;
      }
    }
    assert(lineIdx >= 0, 'Should find proc myClosure line');
    const procLine = result[lineIdx];
    console.log(`\nCRITICAL TEST - proc myClosure line (${lineIdx}): ${JSON.stringify(procLine.line)}`);
    console.log('Tokens:', JSON.stringify(procLine.tokens.map(t => ({
      offset: t.offset,
      type: t.type,
      text: procLine.line.substring(t.offset, procLine.tokens[procLine.tokens.indexOf(t) + 1]?.offset ?? procLine.line.length)
    }))));

    const procToken = getTokenAt(procLine.tokens, 0, procLine.line);
    assert(procToken, 'Should find proc token at position 0');
    assert(procToken.type.includes('keyword'),
      `CRITICAL BUG: proc myClosure - 'proc' should be keyword, got: ${procToken.type}`);
  });

  test('myClosure name should be entity.name.function', () => {
    const result = tokenizeCode(code);
    let lineIdx = -1;
    for (let i = 0; i < result.length; i++) {
      if (result[i].line.includes('proc myClosure')) {
        lineIdx = i;
        break;
      }
    }
    const procLine = result[lineIdx];
    // "proc myClosure" - myClosure starts at position 5
    const nameToken = getTokenAt(procLine.tokens, 5, procLine.line);
    assert(nameToken, 'Should find myClosure token');
    assert(nameToken.type.includes('entity.name.function'),
      `CRITICAL BUG: myClosure should be entity.name.function, got: ${nameToken.type}`);
  });

  // CRITICAL TEST: mySet line with set literal
  test('mySet line - closing brace should be delimiter not metatag', () => {
    const result = tokenizeCode(code);
    // Find the mySet line
    let lineIdx = -1;
    for (let i = 0; i < result.length; i++) {
      if (result[i].line.includes("mySet: set[char]")) {
        lineIdx = i;
        break;
      }
    }
    assert(lineIdx >= 0, 'Should find mySet line');
    const setLine = result[lineIdx];
    console.log(`\nCRITICAL TEST - mySet line (${lineIdx}): ${JSON.stringify(setLine.line)}`);
    console.log('Tokens:', JSON.stringify(setLine.tokens.map(t => ({
      offset: t.offset,
      type: t.type,
      text: setLine.line.substring(t.offset, setLine.tokens[setLine.tokens.indexOf(t) + 1]?.offset ?? setLine.line.length)
    }))));

    // Check that the } at the end is a delimiter, not metatag
    const closingBrace = setLine.tokens.find(t => setLine.line.substring(t.offset, t.offset + 1) === '}');
    if (closingBrace) {
      assert(!closingBrace.type.includes('metatag'),
        `CRITICAL BUG: closing } should NOT be metatag, got: ${closingBrace.type}`);
    }
  });

  test('int8Set line after mySet should be properly tokenized', () => {
    const result = tokenizeCode(code);
    // Find the int8Set line
    let lineIdx = -1;
    for (let i = 0; i < result.length; i++) {
      if (result[i].line.includes("int8Set:")) {
        lineIdx = i;
        break;
      }
    }
    assert(lineIdx >= 0, 'Should find int8Set line');
    const fieldLine = result[lineIdx];
    console.log(`\nCRITICAL TEST - int8Set line (${lineIdx}): ${JSON.stringify(fieldLine.line)}`);
    console.log('Tokens:', JSON.stringify(fieldLine.tokens.map(t => ({
      offset: t.offset,
      type: t.type,
      text: fieldLine.line.substring(t.offset, fieldLine.tokens[fieldLine.tokens.indexOf(t) + 1]?.offset ?? fieldLine.line.length)
    }))));

    // int8Set should be an identifier or variable.name, NOT metatag
    const fieldToken = fieldLine.tokens.find(t => fieldLine.line.substring(t.offset).startsWith('int8Set'));
    assert(fieldToken, 'Should find int8Set token');
    assert(!fieldToken.type.includes('metatag'),
      `CRITICAL BUG: int8Set should NOT be metatag, got: ${fieldToken.type}`);
  });

  test('when keyword should be keyword', () => {
    const result = tokenizeCode(code);
    // Find the when line
    let lineIdx = -1;
    for (let i = 0; i < result.length; i++) {
      if (result[i].line.includes('when isMainModule')) {
        lineIdx = i;
        break;
      }
    }
    assert(lineIdx >= 0, 'Should find when line');
    const whenLine = result[lineIdx];
    const token = getTokenAt(whenLine.tokens, 0, whenLine.line);
    assert(token, 'Should find when token');
    assert(token.type.includes('keyword'),
      `when should be keyword, got: ${token.type}`);
  });
});

// ===========================================================================
// Run tests
// ===========================================================================

console.log('\n========================================');
console.log('Nim Monaco Tokenizer Integration Tests');
console.log('========================================');

console.log('\n========================================');
console.log(`Results: \x1b[32m${passed} passed\x1b[0m, \x1b[31m${failed} failed\x1b[0m`);
console.log('========================================\n');

if (failed > 0) {
  process.exit(1);
}
