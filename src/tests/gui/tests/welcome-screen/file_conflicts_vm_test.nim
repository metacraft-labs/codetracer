import std/[strutils, unittest]

import file_conflicts

suite "External file change conflict model":
  test "clean buffers reload automatically":
    check classifyExternalChange(bufferChanged = false) == ecdReload

  test "dirty buffers prompt before reload":
    check classifyExternalChange(bufferChanged = true) == ecdPrompt

  test "three-way merge document contains all sides":
    let document = buildThreeWayMergeDocument(
      "/workspace/main.nim",
      "let value = 1",
      "let value = 2",
      "let value = 3")

    check "BASE: last synchronized version" in document
    check "OURS: in-memory CodeTracer buffer" in document
    check "THEIRS: current disk version" in document
    check "let value = 1" in document
    check "let value = 2" in document
    check "let value = 3" in document
