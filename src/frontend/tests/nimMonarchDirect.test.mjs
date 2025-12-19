/**
 * Direct tests for Nim Monarch tokenizer using Monaco's Monarch compiler
 *
 * These tests use Monaco's Monarch compile and lexer modules directly,
 * without the full Monaco editor (avoiding browser dependencies).
 *
 * Run with: node src/frontend/tests/nimMonarchDirect.test.mjs
 */

import { nimLanguage } from '../languages/nimLanguage.js';

// Try to import Monaco's Monarch compiler - may not be available in all environments
let compile;
try {
  const monarchCompile = await import('../../../node-packages/node_modules/monaco-editor/esm/vs/editor/standalone/common/monarch/monarchCompile.js');
  compile = monarchCompile.compile;
} catch (e) {
  console.log('\x1b[33m⚠ Monaco Monarch compiler not available, skipping compile tests\x1b[0m');
  console.log(`  (${e.message})`);
  console.log('\n========================================');
  console.log('Nim Monarch Direct Tests (compile only)');
  console.log('========================================');
  console.log('\n========================================');
  console.log('Results: \x1b[33m0 passed (skipped)\x1b[0m, \x1b[31m0 failed\x1b[0m');
  console.log('========================================\n');
  process.exit(0);
}

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

// ===========================================================================
// Compile and test
// ===========================================================================

describe('Monarch grammar compilation', () => {
  test('should compile without errors', () => {
    const compiled = compile('nim', nimLanguage);
    assert(compiled, 'Should return compiled lexer');
    assert(compiled.tokenizer, 'Should have tokenizer');
    assert(compiled.tokenizer.root, 'Should have root state');
  });

  test('should have all expected states', () => {
    const compiled = compile('nim', nimLanguage);
    const states = Object.keys(compiled.tokenizer);
    assert(states.includes('root'), 'Should have root state');
    assert(states.includes('string'), 'Should have string state');
    assert(states.includes('blockComment'), 'Should have blockComment state');
    assert(states.includes('importClauseStart'), 'Should have importClauseStart state');
    assert(states.includes('typeBlock'), 'Should have typeBlock state');
  });

  test('should have keyword matchers', () => {
    const compiled = compile('nim', nimLanguage);
    // Check that keywords list was processed
    assert(compiled.tokenizer.root.length > 0, 'Root state should have rules');
  });

  test('should be case insensitive', () => {
    const compiled = compile('nim', nimLanguage);
    assert(compiled.ignoreCase === true, 'Should be case insensitive');
  });
});

describe('Import state rules', () => {
  test('importClauseStart should have newline pop rule', () => {
    const compiled = compile('nim', nimLanguage);
    const importRules = compiled.tokenizer.importClauseStart;
    assert(importRules, 'Should have importClauseStart state');

    // Find a rule that matches newlines and pops
    let hasNewlinePop = false;
    for (const rule of importRules) {
      if (rule.regex) {
        const source = rule.regex.source;
        if (source.includes('\\r') || source.includes('\\n') || source === '[\\r\\n]') {
          // Check if action pops
          if (rule.action && rule.action.next === '@pop') {
            hasNewlinePop = true;
            break;
          }
        }
      }
    }
    assert(hasNewlinePop, 'importClauseStart should pop on newline');
  });
});

describe('Type block rules', () => {
  test('typeBlock state should exist', () => {
    const compiled = compile('nim', nimLanguage);
    assert(compiled.tokenizer.typeBlock, 'Should have typeBlock state');
  });
});

// ===========================================================================
// Run tests
// ===========================================================================

console.log('\n========================================');
console.log('Nim Monarch Direct Tests (compile only)');
console.log('========================================');

console.log('\n========================================');
console.log(`Results: \x1b[32m${passed} passed\x1b[0m, \x1b[31m${failed} failed\x1b[0m`);
console.log('========================================\n');

if (failed > 0) {
  process.exit(1);
}
