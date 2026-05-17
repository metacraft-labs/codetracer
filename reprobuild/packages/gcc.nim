import repro_project_dsl

package gcc:
  executable gccTool:
    name "gcc"
    cli:
      subcmd "-fPIC":
        pos args, seq[string], position = 0

proc compile*(args: seq[string]): PublicCliCall =
  subcmd_2d_fPIC(args = args)
