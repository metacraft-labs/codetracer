import std/[algorithm, os, sequtils, strutils, tables]

type
  PythonTestKind* = enum
    ptkClass
    ptkFunction
    ptkMethod

  PythonTestDecl* = object
    kind*: PythonTestKind
    name*: string
    className*: string
    line*: int
    column*: int
    endColumn*: int
    indent*: int
    tags*: seq[string]

  PythonCommandScope* = enum
    pcsProject
    pcsFile
    pcsSingle

proc normalizedRelative*(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc isPythonFile*(path: string): bool =
  path.endsWith(".py") and fileExists(path)

proc hasPytestConfig*(projectRoot: string): bool =
  for marker in ["pytest.ini", "tox.ini", "setup.cfg", "pyproject.toml"]:
    if fileExists(projectRoot / marker):
      let content = readFile(projectRoot / marker).toLowerAscii
      if marker == "pytest.ini" or content.contains("pytest"):
        return true
  false

proc isCandidatePytestFile*(path: string): bool =
  if not isPythonFile(path):
    return false
  let name = splitFile(path).name.toLowerAscii & splitFile(path).ext.toLowerAscii
  name.startsWith("test_") or name.endsWith("_test.py")

proc isCandidateUnittestFile*(path: string): bool =
  if not isPythonFile(path):
    return false
  let name = splitFile(path).name.toLowerAscii & splitFile(path).ext.toLowerAscii
  name.startsWith("test") or name.contains("test")

proc pythonFiles*(projectRoot: string; predicate: proc(path: string): bool {.gcsafe.}): seq[string] =
  if not dirExists(projectRoot):
    return @[]
  for path in walkDirRec(projectRoot):
    if predicate(path):
      result.add path
  result.sort(system.cmp[string])

proc sanitizePython*(content: string): string =
  result = newStringOfCap(content.len)
  var
    i = 0
  while i < content.len:
    let ch = content[i]
    if ch == '\n':
      result.add ch
      inc i
      continue
    if ch == '#':
      while i < content.len and content[i] != '\n':
        result.add ' '
        inc i
      continue
    if ch in {'"', '\''}:
      let quote = ch
      let triple = i + 2 < content.len and content[i + 1] == quote and content[i + 2] == quote
      if triple:
        result.add "   "
        i += 3
        while i < content.len:
          if i + 2 < content.len and content[i] == quote and content[i + 1] == quote and content[i + 2] == quote:
            result.add "   "
            i += 3
            break
          if content[i] == '\n':
            result.add '\n'
          else:
            result.add ' '
          inc i
        continue
      else:
        result.add ' '
        inc i
        while i < content.len:
          if content[i] == '\\':
            result.add ' '
            inc i
            if i < content.len:
              result.add(if content[i] == '\n': '\n' else: ' ')
              inc i
            continue
          if content[i] == quote:
            result.add ' '
            inc i
            break
          if content[i] == '\n':
            result.add '\n'
            inc i
            break
          result.add ' '
          inc i
        continue
    result.add ch
    inc i

proc leadingSpaces(line: string): int =
  result = 0
  for ch in line:
    if ch == ' ':
      inc result
    elif ch == '\t':
      result += 4
    else:
      break

proc readNameAfter(line, keyword: string): string =
  let stripped = line.strip
  if not stripped.startsWith(keyword & " "):
    return ""
  var i = keyword.len + 1
  while i < stripped.len and stripped[i] in {' ', '\t'}:
    inc i
  let start = i
  while i < stripped.len and stripped[i] in {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
    inc i
  if i == start:
    return ""
  stripped[start ..< i]

proc isTestFunctionName*(name: string): bool =
  name.startsWith("test")

proc isPytestClassName*(name: string): bool =
  name.startsWith("Test")

proc lineHasDecorator(decorators: seq[string]; needle: string): bool =
  for decorator in decorators:
    if decorator.contains(needle):
      return true
  false

proc parsePythonDeclarations*(content: string): seq[PythonTestDecl] =
  let sanitized = sanitizePython(content)
  var
    classStack: seq[PythonTestDecl] = @[]
    decoratorsByIndent = initTable[int, seq[string]]()
    lineNo = 0
  for line in sanitized.splitLines:
    inc lineNo
    let
      indent = leadingSpaces(line)
      stripped = line.strip
    if stripped.len == 0:
      continue
    while classStack.len > 0 and classStack[^1].indent >= indent:
      discard classStack.pop()
    if stripped.startsWith("@"):
      var decorators = decoratorsByIndent.getOrDefault(indent, @[])
      decorators.add stripped
      decoratorsByIndent[indent] = decorators
      continue
    let className = readNameAfter(line, "class")
    if className.len > 0:
      let column = line.find("class") + 1
      let decl = PythonTestDecl(
        kind: ptkClass,
        name: className,
        line: lineNo,
        column: column,
        endColumn: column + "class ".len + className.len - 1,
        indent: indent,
        tags: @[])
      classStack.add decl
      result.add decl
      decoratorsByIndent.del(indent)
      continue
    var functionName = readNameAfter(line, "def")
    let functionKeyword =
      if functionName.len > 0:
        "def"
      else:
        functionName = readNameAfter(line, "async def")
        "async def"
    if functionName.len > 0:
      let decorators = decoratorsByIndent.getOrDefault(indent, @[])
      decoratorsByIndent.del(indent)
      let parentClass =
        if classStack.len > 0:
          classStack[^1]
        else:
          PythonTestDecl()
      if isTestFunctionName(functionName):
        var tags: seq[string] = @[]
        if decorators.lineHasDecorator("parametrize"):
          tags.add "parametrize"
        if decorators.lineHasDecorator("pytest.mark.skip") or decorators.lineHasDecorator("@unittest.skip"):
          tags.add "skip"
        if decorators.lineHasDecorator("pytest.mark.xfail"):
          tags.add "xfail"
        let column = line.find(functionKeyword) + 1
        result.add PythonTestDecl(
          kind: if parentClass.name.len > 0: ptkMethod else: ptkFunction,
          name: functionName,
          className: parentClass.name,
          line: lineNo,
          column: column,
          endColumn: column + functionKeyword.len + 1 + functionName.len - 1,
          indent: indent,
          tags: tags)
      continue
    decoratorsByIndent.del(indent)

proc moduleNameForFile*(projectRoot, filePath: string): string =
  let relative = normalizedRelative(projectRoot, filePath)
  result = relative
  if result.endsWith(".py"):
    result = result[0 ..< result.len - 3]
  result = result.replace("/", ".").replace("\\", ".")

proc quoteArg(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc pytestSelector*(projectRoot, filePath: string; decl: PythonTestDecl): string =
  result = normalizedRelative(projectRoot, filePath)
  if decl.kind == ptkMethod:
    result.add "::" & decl.className & "::" & decl.name
  elif decl.kind == ptkClass:
    result.add "::" & decl.name
  else:
    result.add "::" & decl.name

proc unittestSelector*(projectRoot, filePath: string; decl: PythonTestDecl): string =
  result = moduleNameForFile(projectRoot, filePath)
  if decl.className.len > 0:
    result.add "." & decl.className & "." & decl.name
  elif decl.kind == ptkClass:
    result.add "." & decl.name
  else:
    result.add "." & decl.name

proc buildPytestCommand*(projectRoot, filePath, selector: string; scope: PythonCommandScope): seq[string] =
  result = @["python", "-m", "pytest", "-q", "--color=no"]
  case scope
  of pcsProject:
    discard
  of pcsFile:
    result.add normalizedRelative(projectRoot, filePath)
  of pcsSingle:
    result.add selector

proc buildUnittestCommand*(projectRoot, filePath, selector: string; scope: PythonCommandScope): seq[string] =
  result = @["python", "-m", "unittest"]
  case scope
  of pcsProject:
    result.add @["discover", "-s", ".", "-p", "test*.py", "-t", "."]
  of pcsFile:
    result.add moduleNameForFile(projectRoot, filePath)
  of pcsSingle:
    result.add selector

proc commandToString*(parts: seq[string]): string =
  parts.mapIt(quoteArg(it)).join(" ")
