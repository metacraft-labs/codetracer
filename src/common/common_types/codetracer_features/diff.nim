# trying to describe some patch format/git or normal diff data

type
  Diff* = ref object
    files*: seq[FileDiff]

  FileChange* = enum
    FileAdded,
    FileDeleted,
    FileRenamed,
    FileChanged

  FileDiff* = ref object
    chunks*: seq[Chunk]
    previousPath*: langstring
    currentPath*: langstring
    change*: FileChange

  Chunk* = object
    previousFrom*: int
    previousCount*: int
    currentFrom*: int
    currentCount*: int
    lines*: seq[DiffLine]

  DiffLineKind* = enum NonChanged, Deleted, Added

  DiffLine* = object
    kind*: DiffLineKind
    text*: string
    previousLineNumber*: int
    currentLineNumber*: int
