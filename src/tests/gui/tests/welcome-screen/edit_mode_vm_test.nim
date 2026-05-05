import std/unittest

import edit_mode

suite "Edit mode startup selection":
  test "explicit file path wins over indexed folder files":
    let requested = "/workspace/src/manual.nim"
    let filenames = [
      "/workspace/src/main.nim",
      "/workspace/.gitignore"
    ]

    check chooseInitialEditPath(requested, filenames, editMode = true) ==
      requested

  test "folder edit mode prefers real source entry over hidden files":
    let filenames = [
      "/workspace/.gitignore",
      "/workspace/target/generated.o",
      "/workspace/src/main.nr",
      "/workspace/README.md"
    ]

    check chooseInitialEditPath("", filenames, editMode = true) ==
      "/workspace/src/main.nr"

  test "non-edit no-trace mode does not invent an editor tab":
    let filenames = [
      "/workspace/src/main.py"
    ]

    check chooseInitialEditPath("", filenames, editMode = false) == ""
