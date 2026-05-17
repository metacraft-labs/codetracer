import repro_project_dsl

package nim:
  executable nimTool:
    name "nim"
    cli:
      subcmd "-d:asyncBackend=asyncdispatch":
        pos args, seq[string], position = 0

proc c*(args: seq[string]): PublicCliCall =
  subcmd_2d_d_3a_asyncBackend_3d_asyncdispatch(args = args)
