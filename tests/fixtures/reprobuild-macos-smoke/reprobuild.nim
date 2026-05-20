import repro_dsl_stdlib

package reprobuildMacosSmoke:
  uses:
    "gcc >=1"
    "sh >=1"

  executable shell:
    name "sh"
    cli:
      subcmd "-c":
        pos args is seq[string],
          position = 0

  executable cCompiler:
    name "gcc"
    cli:
      subcmd "-o":
        pos args is seq[string],
          position = 0

  build:
    let buildDir = fs.ensureDir(
      path = "build",
      actionId = "build-dir")

    let hello = buildAction(
      "compile-hello",
      reprobuildMacosSmoke.executable("gcc").subcmd_2d_o(
        args = @["build/hello", "src/hello.c"]),
      deps = @["build-dir"],
      inputs = @["src/hello.c"],
      outputs = @["build/hello"])

    let output = buildAction(
      "run-hello",
      reprobuildMacosSmoke.executable("sh").subcmd_2d_c(
        args = @["./build/hello > build/hello-output.txt"]),
      deps = @["compile-hello"],
      inputs = @["build/hello"],
      outputs = @["build/hello-output.txt"])

    target("hello", [buildDir, hello, output])
    defaultTarget(output)
