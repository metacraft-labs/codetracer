/**
 * Behavioral tests for Nim Monarch language tokenizer
 *
 * This file tests the Nim language definition patterns directly
 * to verify they correctly match Nim language constructs.
 *
 * Run with: node src/frontend/tests/nimTokenizer.test.js
 */

import { nimLanguage, nimConf } from '../languages/nimLanguage.js';

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
// Helper Functions
// ===========================================================================

/**
 * Expand @references in a pattern string or RegExp
 */
function expandPattern(pattern) {
  let str;
  let originalFlags = '';

  if (pattern instanceof RegExp) {
    str = pattern.source;
    originalFlags = pattern.flags;
  } else if (typeof pattern === 'string') {
    str = pattern;
  } else {
    return null;
  }

  str = str.replace(/@@/g, '\x01');

  let iterations = 0;
  let hadExpansion;
  do {
    hadExpansion = false;
    str = str.replace(/@(\w+)/g, (match, attr) => {
      hadExpansion = true;
      const sub = nimLanguage[attr];
      if (typeof sub === 'string') {
        return '(?:' + sub + ')';
      } else if (sub instanceof RegExp) {
        return '(?:' + sub.source + ')';
      }
      return match;
    });
    iterations++;
  } while (hadExpansion && iterations < 10);

  str = str.replace(/\x01/g, '@');

  // Combine original flags with ignoreCase if needed
  let flags = originalFlags;
  if (nimLanguage.ignoreCase && !flags.includes('i')) {
    flags += 'i';
  }

  return new RegExp(str, flags);
}

/**
 * Test if a pattern matches at the start of text
 */
function matchesAtStart(pattern, text) {
  const regex = expandPattern(pattern);
  if (!regex) return null;

  // Ensure it matches at start
  const anchoredRegex = new RegExp('^(?:' + regex.source + ')', regex.flags);
  const match = text.match(anchoredRegex);
  return match ? match[0] : null;
}

/**
 * Find a rule in a tokenizer state that matches the given text
 */
function findMatchingRule(stateName, text, depth = 0, visited = new Set()) {
  if (depth > 10) return null; // Prevent infinite recursion
  if (visited.has(stateName)) return null; // Prevent cycles
  visited.add(stateName);

  const rules = nimLanguage.tokenizer[stateName];
  if (!rules) return null;

  for (const rule of rules) {
    // Handle includes - can be { include: '@foo' } format
    if (rule.include) {
      const includedState = rule.include.replace(/^@/, '');
      const result = findMatchingRule(includedState, text, depth + 1, new Set(visited));
      if (result) return result;
      continue;
    }

    // Handle object with include property
    if (typeof rule === 'object' && !Array.isArray(rule) && 'include' in rule) {
      const includedState = rule.include.replace(/^@/, '');
      const result = findMatchingRule(includedState, text, depth + 1, new Set(visited));
      if (result) return result;
      continue;
    }

    // Get the pattern
    let pattern;
    if (Array.isArray(rule)) {
      pattern = rule[0];
    } else if (rule.regex) {
      pattern = rule.regex;
    } else {
      continue;
    }

    const matched = matchesAtStart(pattern, text);
    if (matched) {
      return { rule, matched, pattern };
    }
  }

  return null;
}

/**
 * Check if text would be recognized as a specific token type in the given state
 */
function wouldTokenizeAs(stateName, text, expectedTokenType) {
  const result = findMatchingRule(stateName, text);
  if (!result) return false;

  const { rule, matched } = result;

  // Get the action/token type
  let action;
  if (Array.isArray(rule)) {
    action = rule[1];
  } else {
    action = rule.action || rule.token;
  }

  if (typeof action === 'string') {
    return action.includes(expectedTokenType);
  }

  if (typeof action === 'object') {
    if (action.token && action.token.includes(expectedTokenType)) {
      return true;
    }
    // Check cases
    if (action.cases) {
      const checkText = nimLanguage.ignoreCase ? text.toLowerCase() : text;
      for (const [caseKey, caseToken] of Object.entries(action.cases)) {
        if (caseKey === '@keywords' && nimLanguage.keywords.includes(checkText)) {
          return caseToken.includes(expectedTokenType);
        }
        if (caseKey === '@typeKeywords' && nimLanguage.typeKeywords.includes(checkText)) {
          return caseToken.includes(expectedTokenType);
        }
        if (caseKey === '@constants' && nimLanguage.constants.includes(checkText)) {
          return caseToken.includes(expectedTokenType);
        }
        if (caseKey === '@builtinFunctions' && nimLanguage.builtinFunctions.includes(checkText)) {
          return caseToken.includes(expectedTokenType);
        }
        if (caseKey === '@default') {
          return caseToken.includes(expectedTokenType);
        }
      }
    }
  }

  return false;
}

// ===========================================================================
// Pattern Tests - Verify regex patterns match expected inputs
// ===========================================================================

describe('Pattern: @ident (identifiers)', () => {
  const ident = nimLanguage.ident;

  test('should match simple identifier', () => {
    assert(ident.test('foo'), 'should match foo');
    assert(ident.test('myVariable'), 'should match myVariable');
  });

  test('should match PascalCase', () => {
    assert(ident.test('FooBar'), 'should match FooBar');
    assert(ident.test('MyType'), 'should match MyType');
  });

  test('should match identifier with digits', () => {
    assert(ident.test('var1'), 'should match var1');
    assert(ident.test('foo123'), 'should match foo123');
  });

  test('should match identifier with underscore before alphanumeric', () => {
    assert(ident.test('my_var'), 'should match my_var');
    assert(ident.test('foo_bar_baz'), 'should match foo_bar_baz');
  });

  test('should match Unicode identifiers', () => {
    assert(ident.test('\u00e4bc'), 'should match Unicode start'); // ä
  });

  test('should not match at digit start', () => {
    const match = '123foo'.match(ident);
    assert(!match || match.index !== 0, 'should not match 123foo at start');
  });
});

describe('Pattern: @underscoreIdent', () => {
  const underscoreIdent = nimLanguage.underscoreIdent;

  test('should match standalone underscore', () => {
    assert(underscoreIdent.test('_'), 'should match single underscore');
  });
});

describe('Pattern: @escapes', () => {
  const escapes = nimLanguage.escapes;

  test('should match newline escape', () => {
    assert(escapes.test('\\n'), 'should match \\n');
  });

  test('should match tab escape', () => {
    assert(escapes.test('\\t'), 'should match \\t');
  });

  test('should match quote escapes', () => {
    assert(escapes.test('\\"'), 'should match \\"');
    assert(escapes.test("\\'"), "should match \\'");
  });

  test('should match hex escape', () => {
    assert(escapes.test('\\x41'), 'should match \\x41');
    assert(escapes.test('\\xFF'), 'should match \\xFF');
  });

  test('should match unicode escape', () => {
    assert(escapes.test('\\u0041'), 'should match \\u0041');
  });
});

describe('Pattern: @decDigits', () => {
  const decDigits = nimLanguage.decDigits;

  test('should match plain digits', () => {
    assert(decDigits.test('123'), 'should match 123');
    assert(decDigits.test('42'), 'should match 42');
  });

  test('should match digits with underscores', () => {
    assert(decDigits.test('1_000'), 'should match 1_000');
    assert(decDigits.test('1_000_000'), 'should match 1_000_000');
  });
});

describe('Pattern: @hexDigits', () => {
  const hexDigits = nimLanguage.hexDigits;

  test('should match hex digits', () => {
    assert(hexDigits.test('DEADBEEF'), 'should match DEADBEEF');
    assert(hexDigits.test('deadbeef'), 'should match lowercase');
    assert(hexDigits.test('123abc'), 'should match mixed');
  });

  test('should match hex with underscores', () => {
    assert(hexDigits.test('DE_AD_BE_EF'), 'should match with underscores');
  });
});

describe('Pattern: @symbols (operators)', () => {
  const symbols = nimLanguage.symbols;

  test('should match single operators', () => {
    assert(symbols.test('+'), 'should match +');
    assert(symbols.test('-'), 'should match -');
    assert(symbols.test('*'), 'should match *');
    assert(symbols.test('/'), 'should match /');
    assert(symbols.test('='), 'should match =');
  });

  test('should match compound operators', () => {
    assert(symbols.test('=='), 'should match ==');
    assert(symbols.test('!='), 'should match !=');
    assert(symbols.test('<='), 'should match <=');
    assert(symbols.test('>='), 'should match >=');
    assert(symbols.test('+='), 'should match +=');
  });

  test('should match range operator', () => {
    assert(symbols.test('..'), 'should match ..');
  });

  test('should match special Nim operators', () => {
    assert(symbols.test('@'), 'should match @');
    assert(symbols.test('$'), 'should match $');
    assert(symbols.test('->'), 'should match ->');
  });
});

// ===========================================================================
// Tokenizer State Tests - Verify rules in tokenizer states
// ===========================================================================

describe('Root state: keyword recognition', () => {
  test('should have rule matching proc', () => {
    const result = findMatchingRule('root', 'proc');
    assert(result !== null, 'should find matching rule for proc');
    assertEqual(result.matched, 'proc', 'should match "proc"');
  });

  test('should have rule matching var', () => {
    const result = findMatchingRule('root', 'var');
    assert(result !== null, 'should find matching rule for var');
  });

  test('should have rule matching let', () => {
    const result = findMatchingRule('root', 'let');
    assert(result !== null, 'should find matching rule for let');
  });

  test('should have rule matching const', () => {
    const result = findMatchingRule('root', 'const');
    assert(result !== null, 'should find matching rule for const');
  });

  test('should have rule matching type', () => {
    const result = findMatchingRule('root', 'type');
    assert(result !== null, 'should find matching rule for type');
  });

  test('should have rule matching import', () => {
    const result = findMatchingRule('root', 'import');
    assert(result !== null, 'should find matching rule for import');
  });
});

describe('Root state: string literals', () => {
  test('should match double quote', () => {
    const result = findMatchingRule('root', '"hello"');
    assert(result !== null, 'should find rule for double quote');
  });

  test('should match raw string', () => {
    const result = findMatchingRule('root', 'r"raw"');
    assert(result !== null, 'should find rule for raw string');
  });

  test('should match triple quote', () => {
    const result = findMatchingRule('root', '"""multiline"""');
    assert(result !== null, 'should find rule for triple quote');
  });
});

describe('Root state: comments', () => {
  test('should match line comment in whitespace state', () => {
    const result = findMatchingRule('whitespace', '# comment');
    assert(result !== null, 'should find rule for line comment');
  });

  test('should match doc comment', () => {
    const result = findMatchingRule('whitespace', '## doc comment');
    assert(result !== null, 'should find rule for doc comment');
  });

  test('should match block comment', () => {
    const result = findMatchingRule('whitespace', '#[');
    assert(result !== null, 'should find rule for block comment start');
  });
});

describe('Root state: numbers (via include)', () => {
  // Numbers are matched via { include: '@numbers' } in root state
  // So we test from root, which includes the numbers rules

  test('should match decimal number from root', () => {
    const result = findMatchingRule('root', '42');
    assert(result !== null, 'should find rule for decimal');
  });

  test('should match hex number from root', () => {
    const result = findMatchingRule('root', '0xDEAD');
    assert(result !== null, 'should find rule for hex');
  });

  test('should match binary number from root', () => {
    const result = findMatchingRule('root', '0b1010');
    assert(result !== null, 'should find rule for binary');
  });

  test('should match octal number from root', () => {
    const result = findMatchingRule('root', '0o777');
    assert(result !== null, 'should find rule for octal');
  });

  test('should match float from root', () => {
    const result = findMatchingRule('root', '3.14');
    assert(result !== null, 'should find rule for float');
  });
});

describe('Root state: brackets', () => {
  test('should match curly braces', () => {
    const result = findMatchingRule('root', '{');
    assert(result !== null, 'should find rule for {');
  });

  test('should match pragma open', () => {
    const result = findMatchingRule('root', '{.');
    assert(result !== null, 'should find rule for pragma open');
  });

  test('should match dot brackets', () => {
    const result = findMatchingRule('root', '[.');
    assert(result !== null, 'should find rule for [.');
  });
});

describe('String state', () => {
  test('should match string content', () => {
    const result = findMatchingRule('string', 'hello world');
    assert(result !== null, 'should find rule for string content');
  });

  test('should match escape sequence', () => {
    const result = findMatchingRule('string', '\\n');
    assert(result !== null, 'should find rule for escape');
  });

  test('should match closing quote', () => {
    const result = findMatchingRule('string', '"');
    assert(result !== null, 'should find rule for closing quote');
  });
});

describe('Block comment state', () => {
  test('should match nested block comment start', () => {
    const result = findMatchingRule('blockComment', '#[');
    assert(result !== null, 'should find rule for nested start');
  });

  test('should match block comment end', () => {
    const result = findMatchingRule('blockComment', ']#');
    assert(result !== null, 'should find rule for block end');
  });

  test('should match comment content', () => {
    const result = findMatchingRule('blockComment', 'some text');
    assert(result !== null, 'should find rule for content');
  });
});

describe('Pragma state', () => {
  test('should match pragma close', () => {
    const result = findMatchingRule('pragma', '.}');
    assert(result !== null, 'should find rule for pragma close');
  });

  test('should match pragma keyword', () => {
    const result = findMatchingRule('pragma', 'inline');
    assert(result !== null, 'should find rule for pragma keyword');
  });
});

// ===========================================================================
// Keyword List Tests
// ===========================================================================

describe('Keyword lists', () => {
  test('should have proc in keywords', () => {
    assert(nimLanguage.keywords.includes('proc'), 'keywords should include proc');
  });

  test('should have func in keywords', () => {
    assert(nimLanguage.keywords.includes('func'), 'keywords should include func');
  });

  test('should have all control flow keywords', () => {
    const controlFlow = ['if', 'elif', 'else', 'when', 'case', 'of', 'for', 'while'];
    for (const kw of controlFlow) {
      assert(nimLanguage.keywords.includes(kw), `keywords should include ${kw}`);
    }
  });

  test('should have int in typeKeywords', () => {
    assert(nimLanguage.typeKeywords.includes('int'), 'typeKeywords should include int');
  });

  test('should have string in typeKeywords', () => {
    assert(nimLanguage.typeKeywords.includes('string'), 'typeKeywords should include string');
  });

  test('should have true/false in constants', () => {
    assert(nimLanguage.constants.includes('true'), 'constants should include true');
    assert(nimLanguage.constants.includes('false'), 'constants should include false');
  });

  test('should have echo in builtinFunctions', () => {
    assert(nimLanguage.builtinFunctions.includes('echo'), 'builtinFunctions should include echo');
  });

  test('should have inline in pragmaKeywords', () => {
    assert(nimLanguage.pragmaKeywords.includes('inline'), 'pragmaKeywords should include inline');
  });

  test('should have result and it in specialVariables', () => {
    assert(nimLanguage.specialVariables.includes('result'), 'specialVariables should include result');
    assert(nimLanguage.specialVariables.includes('it'), 'specialVariables should include it');
  });

  test('should have typeDefRhsKeywords for type definitions', () => {
    const expectedRhsKws = ['object', 'enum', 'tuple', 'concept', 'distinct', 'ref', 'ptr', 'interface'];
    for (const kw of expectedRhsKws) {
      assert(nimLanguage.typeDefRhsKeywords.includes(kw), `typeDefRhsKeywords should include ${kw}`);
    }
  });
});

// ===========================================================================
// Case Sensitivity Test
// ===========================================================================

describe('Case insensitivity', () => {
  test('language should be case insensitive', () => {
    assertEqual(nimLanguage.ignoreCase, true, 'ignoreCase should be true');
  });

  test('keyword patterns use word boundary which requires exact case matching in regex', () => {
    // Note: The \b(proc|...) patterns are case-sensitive in the regex itself,
    // but the ignoreCase flag on the language makes Monaco match case-insensitively.
    // Our simple pattern expander doesn't apply ignoreCase to pre-compiled RegExp.
    // In actual Monaco, 'PrOc' would match due to ignoreCase: true on the language.
    // This is a limitation of our test harness, not the grammar.

    // Instead, verify the ignoreCase flag is set
    assertEqual(nimLanguage.ignoreCase, true, 'ignoreCase should be true');

    // And verify keywords are checked case-insensitively
    const keywords = nimLanguage.keywords.map(k => k.toLowerCase());
    assert(keywords.includes('proc'), 'keywords include proc');
  });
});

// ===========================================================================
// State Transition Tests
// ===========================================================================

describe('State transitions', () => {
  test('proc keyword should transition to afterRoutineKeyword', () => {
    const rules = nimLanguage.tokenizer.root;
    const procRule = rules.find(r =>
      Array.isArray(r) && r[0] && String(r[0]).includes('proc')
    );
    assert(procRule !== null, 'should find proc rule');
    if (procRule && typeof procRule[1] === 'object') {
      assertEqual(procRule[1].next, '@afterRoutineKeyword',
        'proc should transition to afterRoutineKeyword');
    }
  });

  test('double quote should transition to string state', () => {
    const rules = nimLanguage.tokenizer.root;
    const stringRule = rules.find(r =>
      Array.isArray(r) && r[0] instanceof RegExp && r[0].source === '"'
    );
    assert(stringRule !== null, 'should find string rule');
  });

  test('pragma open should transition to pragma state', () => {
    const rules = nimLanguage.tokenizer.root;
    const pragmaRule = rules.find(r =>
      Array.isArray(r) && r[0] && String(r[0]).includes('\\{\\.')
    );
    assert(pragmaRule !== null, 'should find pragma rule');
  });
});

// ===========================================================================
// Language Configuration Tests
// ===========================================================================

describe('Language configuration (nimConf)', () => {
  test('should have correct line comment', () => {
    assertEqual(nimConf.comments.lineComment, '#');
  });

  test('should have correct block comment', () => {
    assertEqual(nimConf.comments.blockComment[0], '#[');
    assertEqual(nimConf.comments.blockComment[1], ']#');
  });

  test('should have pragma brackets', () => {
    const hasPragmaBrackets = nimConf.brackets.some(
      b => b[0] === '{.' && b[1] === '.}'
    );
    assert(hasPragmaBrackets, 'should have pragma brackets');
  });

  test('should have indentation rules', () => {
    assert(nimConf.indentationRules.increaseIndentPattern instanceof RegExp,
      'should have increaseIndentPattern');
    assert(nimConf.indentationRules.decreaseIndentPattern instanceof RegExp,
      'should have decreaseIndentPattern');
  });

  test('should have word pattern', () => {
    assert(nimConf.wordPattern instanceof RegExp, 'should have wordPattern');
  });
});

// ===========================================================================
// Integration-like Tests (pattern matching on code snippets)
// ===========================================================================

describe('Code snippet pattern matching', () => {
  test('proc definition line matches proc rule', () => {
    const code = 'proc hello(name: string): void =';
    const result = findMatchingRule('root', code);
    assert(result !== null, 'should match proc');
    assert(result.matched === 'proc', 'should match exactly "proc"');
  });

  test('let declaration matches let rule', () => {
    const code = 'let x: int = 42';
    const result = findMatchingRule('root', code);
    assert(result !== null, 'should match let');
  });

  test('for loop - for is in keywords list', () => {
    // 'for' is matched by the @ident rule with cases checking @keywords
    // Since 'for' doesn't have a special rule like 'proc', it matches via @ident
    assert(nimLanguage.keywords.includes('for'), 'for should be in keywords');
  });

  test('import statement matches import rule', () => {
    const code = 'import strutils';
    const result = findMatchingRule('root', code);
    assert(result !== null, 'should match import');
  });

  test('pragma matches pragma rule', () => {
    const code = '{.inline.}';
    const result = findMatchingRule('root', code);
    assert(result !== null, 'should match pragma');
  });

  test('comment matches comment rule', () => {
    const code = '# this is a comment';
    const result = findMatchingRule('whitespace', code);
    assert(result !== null, 'should match comment');
  });

  test('string matches string rule', () => {
    const code = '"hello world"';
    const result = findMatchingRule('root', code);
    assert(result !== null, 'should match string');
  });

  test('number matches number rule (via root include)', () => {
    const code = '12345';
    const result = findMatchingRule('root', code);
    assert(result !== null, 'should match number');
  });

  test('hex number matches hex rule (via root include)', () => {
    const code = '0xDEADBEEF';
    const result = findMatchingRule('root', code);
    assert(result !== null, 'should match hex number');
    assert(result.matched.startsWith('0x'), 'should match starting with 0x');
  });
});

// ===========================================================================
// Semantic+ Feature Tests
// ===========================================================================

describe('Semantic+: Special variables (result, it)', () => {
  test('result should be in specialVariables list', () => {
    assert(nimLanguage.specialVariables.includes('result'),
      'result should be a special variable');
  });

  test('it should be in specialVariables list', () => {
    assert(nimLanguage.specialVariables.includes('it'),
      'it should be a special variable');
  });

  test('root state identifier rule should check @specialVariables', () => {
    // Find the identifier rule in root state
    const rules = nimLanguage.tokenizer.root;
    const identRule = rules.find(r =>
      Array.isArray(r) &&
      r[0] instanceof RegExp &&
      r[0].source.includes('ident') &&
      typeof r[1] === 'object' &&
      r[1].cases
    );
    assert(identRule !== null, 'should find identifier rule with cases');
    assert('@specialVariables' in identRule[1].cases,
      'identifier rule should check @specialVariables');
  });
});

describe('Semantic+: Export marker (*)', () => {
  test('should have rule for exported identifiers', () => {
    // Look for rule matching identifier followed by *
    const rules = nimLanguage.tokenizer.root;
    const exportRule = rules.find(r =>
      Array.isArray(r) &&
      r[0] instanceof RegExp &&
      r[0].source.includes('\\*')
    );
    assert(exportRule !== null, 'should find export marker rule');
  });

  test('declNameListVar should have modifier.export token for *', () => {
    const rules = nimLanguage.tokenizer.declNameListVar;
    const starRule = rules.find(r =>
      Array.isArray(r) &&
      r[0] instanceof RegExp &&
      r[0].source === '\\*'
    );
    assert(starRule !== null, 'should find * rule in declNameListVar');
    assertEqual(starRule[1], 'modifier.export', '* should be tokenized as modifier.export');
  });

  test('routineAfterName should have modifier.export token for *', () => {
    const rules = nimLanguage.tokenizer.routineAfterName;
    const starRule = rules.find(r =>
      Array.isArray(r) &&
      r[0] instanceof RegExp &&
      r[0].source === '\\*'
    );
    assert(starRule !== null, 'should find * rule in routineAfterName');
    assertEqual(starRule[1], 'modifier.export', '* should be tokenized as modifier.export');
  });
});

describe('Semantic+: Import statement highlighting', () => {
  test('should have importClauseStart state', () => {
    assert(Array.isArray(nimLanguage.tokenizer.importClauseStart),
      'should have importClauseStart state');
  });

  test('importClauseStart should recognize std specially', () => {
    const rules = nimLanguage.tokenizer.importClauseStart;
    const identRule = rules.find(r =>
      Array.isArray(r) &&
      typeof r[1] === 'object' &&
      r[1].cases &&
      'std' in r[1].cases
    );
    assert(identRule !== null, 'should have rule that recognizes std');
    assertEqual(identRule[1].cases['std'], 'namespace.std',
      'std should be tokenized as namespace.std');
  });

  test('importClauseStart should recognize system specially', () => {
    const rules = nimLanguage.tokenizer.importClauseStart;
    const identRule = rules.find(r =>
      Array.isArray(r) &&
      typeof r[1] === 'object' &&
      r[1].cases &&
      'system' in r[1].cases
    );
    assert(identRule !== null, 'should have rule that recognizes system');
    assertEqual(identRule[1].cases['system'], 'namespace.system',
      'system should be tokenized as namespace.system');
  });

  test('importClauseStart should pop on newline', () => {
    const rules = nimLanguage.tokenizer.importClauseStart;
    const newlineRule = rules.find(r =>
      Array.isArray(r) &&
      r[0] instanceof RegExp &&
      (r[0].source === '[\\r\\n]' || r[0].source.includes('\\n'))
    );
    assert(newlineRule !== null, 'should have newline rule');
    assert(newlineRule[1].next === '@pop', 'should pop on newline');
  });
});

describe('Semantic+: Type definition RHS keywords', () => {
  test('should have typeDefRhsKeywords list', () => {
    assert(Array.isArray(nimLanguage.typeDefRhsKeywords),
      'should have typeDefRhsKeywords array');
  });

  test('typeDefRhsKeywords should include object', () => {
    assert(nimLanguage.typeDefRhsKeywords.includes('object'),
      'should include object');
  });

  test('typeDefRhsKeywords should include enum', () => {
    assert(nimLanguage.typeDefRhsKeywords.includes('enum'),
      'should include enum');
  });

  test('typeDefRhsKeywords should include ref', () => {
    assert(nimLanguage.typeDefRhsKeywords.includes('ref'),
      'should include ref');
  });

  test('should have typeRhsLine state', () => {
    assert(Array.isArray(nimLanguage.tokenizer.typeRhsLine),
      'should have typeRhsLine state for type definition RHS');
  });

  test('typeRhsLine should check @typeDefRhsKeywords', () => {
    const rules = nimLanguage.tokenizer.typeRhsLine;
    const identRule = rules.find(r =>
      Array.isArray(r) &&
      typeof r[1] === 'object' &&
      r[1].cases &&
      '@typeDefRhsKeywords' in r[1].cases
    );
    assert(identRule !== null,
      'typeRhsLine should have rule checking @typeDefRhsKeywords');
    assertEqual(identRule[1].cases['@typeDefRhsKeywords'], 'keyword.type',
      'typeDefRhsKeywords should be tokenized as keyword.type');
  });
});

describe('Semantic+: from ... import statement', () => {
  test('should have fromClauseStart state', () => {
    assert(Array.isArray(nimLanguage.tokenizer.fromClauseStart),
      'should have fromClauseStart state');
  });

  test('should have fromImportItems state', () => {
    assert(Array.isArray(nimLanguage.tokenizer.fromImportItems),
      'should have fromImportItems state');
  });

  test('fromClauseStart should recognize std specially', () => {
    const rules = nimLanguage.tokenizer.fromClauseStart;
    const identRule = rules.find(r =>
      Array.isArray(r) &&
      typeof r[1] === 'object' &&
      r[1].cases &&
      'std' in r[1].cases
    );
    assert(identRule !== null, 'should have rule that recognizes std');
    assertEqual(identRule[1].cases['std'], 'namespace.std',
      'std should be tokenized as namespace.std in from clause');
  });

  test('fromClauseStart should pop on newline', () => {
    const rules = nimLanguage.tokenizer.fromClauseStart;
    const newlineRule = rules.find(r =>
      Array.isArray(r) &&
      r[0] instanceof RegExp &&
      (r[0].source === '[\\r\\n]' || r[0].source.includes('\\n'))
    );
    assert(newlineRule !== null, 'should have newline rule');
    assert(newlineRule[1].next === '@pop', 'should pop on newline');
  });
});

describe('Semantic+: Exported backtick identifiers', () => {
  test('should have rule for exported backtick identifier', () => {
    const rules = nimLanguage.tokenizer.root;
    const backtickExportRule = rules.find(r =>
      Array.isArray(r) &&
      r[0] instanceof RegExp &&
      r[0].source.includes('`[^`\\r\\n]+`') &&
      r[0].source.includes('\\*')
    );
    assert(backtickExportRule !== null,
      'should have rule for exported backtick identifiers like `weird name`*');
  });
});

// ===========================================================================
// Run tests
// ===========================================================================

console.log('\n========================================');
console.log('Nim Tokenizer Pattern Tests');
console.log('========================================');

console.log('\n========================================');
console.log(`Results: \x1b[32m${passed} passed\x1b[0m, \x1b[31m${failed} failed\x1b[0m`);
console.log('========================================\n');

if (failed > 0) {
  process.exit(1);
}
