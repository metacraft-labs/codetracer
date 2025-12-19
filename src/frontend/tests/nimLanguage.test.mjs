/**
 * Unit tests for Nim Monarch language grammar
 *
 * These tests verify that the Nim tokenizer correctly tokenizes
 * various Nim language constructs.
 *
 * Run with: node --experimental-vm-modules nimLanguage.test.js
 * Or use a test runner like Mocha/Jest
 */

import { nimConf, nimLanguage } from '../languages/nimLanguage.js';

// Simple assertion helper
function assert(condition, message) {
  if (!condition) {
    throw new Error(message || 'Assertion failed');
  }
}

function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    throw new Error(message || `Expected "${expected}" but got "${actual}"`);
  }
}

function assertArrayIncludes(arr, item, message) {
  if (!arr.includes(item)) {
    throw new Error(message || `Array does not include "${item}". Array: ${JSON.stringify(arr)}`);
  }
}

// Test counters
let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`\x1b[32m\u2713\x1b[0m ${name}`);
  } catch (e) {
    failed++;
    console.log(`\x1b[31m\u2717\x1b[0m ${name}`);
    console.log(`   \x1b[31m${e.message}\x1b[0m`);
  }
}

function describe(name, fn) {
  console.log(`\n\x1b[1m${name}\x1b[0m`);
  fn();
}

// ===========================================================================
// TESTS
// ===========================================================================

describe('nimConf - Language Configuration', () => {
  test('should have line comment defined', () => {
    assertEqual(nimConf.comments.lineComment, '#');
  });

  test('should have block comment defined', () => {
    assertEqual(nimConf.comments.blockComment[0], '#[');
    assertEqual(nimConf.comments.blockComment[1], ']#');
  });

  test('should have standard brackets', () => {
    const bracketStrs = nimConf.brackets.map(b => `${b[0]}-${b[1]}`);
    assertArrayIncludes(bracketStrs, '{-}', 'should have curly brackets');
    assertArrayIncludes(bracketStrs, '[-]', 'should have square brackets');
    assertArrayIncludes(bracketStrs, '(-)', 'should have parentheses');
  });

  test('should have Nim dot brackets', () => {
    const bracketStrs = nimConf.brackets.map(b => `${b[0]}-${b[1]}`);
    assertArrayIncludes(bracketStrs, '{.-.}', 'should have pragma brackets');
    assertArrayIncludes(bracketStrs, '[.-.]', 'should have dot square brackets');
    assertArrayIncludes(bracketStrs, '(.-.)','should have dot parentheses');
  });

  test('should have auto-closing pairs for strings', () => {
    const hasDoubleQuote = nimConf.autoClosingPairs.some(
      p => p.open === '"' && p.close === '"'
    );
    assert(hasDoubleQuote, 'should auto-close double quotes');
  });

  test('should have auto-closing pairs for triple strings', () => {
    const hasTripleQuote = nimConf.autoClosingPairs.some(
      p => p.open === '"""' && p.close === '"""'
    );
    assert(hasTripleQuote, 'should auto-close triple quotes');
  });

  test('should have auto-closing pairs for block comments', () => {
    const hasBlockComment = nimConf.autoClosingPairs.some(
      p => p.open === '#[' && p.close === ']#'
    );
    assert(hasBlockComment, 'should auto-close block comments');
  });

  test('should have word pattern for Nim identifiers', () => {
    assert(nimConf.wordPattern instanceof RegExp, 'wordPattern should be a RegExp');
  });

  test('should have indentation rules', () => {
    assert(nimConf.indentationRules.increaseIndentPattern instanceof RegExp,
      'should have increaseIndentPattern');
    assert(nimConf.indentationRules.decreaseIndentPattern instanceof RegExp,
      'should have decreaseIndentPattern');
  });
});

describe('nimLanguage - Keywords', () => {
  test('should have all Nim keywords', () => {
    const expectedKeywords = [
      'proc', 'func', 'method', 'iterator', 'template', 'macro', 'converter',
      'if', 'elif', 'else', 'when', 'case', 'of',
      'for', 'while', 'block', 'try', 'except', 'finally',
      'var', 'let', 'const', 'type',
      'import', 'export', 'from', 'include',
      'return', 'yield', 'discard', 'break', 'continue',
      'and', 'or', 'not', 'xor', 'div', 'mod', 'shl', 'shr',
      'in', 'notin', 'is', 'isnot',
      'nil', 'true', 'false' // true/false are constants but nil is keyword
    ];

    for (const kw of expectedKeywords) {
      if (kw === 'true' || kw === 'false') {
        assertArrayIncludes(nimLanguage.constants, kw, `constants should include ${kw}`);
      } else {
        assertArrayIncludes(nimLanguage.keywords, kw, `keywords should include ${kw}`);
      }
    }
  });

  test('should have type keywords', () => {
    const expectedTypes = [
      'int', 'int8', 'int16', 'int32', 'int64',
      'uint', 'uint8', 'uint16', 'uint32', 'uint64',
      'float', 'float32', 'float64',
      'bool', 'char', 'string', 'cstring',
      'seq', 'set', 'array', 'openarray'
    ];

    for (const t of expectedTypes) {
      assertArrayIncludes(nimLanguage.typeKeywords, t, `typeKeywords should include ${t}`);
    }
  });

  test('should have builtin functions', () => {
    const expectedBuiltins = ['echo', 'len', 'high', 'low', 'inc', 'dec', 'assert'];

    for (const fn of expectedBuiltins) {
      assertArrayIncludes(nimLanguage.builtinFunctions, fn, `builtinFunctions should include ${fn}`);
    }
  });

  test('should have pragma keywords', () => {
    const expectedPragmas = [
      'push', 'pop', 'deprecated', 'raises', 'inline', 'noinline',
      'discardable', 'exportc', 'importc', 'cdecl', 'dynlib', 'header'
    ];

    for (const p of expectedPragmas) {
      assertArrayIncludes(nimLanguage.pragmaKeywords, p, `pragmaKeywords should include ${p}`);
    }
  });

  test('should have special variables (result, it)', () => {
    assert(Array.isArray(nimLanguage.specialVariables), 'specialVariables should be an array');
    assertArrayIncludes(nimLanguage.specialVariables, 'result', 'specialVariables should include result');
    assertArrayIncludes(nimLanguage.specialVariables, 'it', 'specialVariables should include it');
  });

  test('should have type definition RHS keywords', () => {
    const expectedTypeDefRhs = [
      'object', 'enum', 'tuple', 'concept', 'distinct', 'ref', 'ptr', 'interface'
    ];

    assert(Array.isArray(nimLanguage.typeDefRhsKeywords), 'typeDefRhsKeywords should be an array');
    for (const kw of expectedTypeDefRhs) {
      assertArrayIncludes(nimLanguage.typeDefRhsKeywords, kw, `typeDefRhsKeywords should include ${kw}`);
    }
  });
});

describe('nimLanguage - Tokenizer States', () => {
  test('should have root state', () => {
    assert(Array.isArray(nimLanguage.tokenizer.root), 'should have root state');
  });

  test('should have whitespace state', () => {
    assert(Array.isArray(nimLanguage.tokenizer.whitespace), 'should have whitespace state');
  });

  test('should have comment states', () => {
    assert(Array.isArray(nimLanguage.tokenizer.blockComment), 'should have blockComment state');
    assert(Array.isArray(nimLanguage.tokenizer.docCommentBlock), 'should have docCommentBlock state');
  });

  test('should have string states', () => {
    assert(Array.isArray(nimLanguage.tokenizer.string), 'should have string state');
    assert(Array.isArray(nimLanguage.tokenizer.rawString), 'should have rawString state');
    assert(Array.isArray(nimLanguage.tokenizer.tripleString), 'should have tripleString state');
    assert(Array.isArray(nimLanguage.tokenizer.rawTripleString), 'should have rawTripleString state');
    assert(Array.isArray(nimLanguage.tokenizer.gstring), 'should have gstring state');
  });

  test('should have pragma state', () => {
    assert(Array.isArray(nimLanguage.tokenizer.pragma), 'should have pragma state');
  });

  test('should have character literal states', () => {
    assert(Array.isArray(nimLanguage.tokenizer.char), 'should have char state');
    assert(Array.isArray(nimLanguage.tokenizer.charEnd), 'should have charEnd state');
  });

  test('should have backtick identifier state', () => {
    assert(Array.isArray(nimLanguage.tokenizer.backtickIdent), 'should have backtickIdent state');
  });

  test('should have number rules', () => {
    assert(Array.isArray(nimLanguage.tokenizer.numbers), 'should have numbers rules');
  });

  test('should have routine definition states', () => {
    assert(Array.isArray(nimLanguage.tokenizer.afterRoutineKeyword), 'should have afterRoutineKeyword');
    assert(Array.isArray(nimLanguage.tokenizer.routineAfterName), 'should have routineAfterName');
    assert(Array.isArray(nimLanguage.tokenizer.paramList), 'should have paramList');
    assert(Array.isArray(nimLanguage.tokenizer.paramTypeRef), 'should have paramTypeRef');
    assert(Array.isArray(nimLanguage.tokenizer.returnTypeRef), 'should have returnTypeRef');
  });

  test('should have var/let/const declaration states', () => {
    assert(Array.isArray(nimLanguage.tokenizer.afterVarInline), 'should have afterVarInline');
    assert(Array.isArray(nimLanguage.tokenizer.afterLetInline), 'should have afterLetInline');
    assert(Array.isArray(nimLanguage.tokenizer.afterConstInline), 'should have afterConstInline');
    assert(Array.isArray(nimLanguage.tokenizer.declTypeRef), 'should have declTypeRef');
  });

  test('should have import states', () => {
    assert(Array.isArray(nimLanguage.tokenizer.importClauseStart), 'should have importClauseStart');
    assert(Array.isArray(nimLanguage.tokenizer.fromClauseStart), 'should have fromClauseStart');
    assert(Array.isArray(nimLanguage.tokenizer.fromImportItems), 'should have fromImportItems');
  });

  test('should have typeRhsLine state for type definitions', () => {
    assert(Array.isArray(nimLanguage.tokenizer.typeRhsLine), 'should have typeRhsLine state');
  });

  test('should have type definition states', () => {
    assert(Array.isArray(nimLanguage.tokenizer.afterTypeInline), 'should have afterTypeInline');
    assert(Array.isArray(nimLanguage.tokenizer.typeBlock), 'should have typeBlock');
  });

  test('should have section block states', () => {
    assert(Array.isArray(nimLanguage.tokenizer.typeHeader), 'should have typeHeader');
    assert(Array.isArray(nimLanguage.tokenizer.constHeader), 'should have constHeader');
    assert(Array.isArray(nimLanguage.tokenizer.varHeader), 'should have varHeader');
    assert(Array.isArray(nimLanguage.tokenizer.letHeader), 'should have letHeader');
  });
});

describe('nimLanguage - Regex Patterns', () => {
  test('ident pattern should match valid Nim identifiers', () => {
    const ident = nimLanguage.ident;
    assert(ident.test('foo'), 'should match simple identifier');
    assert(ident.test('FooBar'), 'should match PascalCase');
    assert(ident.test('foo_bar'), 'should match snake_case with underscore followed by letter');
    assert(ident.test('foo123'), 'should match identifier with digits');
    // Note: The regex can find matches within strings containing identifiers.
    // For proper testing of what Monarch matches AT A POSITION, we need to test
    // if the match starts at position 0 (as Monarch does).
    const noMatchAtStart = (regex, str) => {
      const match = str.match(regex);
      return !match || match.index !== 0;
    };
    assert(noMatchAtStart(ident, '123foo'), 'should not match identifier starting with digit');
    assert(noMatchAtStart(ident, '_foo'), 'should not match identifier starting with underscore');
  });

  test('underscoreIdent pattern should match standalone underscore', () => {
    const underscoreIdent = nimLanguage.underscoreIdent;
    // Standalone underscore should match at end of line or before non-identifier chars
    assert(underscoreIdent.test('_'), 'should match standalone underscore');
  });

  test('escapes pattern should match string escape sequences', () => {
    const escapes = nimLanguage.escapes;
    assert(escapes.test('\\n'), 'should match newline escape');
    assert(escapes.test('\\t'), 'should match tab escape');
    assert(escapes.test('\\\\'), 'should match backslash escape');
    assert(escapes.test('\\"'), 'should match quote escape');
    assert(escapes.test('\\x41'), 'should match hex escape');
  });

  test('decDigits pattern should match decimal numbers', () => {
    const decDigits = nimLanguage.decDigits;
    assert(decDigits.test('123'), 'should match plain digits');
    assert(decDigits.test('1_000'), 'should match digits with underscores');
    assert(decDigits.test('1_000_000'), 'should match multiple underscores');
  });

  test('hexDigits pattern should match hex digits', () => {
    const hexDigits = nimLanguage.hexDigits;
    assert(hexDigits.test('DEADBEEF'), 'should match uppercase hex');
    assert(hexDigits.test('deadbeef'), 'should match lowercase hex');
    assert(hexDigits.test('12ab'), 'should match mixed hex');
    assert(hexDigits.test('1_2_3'), 'should match hex with underscores');
  });

  test('symbols pattern should match operators', () => {
    const symbols = nimLanguage.symbols;
    assert(symbols.test('=='), 'should match equality');
    assert(symbols.test('!='), 'should match inequality');
    assert(symbols.test('+='), 'should match compound assignment');
    assert(symbols.test('->'), 'should match arrow');
    assert(symbols.test('..'), 'should match range');
    assert(symbols.test('@'), 'should match at sign');
    assert(symbols.test('$'), 'should match dollar');
  });
});

describe('nimLanguage - Token Postfix', () => {
  test('should have .nim token postfix', () => {
    assertEqual(nimLanguage.tokenPostfix, '.nim');
  });

  test('should be case insensitive', () => {
    assertEqual(nimLanguage.ignoreCase, true);
  });
});

// ===========================================================================
// Run tests
// ===========================================================================

console.log('\n========================================');
console.log('Nim Language Definition Tests');
console.log('========================================');

// Execute all tests
// (they run synchronously as we defined them above)

console.log('\n========================================');
console.log(`Results: \x1b[32m${passed} passed\x1b[0m, \x1b[31m${failed} failed\x1b[0m`);
console.log('========================================\n');

// Exit with error code if any tests failed
if (failed > 0) {
  process.exit(1);
}
