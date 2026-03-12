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

  test "findTool matches findExe exactly":
    # findTool is now a direct wrapper around findExe with no fallback
    check findTool("bash") == findExe("bash")
    check findTool("nonexistent_tool_xyz") == findExe("nonexistent_tool_xyz")

suite "requireTool":
  test "requireTool resolves bash":
    let result = requireTool("bash")
    check result.len > 0
    check fileExists(result)

suite "codetracerPrefix":
  test "codetracerPrefix is non-empty":
    check codetracerPrefix.len > 0

suite "external tool resolution":
  test "bashExe resolves to a real path":
    check bashExe.len > 0
    check fileExists(bashExe)

  test "rubyExe resolves consistently with findTool":
    # Verify that rubyExe at runtime matches what findTool would return
    # (assuming CODETRACER_RUBY_EXE_PATH env var is not set, which is the
    # normal test case).
    let expected = findTool("ruby")
    if getEnv("CODETRACER_RUBY_EXE_PATH").len == 0:
      check rubyExe == expected
    else:
      # env var override is in effect — rubyExe should match the env var
      check rubyExe == getEnv("CODETRACER_RUBY_EXE_PATH")

  test "electronExe resolves consistently with findTool":
    # Verify that electronExe matches what findTool("electron") returns.
    let expected = findTool("electron")
    check electronExe == expected
