import std / [unittest, os]

import paths

suite "findTool":
  test "findTool resolves bash":
    let result = findTool("bash")
    check result.len > 0
    check fileExists(result)

  test "findTool returns empty for nonexistent tool":
    let result = findTool("this_tool_does_not_exist_xyz_12345")
    check result.len == 0

suite "requireTool":
  test "requireTool resolves bash":
    let result = requireTool("bash")
    check result.len > 0
    check fileExists(result)

suite "codetracerPrefix":
  test "codetracerPrefix is non-empty":
    check codetracerPrefix.len > 0

  test "codetracerPrefix respects CODETRACER_PREFIX env var":
    let envVal = getEnv("CODETRACER_PREFIX")
    if envVal.len > 0:
      check codetracerPrefix == envVal
    else:
      # When env var is unset, codetracerPrefix falls back to getAppDir().parentDir
      check codetracerPrefix == getAppDir().parentDir
