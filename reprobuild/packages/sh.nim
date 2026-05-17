import repro_project_dsl

package sh:
  executable shTool:
    name "sh"
    cli:
      subcmd "-c":
        pos args, seq[string], position = 0

proc c*(args: seq[string]): PublicCliCall =
  subcmd_2d_c(args = args)
