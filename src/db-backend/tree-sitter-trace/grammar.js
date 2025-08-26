// ============================================================================
// _   _  ___ _____ _____
// | \ | |/ _ \_   _| ____|
// |  \| | | | || | |  _|
// | |\  | |_| || | | |___
// |_| \_|\___/ |_| |_____|
//
// Tup doesn't know if this file is chaned. When you change this file, you must
// manually run `tree-sitter generate` in order to update the parser.
//
// TODO: make tup build for this
//
// ============================================================================

/**
 * @file Tracepoint grammar for tree-sitter
 * @author Metacraft Labs Ltd
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
  name: 'tracepoint',

  rules: {
    source_file: $ => repeat(seq(choice($._expression, $._comment), optional('\n'))),
    _expression: $ => choice(
      $._expressionWithBraces,
      $._directExpression
    ),
    _directExpression: $ => prec(2, choice(
      $.unaryOperationExpression,
      $.ifExpression,
      $.logExpression,
      $.forExpression,
      $.fieldExpression,
      $.patternMatchExpression,
      $.binaryOperationExpression,
      $.indexExpression,
      $.callExpression,
      $.rangeExpression,
      $.namespacedName,
      $.booleanLiteral,
      $.name,
      $.integer,
      $.float,
      $.interpolatedString,
      // $.string
    )),
    _expressionWithBraces: $ => seq("(", $._expression, ")"),
    _indexLeftExpression: $ => choice(
      $._expressionWithBraces,
      $.fieldExpression,
      $.indexExpression,
      $.callExpression,
      $.name,
      $.interpolatedString
    ),
    _unaryArgExpression: $ => prec(3, choice(
      $._expressionWithBraces,
      $.fieldExpression,
      $.indexExpression,
      $.callExpression,
      $.unaryOperationExpression,
      $.booleanLiteral,
      $.name,
      $.integer,
      $.float,
    )),
    codeBlock: $ => seq(
      '{',
      repeat(seq(choice($._expression, $._comment), optional('\n'))),
      '}'
    ),
    ifExpression: $ => seq(
      choice("if", "ако"),
      field('condition', $._expression),
      field('body', $.codeBlock),
      optional(seq(
        choice("else", "иначе"),
        field('else', choice($.ifExpression, $.codeBlock))
      ))
    ),
    logExpression: $ => seq(
      choice("log", "покажи"),
      "(",
      // based on https://stackoverflow.com/a/62803449/438099
      optional(seq($._expression, repeat(seq(",", $._expression)))),
      ")"
    ),
    _fieldBaseExpression: $ => choice(
      $._expressionWithBraces,
      $.fieldExpression,
      $.indexExpression,
      $.callExpression,
      $.name,
      $.interpolatedString
    ),
    fieldExpression: $ => prec(2, seq($._fieldBaseExpression, ".", choice($.name, $.integer))),
    indexExpression: $ => prec(1, seq($._indexLeftExpression, "[", $._expression, "]")),
    callExpression: $ => seq(
      $.name,
      "(",
      // based on https://stackoverflow.com/a/62803449/438099
      optional(seq($._expression, repeat(seq(",", $._expression)))),
      ")"
    ),
    forExpression: $ => seq(
      choice("for", "за"),
      "(",
      repeat1(seq($.name, optional(","))),
      choice("in", "в"),
      $._expression,
      ")",
      "{",
      repeat(seq(choice($._expression, $._comment), optional("\n"))),
      "}"
    ),
    rangeExpression: $ => choice(
      prec.left(2, seq($._expression, field('op', "..<="), $._expression)),
      prec.left(2, seq($._expression, field('op', "..>="), $._expression)),
      prec.left(1, seq($._expression, field('op', "..<"), $._expression)),
      prec.left(1, seq($._expression, field('op', "..>"), $._expression))
    ),
    namespacedName: $ => seq(repeat1(seq($.name, "::")), $.name),
    patternMatchExpression: $ => choice(
      prec.left(2, seq('~', $._pattern, field('op', '='), $._expression)),
      prec.left(2, seq('let', $._pattern, field('op', '='), $._expression))
    ),
    _pattern: $ => choice(
      $.argsPattern,
      $.recordPattern,
      $.wildcard,
      $.booleanLiteral,
      $.integer,
      $.float,
      $.string,
      $.bindingVariable
    ),
    argsPattern: $ => seq(
      choice(
        $.namespacedName,
        $.name
      ),
      '(',
      repeat1(seq($._pattern, optional(","))),
      ')'),
    recordPattern: $ => seq(
      choice(
        $.namespacedName,
        $.name
      ),
      '{',
      repeat1(seq($._recordPatternArg, optional(","))),
      '}'),
    _recordPatternArg: $ => choice(
      $.fieldPattern,
      $.restWildcard,
      $.name),
    fieldPattern: $ => seq($.name, ':', $._pattern),
    bindingVariable: $ => $._name,
    wildcard: $ => '_',
    restWildcard: $ => '..',
    unaryOperationExpression: $ => prec(7, choice(
      seq(field('op', 'not'), $._unaryArgExpression),
      seq(field('op', 'не'), $._unaryArgExpression),
      seq(field('op', '!'), $._unaryArgExpression),
      seq(field('op', '-'), $._unaryArgExpression)
    )),
    binaryOperationExpression: $ => prec(5, choice(
      prec.left(5, seq($._expression, field('op', '*'), $._expression)),
      prec.left(5, seq($._expression, field('op', "/"), $._expression)),
      prec.left(5, seq($._expression, field('op', "%"), $._expression)),
      prec.left(4, seq($._expression, field('op', '+'), $._expression)),
      prec.left(4, seq($._expression, field('op', "-"), $._expression)),
      prec.left(3, seq($._expression, field('op', "=="), $._expression)),
      prec.left(3, seq($._expression, field('op', "!="), $._expression)),
      prec.left(3, seq($._expression, field('op', ">="), $._expression)),
      prec.left(3, seq($._expression, field('op', ">"), $._expression)),
      prec.left(3, seq($._expression, field('op', "<="), $._expression)),
      prec.left(3, seq($._expression, field('op', "<"), $._expression)),
      prec.left(2, seq($._expression, field('op', 'and'), $._expression)),
      prec.left(2, seq($._expression, field('op', 'и'), $._expression)),
      prec.left(2, seq($._expression, field('op', '&&'), $._expression)),
      prec.left(1, seq($._expression, field('op', 'or'), $._expression)),
      prec.left(1, seq($._expression, field('op', 'или'), $._expression)),
      prec.left(1, seq($._expression, field('op', '||'), $._expression))
    )),
    // rangeOperator: $ => choice("..<=", "..<", "..>=", "..>"),
    interpolatedString: $ => seq(
      "\"",
      $.rawStringPart,
      repeat(seq($.codeInString, $.rawStringPart)),
      "\""
    ),
    codeInString: $ => seq("{", $._expression, "}"),
    rawStringPart: $ => /[^"\{]*/,
    _comment: $ => /\/\/.*/,
    mult: $ => "*",
    add: $ => '+',
    name: $ => /[a-zA-Z_][a-zA-Z0-9_]*/,
    _name: $ => /[a-zA-Z_][a-zA-Z0-9_]*/,
    integer: $ => /[0-9]+/,
    float: $ => /[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)/,
    booleanLiteral: $ => choice('true', 'false'),
    string: $ => seq('"', /[^"]*/, '"'),
  }
});
