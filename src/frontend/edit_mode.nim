import std/strutils

const PreferredSourceExtensions = [
  ".nim", ".nims", ".py", ".rb", ".js", ".ts", ".jsx", ".tsx",
  ".c", ".h", ".cpp", ".hpp", ".cc", ".rs", ".go", ".nr", ".sol",
  ".move", ".leo", ".cairo", ".circom", ".flow", ".cadence", ".aiken",
  ".sway", ".tolk", ".asm", ".masm", ".java", ".kt", ".swift", ".cs",
  ".lua", ".sh", ".zsh", ".bash", ".html", ".css", ".scss", ".styl",
  ".json", ".yaml", ".yml", ".toml", ".md"
]

const LowPriorityNames = [
  ".gitignore", ".dockerignore", ".env", ".envrc", "package-lock.json",
  "yarn.lock", "pnpm-lock.yaml"
]

proc basename(path: string): string =
  let slash = max(path.rfind('/'), path.rfind('\\'))
  if slash < 0:
    path
  else:
    path[slash + 1 .. ^1]

proc extension(path: string): string =
  let name = basename(path)
  let dot = name.rfind('.')
  if dot <= 0:
    ""
  else:
    name[dot .. ^1].toLowerAscii()

proc isHiddenOrBuildArtifact(path: string): bool =
  let parts = path.replace('\\', '/').split('/')
  for part in parts:
    if part.len == 0:
      continue
    if part[0] == '.':
      return true
    if part in ["target", "node_modules", "nimcache", "build", "dist",
                "vendor", "__pycache__", "proofs"]:
      return true
  false

proc sourceScore(path: string): int =
  let name = basename(path)
  if name.len == 0:
    return -1
  let lowerName = name.toLowerAscii()
  if lowerName in LowPriorityNames:
    return 1
  let ext = extension(path)
  if ext.len == 0 or ext notin PreferredSourceExtensions:
    return 2

  result = 20
  if isHiddenOrBuildArtifact(path):
    result -= 10
  if lowerName in ["main" & ext, "__main__.py", "index" & ext, "app" & ext]:
    result += 20
  if path.replace('\\', '/').contains("/src/"):
    result += 10

proc chooseInitialEditPath*(requestedPath: string; filenames: openArray[string];
                            editMode: bool): string =
  ## Choose the first editor tab for edit mode. Explicit file paths win; folder
  ## edit mode picks a likely source entry instead of whatever filesystem walk
  ## happened to return first, such as .gitignore or build output.
  if requestedPath.len > 0:
    return requestedPath
  if not editMode:
    return ""

  var bestPath = ""
  var bestScore = -1
  for path in filenames:
    let score = sourceScore(path)
    if score > bestScore:
      bestPath = path
      bestScore = score
  bestPath
