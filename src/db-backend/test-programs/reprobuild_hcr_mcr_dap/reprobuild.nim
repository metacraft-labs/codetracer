import std/[os]

import repro_dsl_stdlib

package codetracerReprobuildHcrMcrDap:
  uses:
    "nim >=1.6 <3.0"
    "sh >=1"

  executable nimTool:
    name "nim"
    cli:
      subcmd "c":
        flag defines is seq[string],
          alias = "-d:",
          format = concat,
          repeated = true
        boolFlag debugInfo is bool, alias = "--debugInfo"
        boolFlag lineDirOn is bool, alias = "--lineDir:on"
        boolFlag stacktraceOn is bool, alias = "--stacktrace:on"
        boolFlag linetraceOn is bool, alias = "--linetrace:on"
        boolFlag hintsOff is bool, alias = "--hints:off"
        flag output is string,
          alias = "--out:",
          format = concat,
          role = output,
          required = true
        flag paths is seq[string],
          alias = "--path:",
          format = concat,
          repeated = true
        flag passC is seq[string],
          alias = "--passC:",
          format = concat,
          repeated = true
        pos source is string,
          role = input,
          position = 0

  executable shTool:
    name "sh"
    cli:
      subcmd "-c":
        pos args, seq[string], position = 0

  build:
    let reproRoot = getEnv("REPROBUILD_SOURCE_ROOT")
    if reproRoot.len == 0:
      raise newException(ValueError,
        "REPROBUILD_SOURCE_ROOT must point to the Reprobuild source tree")

    let binary = buildAction("compile-hcr-target",
      codetracerReprobuildHcrMcrDap.executable("nim").c(
        source = "hcr_target.nim",
        output = "build/hcr_target",
        debugInfo = true,
        lineDirOn = true,
        stacktraceOn = true,
        linetraceOn = true,
        hintsOff = true,
        defines = @["reproVendoredHash"],
        passC = @[
          "-I" & (reproRoot / "references" / "mold" / "third-party" / "blake3" / "c"),
          "-I" & (reproRoot / "references" / "mold" / "third-party" / "xxhash")
        ],
        paths = @[
          reproRoot / "libs" / "blake3" / "src",
          reproRoot / "libs" / "gxhash" / "src",
          reproRoot / "libs" / "repro_core" / "src",
          reproRoot / "libs" / "repro_hcr_agent" / "src",
          reproRoot / "libs" / "repro_hcr_linker" / "src",
          reproRoot / "libs" / "repro_hcr_linkgraph" / "src",
          reproRoot / "libs" / "repro_hash" / "src",
          reproRoot / "libs" / "xxh3" / "src"
        ]),
      inputs = @["hcr_target.nim"],
      outputs = @["build/hcr_target"],
      dependencyPolicy = declaredOnlyDependencyPolicy())

    let runTarget = buildAction("run-hcr-target",
      codetracerReprobuildHcrMcrDap.executable("sh").subcmd_2d_c(
        args = @["mkdir -p build && ./build/hcr_target > build/hcr-output.json"]),
      deps = @[binary.id],
      inputs = @["build/hcr_target"],
      outputs = @["build/hcr-output.json"])

    defaultBuildAction(runTarget)
