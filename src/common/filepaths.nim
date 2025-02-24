import
  os

type
  ## Below are some aliases for the `string` type that is typically used in
  ## in Nim for handling file paths.
  ##
  ## For now, these aliases exists mostly to make the code more self-documenting.
  ## In the future, we might try to introduce more type safety around them to
  ## facilitate the detection of programmer errors (e.g. a directory path being
  ## passed to a function expecting a file type).
  ##
  ## Using these types will also help us migrate to Nim 2.0 where the `Path` is
  ## already a `distinct string` type.

  FilePath* = string
    ## Represents a file path.
    ## A file might or might not exist on this path.

  ExistingFilePath* = FilePath
    ## Represents a file path.
    ## A file is expected to exist on this path.
    ## Please note that this is not 100% guaranteed, because a concurrent process
    ## can always delete a file, violating the expectations of the program.

  CreatedFilePath* = ExistingFilePath
    ## Represents a file path for a file that was just created.

  DirPath* = string
    ## Represents a directory path.
    ## A directory might or might not exist on this path.

  ExistingDirPath* = DirPath
    ## Represents a directory path.
    ## A directory is expected to exist on this path.
    ## Please note that this is not 100% guaranteed, because a concurrent
    ## process can always delete the directory, violating the expectations
    ## of the program.

  CreatedDirPath* = ExistingDirPath
    ## Represents a directory path for a directory that was just created.

export os
