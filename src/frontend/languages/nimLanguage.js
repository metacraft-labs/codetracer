// Nim language definition for Monaco editor
// Based on Monarch framework - mirrors Nim compiler lexer behavior
// Semantic+ version with enhanced heuristics for result/it, export markers, imports, and type definitions

// Language configuration for Nim in Monaco
export const nimConf = {
  comments: {
    lineComment: '#',
    // Nim also has doc block comments ##[ ]##, but Monaco only supports one block pair here.
    blockComment: ['#[', ']#']
  },

  // Bracket matching (Monaco supports multi-char pairs too)
  brackets: [
    ['{', '}'],
    ['[', ']'],
    ['(', ')'],

    // Nim "dot" bracket tokens (lexer has explicit tokens for these):
    ['{.', '.}'],
    ['[.', '.]'],
    ['(.', '.)'],

    // Slice opener:
    ['[:', ']']
  ],

  autoClosingPairs: [
    { open: '{', close: '}' },
    { open: '[', close: ']' },
    { open: '(', close: ')' },

    // Pragmas
    { open: '{.', close: '.}' },

    // Dot brackets
    { open: '[.', close: '.]' },
    { open: '(.', close: '.)' },

    // Strings
    { open: '"', close: '"', notIn: ['string', 'comment'] },
    // Monaco can auto-close multi-char opens; this is handy for Nim triple strings:
    { open: '"""', close: '"""', notIn: ['string', 'comment'] },

    // Characters & backticks
    { open: "'", close: "'", notIn: ['string', 'comment'] },
    { open: '`', close: '`', notIn: ['string', 'comment'] },

    // Nested block comments (regular + doc)
    { open: '#[', close: ']#', notIn: ['string'] },
    { open: '##[', close: ']##', notIn: ['string'] }
  ],

  surroundingPairs: [
    { open: '{', close: '}' },
    { open: '[', close: ']' },
    { open: '(', close: ')' },
    { open: '"', close: '"' },
    { open: "'", close: "'" },
    { open: '`', close: '`' }
  ],

  // Reasonable default for auto-close behavior around punctuation
  autoCloseBefore: ' \t\r\n]}),;:.',

  // Word selection: Nim identifiers (with Nim underscore rule) + backtick identifiers + single underscore
  // Note: This is for selection, not tokenization.
  wordPattern:
    /(`[^`\r\n]*`)|(_(?![\w\u0080-\uFFFF]))|([A-Za-z\u0080-\uFFFF](?:[A-Za-z0-9\u0080-\uFFFF]|_(?=[A-Za-z0-9\u0080-\uFFFF]))*)/,

  // Optional: very light indentation heuristics (not perfect, but helps)
  indentationRules: {
    // Indent after ':' or '=' at line end, or after control-flow introducers
    increaseIndentPattern:
      /^\s*(?:.*(?:=|:)\s*(?:#.*)?|(?:if|when|elif|else|for|while|try|except|finally|case|of|block|proc|func|method|iterator|template|macro|converter)\b.*)\s*$/,

    // Dedent on typical continuation keywords (Nim doesn't have "end" blocks generally, but has elif/else/except/finally)
    decreaseIndentPattern:
      /^\s*(?:elif|else|except|finally)\b.*$/
  }
};

// Nim Monarch language definition
export const nimLanguage = {
  defaultToken: '',
  tokenPostfix: '.nim',
  ignoreCase: true,
  // Include line feed at end of each line so [\r\n] patterns can match
  includeLF: true,

  // --- Nim lexer keywords (case-insensitive) ---
  keywords: [
    'addr', 'and', 'as', 'asm',
    'bind', 'block', 'break',
    'case', 'cast', 'concept', 'const', 'continue', 'converter',
    'defer', 'discard', 'distinct', 'div', 'do',
    'elif', 'else', 'end', 'enum', 'except', 'export',
    'finally', 'for', 'from', 'func',
    'if', 'import', 'in', 'include', 'interface', 'is', 'isnot', 'iterator',
    'let',
    'macro', 'method', 'mixin', 'mod', 'nil', 'not', 'notin',
    'object', 'of', 'or', 'out',
    'proc', 'ptr', 'raise', 'ref', 'return',
    'shl', 'shr', 'static',
    'template', 'try', 'tuple', 'type', 'using',
    'var', 'when', 'while', 'xor', 'yield'
  ],

  // Some widely-used type-like ids (purely for highlighting; lexer treats as symbols)
  typeKeywords: [
    'int', 'int8', 'int16', 'int32', 'int64',
    'uint', 'uint8', 'uint16', 'uint32', 'uint64',
    'float', 'float32', 'float64', 'float128',
    'bool', 'char', 'string', 'cstring', 'pointer', 'byte',
    'cint', 'cuint', 'clong', 'culong', 'cshort', 'cushort',
    'csize_t', 'cfloat', 'cdouble',
    'seq', 'set', 'array', 'openarray', 'varargs', 'range', 'slice',
    'typedesc',
    'auto', 'any', 'untyped', 'typed'
  ],

  constants: ['true', 'false', 'nil'],

  // Language-ish special variables (result is implicit return, it is used in some templates)
  specialVariables: ['result', 'it'],

  // Pragmas you usually want to "pop" visually
  pragmaKeywords: [
    'push', 'pop',
    'hint', 'warning', 'error',
    'deprecated',
    'raises', 'tags',
    'gcsafe', 'nosideeffect', 'inline', 'noinline',
    'discardable', 'used', 'exportc', 'importc',
    'cdecl', 'stdcall', 'nimcall', 'dynlib', 'header',
    'compile', 'link',
    'passc', 'passl',
    'checks', 'boundchecks', 'overflowchecks',
    'optimization', 'hints', 'warnings'
  ],

  // A *small* set of common System-ish calls (optional; tweak to taste)
  builtinFunctions: [
    'echo', 'len', 'high', 'low',
    'inc', 'dec',
    'ord', 'chr',
    'assert', 'doassert',
    'newseq', 'newstring',
    'sizeof', 'typeof',
    'defined', 'compiles', 'declared'
  ],

  operators: [
    '+', '-', '*', '/', '\\', '<', '>', '!', '?', '^', '.',
    '|', '=', '%', '&', '$', '@', '~', ':'
  ],

  unicodeOperators: [
    '\u2219', '\u2218', '\u00D7', '\u2605', '\u2297', '\u2298', '\u2299', '\u229B', '\u22A0', '\u22A1', '\u2229', '\u2227', '\u2293',
    '\u00B1', '\u2295', '\u2296', '\u229E', '\u229F', '\u222A', '\u2228', '\u2294'
  ],

  // Keywords we want to emphasize specifically when they appear on the RHS of a type definition
  typeDefRhsKeywords: [
    'object', 'enum', 'tuple', 'concept', 'distinct', 'ref', 'ptr', 'interface'
  ],

  brackets: [
    { open: '{', close: '}', token: 'delimiter.curly' },
    { open: '[', close: ']', token: 'delimiter.bracket' },
    { open: '(', close: ')', token: 'delimiter.parenthesis' },
    { open: '{.', close: '.}', token: 'delimiter.curly' },
    { open: '[.', close: '.]', token: 'delimiter.bracket' },
    { open: '(.', close: '.)', token: 'delimiter.parenthesis' }
  ],

  // --- Core regex atoms (close to Nim lexer rules) ---
  ident: /[A-Za-z\u0080-\uFFFF](?:[A-Za-z0-9\u0080-\uFFFF]|_(?=[A-Za-z0-9\u0080-\uFFFF]))*/,
  underscoreIdent: /_(?![A-Za-z0-9\u0080-\uFFFF_])/,

  symbols: /(?:[=><!\~\?:&|+\-*\/\\\^%@$.:]+|[\u2219\u2218\u00D7\u2605\u2297\u2298\u2299\u229B\u22A0\u22A1\u2229\u2227\u2293\u00B1\u2295\u2296\u229E\u229F\u222A\u2228\u2294])+/,

  escapes: /\\(?:[nNpPrRcClLfFeEaAbBvVtT"'\\]|x[0-9A-Fa-f]{2}|u\{[0-9A-Fa-f]+\}|u[0-9A-Fa-f]{4}|[0-9]{1,3})/,

  decDigits: /[0-9](?:_?[0-9])*/,
  hexDigits: /[0-9A-Fa-f](?:_?[0-9A-Fa-f])*/,
  octDigits: /[0-7](?:_?[0-7])*/,
  binDigits: /[0-1](?:_?[0-1])*/,

  numTypeSuffix: /'?(?:f128|f64|f32|f|d|i8|i16|i32|i64|u64|u32|u16|u8|u)\b/,
  numCustomSuffix: /'(?:[A-Za-z0-9\u0080-\uFFFF][A-Za-z0-9\u0080-\uFFFF_]*)/,

  tokenizer: {
    root: [
      // ============================================================
      // 0) Top-level "section blocks" (best-effort; column-0 only)
      // ============================================================

      // type\n  (block)
      [/^(?=type\b)/, { token: '', next: '@typeHeader' }],
      // const\n (block)
      [/^(?=const\b)/, { token: '', next: '@constHeader' }],
      // var\n   (block)
      [/^(?=var\b)/, { token: '', next: '@varHeader' }],
      // let\n   (block)
      [/^(?=let\b)/, { token: '', next: '@letHeader' }],

      // ============================================================
      // 1) Definition-ish statements (any indentation)
      // ============================================================

      // Routine definitions: highlight the next identifier as entity.name.function
      [/\b(proc|func|method|iterator|template|macro|converter)\b/, { token: 'keyword', next: '@afterRoutineKeyword' }],

      // Inline type statement (not the block form): highlight next identifier as entity.name.type
      [/\btype\b/, { token: 'keyword', next: '@afterTypeInline' }],

      // Inline var/let/const: highlight declared names
      [/\b(var)\b/, { token: 'keyword', next: '@afterVarInline' }],
      [/\b(let)\b/, { token: 'keyword', next: '@afterLetInline' }],
      [/\b(const)\b/, { token: 'keyword', next: '@afterConstInline' }],

      // Imports
      [/\b(import|include)\b/, { token: 'keyword', next: '@importClauseStart' }],
      [/\bfrom\b/, { token: 'keyword', next: '@fromClauseStart' }],

      // ============================================================
      // 2) Normal lexing (comments/strings/numbers/operators/idents)
      // ============================================================

      { include: '@whitespace' },

      // Pragmas: {. ... .}
      [/\{\./, { token: 'metatag', next: '@pragma' }],

      // Nim dot-bracket tokens and slice opener
      [/\[\./, 'delimiter.bracket'],
      [/\.\]/, 'delimiter.bracket'],
      [/\(\./, 'delimiter.parenthesis'],
      [/\.\)/, 'delimiter.parenthesis'],
      [/\[:/, 'delimiter.bracket'],

      // Raw string literals: r"..." and r"""..."""
      [/r"""/, { token: 'string.delimiter', next: '@rawTripleString' }],
      [/r"/, { token: 'string.delimiter', next: '@rawString' }],

      // Generalized strings: ident"..." / ident"""...""" => raw semantics
      [/@ident(?=")/, { token: 'type.identifier', next: '@gstringStart' }],

      // Regular triple + normal
      [/"""/, { token: 'string.delimiter', next: '@tripleString' }],
      [/"/, { token: 'string.delimiter', next: '@string' }],

      // Exported backtick identifier: `weird name`*
      [/(`[^`\r\n]+`)(\*)(?=\s*(?:,|:|=|\)|\]|\}|\{|$))/, ['identifier', 'modifier.export']],

      // Backtick identifier/operator
      [/`/, { token: 'delimiter.backtick', next: '@backtickIdent' }],

      // Char literal
      [/'/, { token: 'string.delimiter', next: '@char' }],

      // Numbers (incl unary-minus heuristic)
      { include: '@numbers' },

      // Exported normal identifiers (covers fields like x*: int, enum members like A*, etc.)
      [/(@ident)(\*)(?=\s*(?:,|:|=|\)|\]|\}|\{|$))/, [
        {
          cases: {
            '@keywords': 'keyword',
            '@typeKeywords': 'type.identifier',
            '@specialVariables': 'variable.language',
            '@default': 'identifier'
          }
        },
        'modifier.export'
      ]],

      // Member call / access (do before @symbols so '.' doesn't get swallowed)
      [/(\.)(@ident)(?=\s*\()/, ['operator', 'variable.member.function']],
      [/(\.)(@ident)/, ['operator', 'variable.member']],

      // Call sites: foo(...)
      [/@ident(?=\s*\()/, {
        cases: {
          '@specialVariables': 'variable.language',
          '@keywords': 'keyword',
          '@typeKeywords': 'type.identifier',
          '@builtinFunctions': 'support.function',
          '@default': 'identifier.function'
        }
      }],

      // Brackets + punctuation
      [/[{}()\[\]]/, '@brackets'],
      [/::/, 'delimiter'],
      [/\.\./, 'operator'],
      [/[;,]/, 'delimiter'],

      // Operators
      [/@symbols/, 'operator'],

      // Identifiers & keywords
      [/@underscoreIdent/, 'identifier'],
      [/@ident/, {
        cases: {
          '@specialVariables': 'variable.language',
          '@keywords': 'keyword',
          '@constants': 'constant',
          '@typeKeywords': 'type.identifier',
          '@builtinFunctions': 'support.function',
          '@default': 'identifier'
        }
      }]
    ],

    // ============================================================
    // Whitespace + comments (nested, incl doc comments)
    // ============================================================
    whitespace: [
      [/[ \t\r\n]+/, 'white'],
      [/##\[/, 'comment.doc', '@docCommentBlock'],
      [/##[^\r\n]*/, 'comment.doc'],  // Match until newline (includeLF makes $ unreliable)
      [/#\[/, 'comment', '@blockComment'],
      [/#[^\r\n]*/, 'comment']  // Match until newline
    ],

    blockComment: [
      [/#\[/, 'comment', '@push'],
      [/\]#/, 'comment', '@pop'],
      [/[^#\[\]]+/, 'comment'],
      [/[\[\]#]/, 'comment']
    ],

    docCommentBlock: [
      [/##\[/, 'comment.doc', '@push'],
      [/\]##/, 'comment.doc', '@pop'],
      [/[^#\]]+/, 'comment.doc'],
      [/./, 'comment.doc']
    ],

    // ============================================================
    // Pragmas with semantic-ish highlighting
    // ============================================================
    pragma: [
      [/\.\}/, { token: 'metatag', next: '@pop' }],
      { include: '@whitespace' },

      // allow strings/numbers in pragmas
      [/r"""/, { token: 'string.delimiter', next: '@rawTripleString' }],
      [/r"/, { token: 'string.delimiter', next: '@rawString' }],
      [/"""/, { token: 'string.delimiter', next: '@tripleString' }],
      [/"/, { token: 'string.delimiter', next: '@string' }],
      { include: '@numbers' },

      // pragma keys
      [/@ident/, {
        cases: {
          '@pragmaKeywords': 'attribute.name',
          '@keywords': 'keyword',
          '@constants': 'constant',
          '@typeKeywords': 'type.identifier',
          '@default': 'metatag'
        }
      }],

      // pragma separators / operators
      [/[:=,]/, 'delimiter'],
      [/@symbols/, 'operator'],

      [/./, 'metatag']
    ],

    // ============================================================
    // Generalized raw string start: ident"..." or ident"""..."""
    // ============================================================
    gstringStart: [
      [/"""/, { token: 'string.delimiter', next: '@tripleString' }],
      [/"/, { token: 'string.delimiter', next: '@gstring' }],
      ['', { token: '', next: '@pop' }]
    ],

    gstring: [
      [/""/, 'string.escape'],
      [/[^"]+/, 'string'],
      [/"/, { token: 'string.delimiter', next: '@pop' }],
      [/$/, { token: 'string.invalid', next: '@pop' }]
    ],

    // ============================================================
    // Strings
    // ============================================================
    string: [
      [/[^"\\]+/, 'string'],
      [/@escapes/, 'string.escape'],
      [/\\./, 'string.escape.invalid'],
      [/"/, { token: 'string.delimiter', next: '@pop' }],
      [/$/, { token: 'string.invalid', next: '@pop' }]
    ],

    rawString: [
      [/""/, 'string.escape'],
      [/[^"]+/, 'string'],
      [/"/, { token: 'string.delimiter', next: '@pop' }],
      [/$/, { token: 'string.invalid', next: '@pop' }]
    ],

    // Nim triple close rule: """ closes only if not followed by another "
    tripleString: [
      [/"""\s*(?!")/, { token: 'string.delimiter', next: '@pop' }],
      [/[^"]+/, 'string'],
      [/"/, 'string']
    ],

    rawTripleString: [
      [/"""\s*(?!")/, { token: 'string.delimiter', next: '@pop' }],
      [/[^"]+/, 'string'],
      [/"/, 'string']
    ],

    // ============================================================
    // Backticks / characters
    // ============================================================
    backtickIdent: [
      [/`/, { token: 'delimiter.backtick', next: '@pop' }],
      [/[^`\r\n]+/, 'identifier'],
      [/$/, { token: 'identifier.invalid', next: '@pop' }]
    ],

    char: [
      [/@escapes/, { token: 'string.escape', next: '@charEnd' }],
      [/[^\\'\r\n]/, { token: 'string', next: '@charEnd' }],
      [/['\r\n]/, { token: 'string.invalid', next: '@pop' }],
      [/$/, { token: 'string.invalid', next: '@pop' }]
    ],
    charEnd: [
      // Use @popall to return to root after character literal ends
      [/'/, { token: 'string.delimiter', next: '@popall' }],
      [/./, { token: 'string.invalid', next: '@popall' }],
      [/$/, { token: 'string.invalid', next: '@popall' }]
    ],

    // ============================================================
    // Numbers
    // ============================================================
    numbers: [
      // unary minus heuristic: boundary + '-' then number will match next
      [
        /(^|[ \t\r\n,;\(\[\{])-(?=(?:0[xX][0-9A-Fa-f]|0[oO][0-7]|0[bB][01]|[0-9]))/,
        ['', 'operator']
      ],

      [/0[xX]@hexDigits(?:@numTypeSuffix|@numCustomSuffix)?/, 'number.hex'],
      [/0[o]@octDigits(?:@numTypeSuffix|@numCustomSuffix)?/, 'number.octal'],
      [/0[cC]@octDigits(?:@numTypeSuffix|@numCustomSuffix)?/, 'number.octal'], // deprecated in compiler
      [/0[bB]@binDigits(?:@numTypeSuffix|@numCustomSuffix)?/, 'number.binary'],

      [/@decDigits\.[0-9](?:_?[0-9])*(?:[eE][+\-]@decDigits)?(?:@numTypeSuffix|@numCustomSuffix)?/, 'number.float'],
      [/@decDigits(?:[eE][+\-]?@decDigits)(?:@numTypeSuffix|@numCustomSuffix)?/, 'number.float'],
      [/@decDigits(?:@numTypeSuffix|@numCustomSuffix)?/, 'number'],

      [/@decDigits'(?![A-Za-z0-9\u0080-\uFFFF_])/, 'number.invalid']
    ],

    // ============================================================
    // SEMANTIC STATES
    // ============================================================

    // ---------- Routine definitions ----------
    afterRoutineKeyword: [
      { include: '@whitespace' },

      // backtick names: proc `==`(a,b:int) = ...
      [/`/, { token: 'delimiter.backtick', next: '@routineBacktickName' }],

      // normal name
      [/@ident/, { token: 'entity.name.function', next: '@routineAfterName' }],
      [/@underscoreIdent/, { token: 'entity.name.function', next: '@routineAfterName' }],

      // if something weird happens, bail out
      ['', { token: '', next: '@pop' }]
    ],

    routineBacktickName: [
      [/`/, { token: 'delimiter.backtick', next: '@routineAfterName' }],
      [/[^`\r\n]+/, 'entity.name.function'],
      [/$/, { token: 'entity.name.function.invalid', next: '@pop' }]
    ],

    routineAfterName: [
      // export marker for routine name
      [/\*/, 'modifier.export'],
      { include: '@whitespace' },

      // parse params with semantic coloring
      [/\(/, { token: 'delimiter.parenthesis', next: '@paramList' }],

      // return type without param list: proc f: int = ...
      [/:/, { token: 'delimiter', next: '@returnTypeRef' }],

      // pragmas in signature
      [/\{\./, { token: 'metatag', next: '@pragma' }],

      // end of "special" handling; return to root
      ['', { token: '', next: '@pop' }]
    ],

    // Parameter list semantic coloring
    paramList: [
      { include: '@whitespace' },

      // nested parentheses (proc types)
      [/\(/, { token: 'delimiter.parenthesis', next: '@push' }],
      [/\)/, { token: 'delimiter.parenthesis', next: '@pop' }],

      // separators
      [/[,;]/, 'delimiter'],

      // type separator (after name(s))
      [/:/, { token: 'delimiter', next: '@paramTypeRef' }],

      // parameter names (best-effort: anything before ':')
      [/`/, { token: 'delimiter.backtick', next: '@paramBacktickName' }],
      [/@ident/, 'variable.parameter'],
      [/@underscoreIdent/, 'variable.parameter'],

      // allow operators/brackets/strings/numbers inside defaults/types etc
      [/\{\./, { token: 'metatag', next: '@pragma' }],
      { include: '@numbers' },
      [/@symbols/, 'operator'],
      [/[{}\[\]]/, '@brackets'],
      [/"""/, { token: 'string.delimiter', next: '@tripleString' }],
      [/"/, { token: 'string.delimiter', next: '@string' }],

      // otherwise: fall through as identifier
      [/./, '']
    ],

    paramBacktickName: [
      [/`/, { token: 'delimiter.backtick', next: '@pop' }],
      [/[^`\r\n]+/, 'variable.parameter'],
      [/$/, { token: 'variable.parameter.invalid', next: '@pop' }]
    ],

    // Type references inside param lists (until delimiter , ; or ) )
    paramTypeRef: [
      { include: '@whitespace' },

      // end type segment
      [/(?=[,;\)])/ , { token: '', next: '@pop' }],

      // proc/func/iterator in type position should be keyword (for proc types like proc() {.closure.})
      [/\b(proc|func|iterator)\b/, 'keyword'],

      // highlight type-ish ids
      [/@ident/, {
        cases: {
          '@typeKeywords': 'type.identifier',
          '@keywords': 'keyword',
          '@default': 'type.identifier'
        }
      }],
      [/@underscoreIdent/, 'type.identifier'],

      // allow nested types / generics etc
      [/\(/, { token: 'delimiter.parenthesis', next: '@push' }],
      [/\)/, { token: 'delimiter.parenthesis', next: '@pop' }],
      [/[{}\[\]]/, '@brackets'],
      [/@symbols/, 'operator'],
      [/[,;]/, 'delimiter'],

      // default values start (heuristic): pop and let paramList handle it
      [/=/, { token: 'operator', next: '@pop' }],

      [/"""/, { token: 'string.delimiter', next: '@tripleString' }],
      [/"/, { token: 'string.delimiter', next: '@string' }],
      { include: '@numbers' },

      [/./, '']
    ],

    // Return type after routine signature: proc f(): T {.p.} = ...
    returnTypeRef: [
      { include: '@whitespace' },

      // stop return-type highlighting at pragmas or body markers
      [/(?=(\{\.)|=|$)/, { token: '', next: '@pop' }],

      // proc/func/iterator in type position should be keyword (for proc return types)
      [/\b(proc|func|iterator)\b/, 'keyword'],

      [/@ident/, {
        cases: {
          '@typeKeywords': 'type.identifier',
          '@keywords': 'keyword',
          '@default': 'type.identifier'
        }
      }],
      [/@underscoreIdent/, 'type.identifier'],
      [/[{}\[\]()]/, '@brackets'],
      [/[,;]/, 'delimiter'],
      [/@symbols/, 'operator'],
      { include: '@numbers' },
      [/"""/, { token: 'string.delimiter', next: '@tripleString' }],
      [/"/, { token: 'string.delimiter', next: '@string' }],

      [/./, '']
    ],

    // ---------- Inline var/let/const ----------
    afterVarInline: [{ include: '@declNameListVar' }],
    afterLetInline: [{ include: '@declNameListLet' }],
    afterConstInline: [{ include: '@declNameListConst' }],

    declNameListVar: [
      { include: '@whitespace' },
      [/$/, { token: '', next: '@pop' }],
      [/`/, { token: 'delimiter.backtick', next: '@declBacktickVar' }],
      [/@ident/, 'variable.name'],
      [/@underscoreIdent/, 'variable.name'],
      [/\*/, 'modifier.export'],
      [/[,;]/, 'delimiter'],
      [/:/, { token: 'delimiter', next: '@declTypeRef' }],
      [/=/, { token: 'operator', next: '@pop' }],
      ['', { token: '', next: '@pop' }]
    ],
    declBacktickVar: [
      [/`/, { token: 'delimiter.backtick', next: '@pop' }],
      [/[^`\r\n]+/, 'variable.name'],
      [/$/, { token: 'variable.name.invalid', next: '@pop' }]
    ],

    declNameListLet: [
      { include: '@whitespace' },
      [/$/, { token: '', next: '@pop' }],
      [/`/, { token: 'delimiter.backtick', next: '@declBacktickLet' }],
      [/@ident/, 'variable.name'],
      [/@underscoreIdent/, 'variable.name'],
      [/\*/, 'modifier.export'],
      [/[,;]/, 'delimiter'],
      [/:/, { token: 'delimiter', next: '@declTypeRef' }],
      [/=/, { token: 'operator', next: '@pop' }],
      ['', { token: '', next: '@pop' }]
    ],
    declBacktickLet: [
      [/`/, { token: 'delimiter.backtick', next: '@pop' }],
      [/[^`\r\n]+/, 'variable.name'],
      [/$/, { token: 'variable.name.invalid', next: '@pop' }]
    ],

    declNameListConst: [
      { include: '@whitespace' },
      [/$/, { token: '', next: '@pop' }],
      [/`/, { token: 'delimiter.backtick', next: '@declBacktickConst' }],
      [/@ident/, 'variable.name'],
      [/@underscoreIdent/, 'variable.name'],
      [/\*/, 'modifier.export'],
      [/[,;]/, 'delimiter'],
      [/:/, { token: 'delimiter', next: '@declTypeRef' }],
      [/=/, { token: 'operator', next: '@pop' }],
      ['', { token: '', next: '@pop' }]
    ],
    declBacktickConst: [
      [/`/, { token: 'delimiter.backtick', next: '@pop' }],
      [/[^`\r\n]+/, 'variable.name'],
      [/$/, { token: 'variable.name.invalid', next: '@pop' }]
    ],

    // Types in var/let/const declarations (until '=' or end)
    declTypeRef: [
      { include: '@whitespace' },
      [/(?=(=|;|$))/ , { token: '', next: '@pop' }],
      // proc/func/iterator in type position should be keyword (for proc types)
      [/\b(proc|func|iterator)\b/, 'keyword'],
      [/@ident/, {
        cases: {
          '@typeKeywords': 'type.identifier',
          '@keywords': 'keyword',
          '@default': 'type.identifier'
        }
      }],
      [/@underscoreIdent/, 'type.identifier'],
      [/[{}\[\]()]/, '@brackets'],
      [/[,;]/, 'delimiter'],
      [/@symbols/, 'operator'],
      { include: '@numbers' },
      [/"""/, { token: 'string.delimiter', next: '@tripleString' }],
      [/"/, { token: 'string.delimiter', next: '@string' }],
      [/./, '']
    ],

    // ---------- Imports: highlight std / system / std/[modules] ----------
    // Simplified import handling - stays in one state and pops at end of line
    importClauseStart: [
      // Handle whitespace but NOT newlines - newlines pop back to root
      [/[ \t]+/, 'white'],
      [/[\r\n]/, { token: 'white', next: '@pop' }],

      // except keyword
      [/\bexcept\b/, 'keyword'],

      // path separators
      [/[\/.]/, 'delimiter'],

      // std/[a, b] bracket list
      [/\[/, 'delimiter.bracket'],
      [/\]/, 'delimiter.bracket'],

      // separators
      [/[,;]/, 'delimiter'],

      // Comments - pop before comment so root handles it
      [/(?=#)/, { token: '', next: '@pop' }],

      // Module names with special cases for std and system
      [/@ident/, {
        cases: {
          'std': 'namespace.std',
          'system': 'namespace.system',
          '@default': 'namespace'
        }
      }],
      [/@underscoreIdent/, 'namespace'],

      // Anything else pops back to root
      [/./, { token: '', next: '@pop' }]
    ],

    // ---------- from ... import ... ----------
    // Simplified: from module/path import symbol1, symbol2
    fromClauseStart: [
      // Handle whitespace but NOT newlines - newlines pop back to root
      [/[ \t]+/, 'white'],
      [/[\r\n]/, { token: 'white', next: '@pop' }],

      // import keyword transitions to import items
      [/\bimport\b/, { token: 'keyword', next: '@fromImportItems' }],

      // path separators
      [/[\/.]/, 'delimiter'],

      // std/[a, b] bracket list
      [/\[/, 'delimiter.bracket'],
      [/\]/, 'delimiter.bracket'],

      // separators
      [/[,;]/, 'delimiter'],

      // Comments - pop before comment so root handles it
      [/(?=#)/, { token: '', next: '@pop' }],

      // Module names with special cases
      [/@ident/, {
        cases: {
          'std': 'namespace.std',
          'system': 'namespace.system',
          '@default': 'namespace'
        }
      }],
      [/@underscoreIdent/, 'namespace'],

      [/./, { token: '', next: '@pop' }]
    ],

    fromImportItems: [
      // Handle whitespace but NOT newlines - newlines pop back to root
      [/[ \t]+/, 'white'],
      [/[\r\n]/, { token: 'white', next: '@pop' }],

      // imported symbol names
      [/`[^`\r\n]+`/, 'identifier'],
      [/@ident/, 'identifier'],
      [/@underscoreIdent/, 'identifier'],
      [/[,;]/, 'delimiter'],

      // Comments - pop before comment so root handles it
      [/(?=#)/, { token: '', next: '@pop' }],

      [/./, { token: '', next: '@pop' }]
    ],

    // ---------- Inline type highlighting ----------
    afterTypeInline: [
      { include: '@whitespace' },

      // next identifier is probably a type name in "type Foo = ..."
      [/`/, { token: 'delimiter.backtick', next: '@typeBacktickName' }],
      [/@ident/, { token: 'entity.name.type', next: '@typeAfterNameInline' }],

      // if no name, bail out
      ['', { token: '', next: '@pop' }]
    ],
    typeBacktickName: [
      [/`/, { token: 'delimiter.backtick', next: '@typeAfterNameInline' }],
      [/[^`\r\n]+/, 'entity.name.type'],
      [/$/, { token: 'entity.name.type.invalid', next: '@pop' }]
    ],
    typeAfterNameInline: [
      [/\*/, 'modifier.export'],
      ['', { token: '', next: '@pop' }]
    ],

    // ============================================================
    // SECTION BLOCKS (column-0 only): type/const/var/let
    // ============================================================

    typeHeader: [
      // we are at col0 because root matched ^(?=type\b)
      [/type\b/, { token: 'keyword', next: '@typeHeaderRest' }]
    ],
    typeHeaderRest: [
      { include: '@whitespace' },
      // if the line ends right after "type", enter the indented block mode
      [/$/, { token: '', next: '@typeBlock' }],
      // otherwise inline handling - pop all the way back to root
      ['', { token: '', next: '@popall' }]
    ],

    // type block: highlight "Foo* = ..." and give RHS type-kws a special token
    typeBlock: [
      // Exit block when next line starts at col0 with a non-space (dedent)
      [/^(?=\S)/, { token: '', next: '@pop' }],

      { include: '@whitespace' },

      // Backtick type name:   `Weird Type`* = ref object
      [/^(\s+)(`[^`\r\n]+`)(\*?)(\s*=\s*)/, ['white', 'entity.name.type', 'modifier.export', { token: 'delimiter', next: '@typeRhsLine' }]],

      // Normal type name:     Foo* = ref object
      [/^(\s+)(@ident)(\*?)(\s*=\s*)/, ['white', 'entity.name.type', 'modifier.export', { token: 'delimiter', next: '@typeRhsLine' }]],

      // keep normal lexing inside the block
      { include: '@root' }
    ],

    // Only for the remainder of the *same line* after "type Foo ="
    // (Monarch is line-based, so $ ends the line)
    typeRhsLine: [
      [/$/, { token: '', next: '@pop' }],

      { include: '@whitespace' },

      // proc/func/iterator in type position should be keyword (for proc types)
      [/\b(proc|func|iterator)\b/, 'keyword'],

      // emphasize common RHS type constructors/keywords
      [/@ident/, {
        cases: {
          '@typeDefRhsKeywords': 'keyword.type',
          '@keywords': 'keyword',
          '@typeKeywords': 'type.identifier',
          '@default': 'type.identifier'
        }
      }],

      // keep normal lexing
      [/r"""/, { token: 'string.delimiter', next: '@rawTripleString' }],
      [/r"/, { token: 'string.delimiter', next: '@rawString' }],
      [/"""/, { token: 'string.delimiter', next: '@tripleString' }],
      [/"/, { token: 'string.delimiter', next: '@string' }],
      { include: '@numbers' },
      [/@symbols/, 'operator'],
      [/[{}()[\]]/, '@brackets'],
      [/[,.;:]/, 'delimiter'],
      [/./, '']
    ],

    constHeader: [
      [/const\b/, { token: 'keyword', next: '@constHeaderRest' }]
    ],
    constHeaderRest: [
      { include: '@whitespace' },
      [/$/, { token: '', next: '@constBlock' }],
      // Not a block - pop all the way back to root
      ['', { token: '', next: '@popall' }]
    ],
    constBlock: [
      [/^(?=\S)/, { token: '', next: '@pop' }],
      { include: '@whitespace' },

      // NAME* = ...
      [/^(\s+)(@ident)(\*?)(?=\s*=)/, ['white', 'variable.name', 'modifier.export']],

      { include: '@root' }
    ],

    varHeader: [
      [/var\b/, { token: 'keyword', next: '@varHeaderRest' }]
    ],
    varHeaderRest: [
      { include: '@whitespace' },
      [/$/, { token: '', next: '@varBlock' }],
      // Not a block - pop all the way back to root
      ['', { token: '', next: '@popall' }]
    ],
    varBlock: [
      [/^(?=\S)/, { token: '', next: '@pop' }],
      { include: '@whitespace' },

      // First name on the line
      [/^(\s+)(@ident)(\*?)(?=\s*(?:,|:|=|$))/ , ['white', 'variable.name', 'modifier.export']],
      // Additional names in "a, b, c: T"
      [/(,)(\s*)(@ident)(\*?)(?=\s*(?:,|:|=|$))/, ['delimiter', 'white', 'variable.name', 'modifier.export']],

      { include: '@root' }
    ],

    letHeader: [
      [/let\b/, { token: 'keyword', next: '@letHeaderRest' }]
    ],
    letHeaderRest: [
      { include: '@whitespace' },
      [/$/, { token: '', next: '@letBlock' }],
      // Not a block - pop twice to get back to root (once from letHeaderRest, once from letHeader)
      ['', { token: '', next: '@popall' }]
    ],
    letBlock: [
      [/^(?=\S)/, { token: '', next: '@pop' }],
      { include: '@whitespace' },

      [/^(\s+)(@ident)(\*?)(?=\s*(?:,|:|=|$))/ , ['white', 'variable.name', 'modifier.export']],
      [/(,)(\s*)(@ident)(\*?)(?=\s*(?:,|:|=|$))/, ['delimiter', 'white', 'variable.name', 'modifier.export']],

      { include: '@root' }
    ]
  }
};

// Function to register Nim language with Monaco
export function registerNimLanguage(monaco) {
  // Register the language
  monaco.languages.register({ id: 'nim' });

  // Set language configuration
  monaco.languages.setLanguageConfiguration('nim', nimConf);

  // Set Monarch tokens provider
  monaco.languages.setMonarchTokensProvider('nim', nimLanguage);
}
