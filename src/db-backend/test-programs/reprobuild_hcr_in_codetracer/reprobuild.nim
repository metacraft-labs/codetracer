import std/os

import repro_dsl_stdlib

package reprobuildHcrInCodetracer:
  uses:
    "clang >=1"
    "sh >=1"

  executable shell:
    name "sh"
    cli:
      subcmd "-c":
        pos args is seq[string],
          position = 0

  build:
    let buildDir = fs.ensureDir(
      path = "build",
      actionId = "build-dir")

    let commonCflags =
      "-O0 -g3 -fno-inline -fno-lto -fPIC " &
      hcr.patchableFunctionEntryFlag()
    let hcrLinkFlags = hcr.machoSegmentLinkFlags()
    let reproRoot = getEnv("REPROBUILD_SOURCE_ROOT")
    let agentDir = reproRoot / "libs" / "repro_hcr_agent" / "c"
    let agentSource = agentDir / "repro_hcr_agent.c"

    let mainObject = buildAction(
      "compile-main-object",
      reprobuildHcrInCodetracer.executable("sh").subcmd_2d_c(
        args = @[
          ": \"${REPROBUILD_SOURCE_ROOT:?REPROBUILD_SOURCE_ROOT is required}\"; " &
          "agent_dir=\"$REPROBUILD_SOURCE_ROOT/libs/repro_hcr_agent/c\"; " &
          "clang " & commonCflags & " -Isrc -I$agent_dir -c src/main.c -o build/main.o"
        ]),
      deps = @["build-dir"],
      inputs = @[
        "src/main.c",
        "src/hcr_fixture.h"],
      outputs = @["build/main.o"])

    let patchableObject = buildAction(
      "compile-patchable-object",
      reprobuildHcrInCodetracer.executable("sh").subcmd_2d_c(
        args = @[
          "clang " & commonCflags & " -Isrc -c src/patchable.c " &
          "-o build/patchable.raw.o"
        ]),
      deps = @["build-dir"],
      inputs = @[
        "src/patchable.c",
        "src/hcr_fixture.h"],
      outputs = @["build/patchable.raw.o"])

    let preparedPatchableObject = hcr.prepareObject(
      actionId = "prepare-patchable-object",
      input = "build/patchable.raw.o",
      output = "build/patchable.o",
      after = @[patchableObject])

    let agentObject = buildAction(
      "compile-hcr-agent-object",
      reprobuildHcrInCodetracer.executable("sh").subcmd_2d_c(
        args = @[
          ": \"${REPROBUILD_SOURCE_ROOT:?REPROBUILD_SOURCE_ROOT is required}\"; " &
          "agent_dir=\"$REPROBUILD_SOURCE_ROOT/libs/repro_hcr_agent/c\"; " &
          "clang " & commonCflags & " -I$agent_dir -c \"$agent_dir/repro_hcr_agent.c\" " &
          "-o build/repro_hcr_agent.o"
        ]),
      deps = @["build-dir"],
      inputs = @[agentSource],
      outputs = @["build/repro_hcr_agent.o"])

    let hcrTarget = buildAction(
      "link-hcr-target",
      reprobuildHcrInCodetracer.executable("sh").subcmd_2d_c(
        args = @[
          "clang build/main.o build/patchable.o build/repro_hcr_agent.o " &
          (if hcrLinkFlags.len > 0: hcrLinkFlags & " " else: "") &
          "-lpthread -o build/hcr_target; " &
          "rm -rf build/hcr_target.dSYM; " &
          "if [ \"$(uname -s)\" = Darwin ] && command -v dsymutil >/dev/null 2>&1; then " &
          "dsymutil build/hcr_target -o build/hcr_target.dSYM; " &
          "else " &
          "mkdir -p build/hcr_target.dSYM/Contents/Resources/DWARF; " &
          "printf '%s\n' 'debug symbols unavailable on this platform' > build/hcr_target.dSYM/Contents/Info.plist; " &
          ": > build/hcr_target.dSYM/Contents/Resources/DWARF/hcr_target; " &
          "fi"
        ]),
      deps = @[
        "compile-main-object",
        "prepare-patchable-object",
        "compile-hcr-agent-object"],
      inputs = @[
        "build/main.o",
        "build/patchable.o",
        "build/repro_hcr_agent.o"],
      outputs = @[
        "build/hcr_target",
        "build/hcr_target.dSYM/Contents/Info.plist",
        "build/hcr_target.dSYM/Contents/Resources/DWARF/hcr_target"])

    target("hcr-target", [
      buildDir,
      mainObject,
      patchableObject,
      preparedPatchableObject,
      agentObject,
      hcrTarget])
    defaultTarget(hcrTarget)
