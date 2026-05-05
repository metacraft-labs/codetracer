import
  std/[ os, unittest ],
  source_paths

suite "trace storage/import source path handling":
  test "relative trace paths resolve from recorded workdir":
    let workdir = getTempDir() / "ct-storage-workdir"
    check resolveTraceSourcePath("src/main.nr", workdir) ==
      workdir / "src/main.nr"
    check tracePayloadRelativePath("src/main.nr", workdir) == "src/main.nr"

  test "absolute trace paths preserve legacy payload layout":
    let absolute = "/tmp/project/src/main.nr"
    check resolveTraceSourcePath(absolute, "/tmp/project") == absolute
    check tracePayloadRelativePath(absolute, "/tmp/project") ==
      "tmp/project/src/main.nr"
