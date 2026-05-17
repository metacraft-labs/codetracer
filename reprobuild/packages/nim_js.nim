import repro_project_dsl

package nimJs:
  executable nimJsTool:
    name "nim-js"
    cli:
      subcmd "-d:asyncBackend=asyncdispatch":
        pos args, seq[string], position = 0

proc js*(args: seq[string]): PublicCliCall =
  subcmd_2d_d_3a_asyncBackend_3d_asyncdispatch(args = args)
