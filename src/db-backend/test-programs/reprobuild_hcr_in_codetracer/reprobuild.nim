import repro_dsl_stdlib

package reprobuildHcrInCodetracer:
  uses:
    "gcc >=1"
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

    let metadata = buildAction(
      "write-hcr-fixture-metadata",
      reprobuildHcrInCodetracer.executable("sh").subcmd_2d_c(
        args = @[
          "cat > build/hcr-fixture-metadata.json <<'JSON'\n" &
          "{\"schemaId\":\"codetracer.reprobuild-hcr-in-codetracer.fixture-metadata.v1\"," &
          "\"supportProfile\":\"macos-arm64-direct-hcr-in-codetracer-v1\"," &
          "\"target\":\"hcr-target\"," &
          "\"sourceGenerations\":[\"src/patchable.c\",\"generations/patchable_gen1.c\"]," &
          "\"patches\":[{\"function\":\"reprobuild_hcr_patchable_value\"," &
          "\"targetSymbol\":\"reprobuild_hcr_patchable_value\"," &
          "\"object\":\"build/patchable.o\"," &
          "\"source\":\"src/patchable.c\"}]," &
          "\"watchDrivenHcr\":true," &
          "\"agentRequired\":true," &
          "\"codeTracerLaunchRequired\":true," &
          "\"directPatchProfile\":true}\nJSON"
        ]),
      deps = @["build-dir"],
      outputs = @["build/hcr-fixture-metadata.json"])

    let hcrTarget = buildAction(
      "compile-hcr-target",
      reprobuildHcrInCodetracer.executable("sh").subcmd_2d_c(
        args = @[
          ": \"${REPROBUILD_SOURCE_ROOT:?REPROBUILD_SOURCE_ROOT is required}\"; " &
          "agent_dir=\"$REPROBUILD_SOURCE_ROOT/libs/repro_hcr_agent/c\"; " &
          "ld_flags=\"\"; " &
          "case \"$(uname -s):$(uname -m)\" in " &
          "Darwin:arm64|Darwin:aarch64) ld_flags=\"-Wl,-segprot,__HCR,rwx,rwx\";; " &
          "esac; " &
          "cflags=\"-O0 -g3 -fno-inline -fno-lto -fPIC " &
          "-fpatchable-function-entry=16,0 " &
          "-ffunction-sections -DCODETRACER_REPROBUILD_HCR_FIXTURE=1 " &
          "-Isrc -I$agent_dir\"; " &
          "gcc $cflags -c src/main.c -o build/main.o; " &
          "gcc $cflags -c src/patchable.c -o build/patchable.o; " &
          "gcc $cflags -c \"$agent_dir/repro_hcr_agent.c\" -o build/repro_hcr_agent.o; " &
          "gcc build/main.o build/patchable.o build/repro_hcr_agent.o " &
          "$ld_flags -lpthread -o build/hcr_target; " &
          "rm -rf build/hcr_target.dSYM; " &
          "if [ \"$(uname -s)\" = Darwin ] && command -v dsymutil >/dev/null 2>&1; then " &
          "dsymutil build/hcr_target -o build/hcr_target.dSYM; " &
          "else " &
          "mkdir -p build/hcr_target.dSYM/Contents/Resources/DWARF; " &
          "printf '%s\n' 'debug symbols unavailable on this platform' > build/hcr_target.dSYM/Contents/Info.plist; " &
          ": > build/hcr_target.dSYM/Contents/Resources/DWARF/hcr_target; " &
          "fi"
        ]),
      deps = @["build-dir"],
      inputs = @[
        "src/main.c",
        "src/patchable.c",
        "src/hcr_fixture.h",
        "generations/patchable_gen1.c"],
      outputs = @[
        "build/main.o",
        "build/patchable.o",
        "build/repro_hcr_agent.o",
        "build/hcr_target",
        "build/hcr_target.dSYM/Contents/Info.plist",
        "build/hcr_target.dSYM/Contents/Resources/DWARF/hcr_target"])

    target("hcr-target", [buildDir, metadata, hcrTarget])
    defaultTarget(hcrTarget)
